#!/bin/bash
# Read-only validation for finished WhisprStream release artifacts.
set -euo pipefail

usage() {
    echo "usage: validate-release.sh app.zip runtime.zip SHA256SUMS app-signature app-version build-number" >&2
    exit 2
}

[ "$#" -eq 6 ] || usage
APP="$1"
RUNTIME_ZIP="$2"
SHA256SUMS="$3"
APP_SIGNATURE="$4"
EXPECTED_APP_VERSION="$5"
EXPECTED_BUILD_NUMBER="$6"

[[ "$EXPECTED_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: expected app version must be stable semantic version" >&2
    exit 1
}
[[ "$EXPECTED_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: expected build number must be a positive integer" >&2
    exit 1
}

for FILE in "$APP" "$RUNTIME_ZIP" "$SHA256SUMS" "$APP_SIGNATURE"; do
    [ -f "$FILE" ] || { echo "error: missing $FILE" >&2; exit 1; }
done

VALIDATION_TMP="$(mktemp -d "${TMPDIR:-/tmp}/whisprstream-release-check.XXXXXX")"
trap 'rm -rf "$VALIDATION_TMP"' EXIT
ditto -x -k "$APP" "$VALIDATION_TMP/app"
APP_DIR="$VALIDATION_TMP/app/WhisprStream.app"
[ -d "$APP_DIR" ] && [ ! -L "$APP_DIR" ] || {
    echo "error: app archive must contain WhisprStream.app at its top level" >&2
    exit 1
}

BIN="$APP_DIR/Contents/MacOS/WhisprStream"
UPDATE_INSTALLER="$APP_DIR/Contents/Helpers/WhisprStreamUpdateInstaller"
[ -x "$BIN" ] || { echo "error: app executable is missing" >&2; exit 1; }
[ -x "$UPDATE_INSTALLER" ] || { echo "error: update installer is missing" >&2; exit 1; }
file "$BIN" | grep -q 'arm64' || { echo "error: app is not arm64" >&2; exit 1; }
file "$UPDATE_INSTALLER" | grep -q 'arm64' || { echo "error: update installer is not arm64" >&2; exit 1; }
for EXECUTABLE in "$BIN" "$UPDATE_INSTALLER"; do
    if rg -a -q '(/Users/|/home/)' "$EXECUTABLE"; then
        echo "error: release executable contains a build-machine home path" >&2
        exit 1
    fi
done
codesign --verify --strict --deep "$APP_DIR"
codesign --verify --strict "$UPDATE_INSTALLER"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_DIR/Contents/Info.plist" 2>/dev/null; }
BUNDLE_ID="$(plist CFBundleIdentifier)"
APP_VERSION="$(plist CFBundleShortVersionString)"
BUILD_NUMBER="$(plist CFBundleVersion)"
MIN_OS="$(plist LSMinimumSystemVersion)"
DEV_PYTHON="$(plist WhisprDevelopmentPythonPath || true)"
RUNTIME_VERSION="$(plist WhisprRuntimeVersion)"
RUNTIME_URL="$(plist WhisprRuntimeURL)"
RUNTIME_SHA256="$(plist WhisprRuntimeSHA256)"
ARCHIVE_BYTES="$(plist WhisprRuntimeArchiveBytes)"
INSTALLED_BYTES="$(plist WhisprRuntimeInstalledBytes)"
UPDATE_REPOSITORY="$(plist WhisprUpdateRepository)"
UPDATE_PUBLIC_KEY="$(plist WhisprUpdatePublicKey)"

[ "$BUNDLE_ID" = "com.leoleo.whisprstream" ] || { echo "error: development bundle identifier" >&2; exit 1; }
[ "$APP_VERSION" = "$EXPECTED_APP_VERSION" ] || { echo "error: app version is $APP_VERSION; expected $EXPECTED_APP_VERSION" >&2; exit 1; }
[ "$BUILD_NUMBER" = "$EXPECTED_BUILD_NUMBER" ] || { echo "error: app build is $BUILD_NUMBER; expected $EXPECTED_BUILD_NUMBER" >&2; exit 1; }
[ "$MIN_OS" = "14.0" ] || { echo "error: minimum macOS must be 14.0" >&2; exit 1; }
[ -z "$DEV_PYTHON" ] || { echo "error: development Python path is embedded" >&2; exit 1; }
[[ "$RUNTIME_URL" =~ ^https:// ]] && [[ "$RUNTIME_URL" != *latest/download* ]] || { echo "error: runtime URL is not immutable HTTPS" >&2; exit 1; }
[[ "$RUNTIME_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "error: invalid runtime SHA-256" >&2; exit 1; }
[[ "$RUNTIME_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid runtime version" >&2; exit 1; }
[[ "$ARCHIVE_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid runtime archive bytes" >&2; exit 1; }
[[ "$INSTALLED_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid runtime installed bytes" >&2; exit 1; }
[[ "$UPDATE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "error: invalid update repository" >&2; exit 1; }
[[ "$UPDATE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "error: invalid update public key" >&2; exit 1; }

grep -F "  $(basename "$APP")" "$SHA256SUMS" >/dev/null || { echo "error: app is missing from SHA256SUMS" >&2; exit 1; }
grep -F "  $(basename "$RUNTIME_ZIP")" "$SHA256SUMS" >/dev/null || { echo "error: runtime is missing from SHA256SUMS" >&2; exit 1; }
grep -F "  $(basename "$APP_SIGNATURE")" "$SHA256SUMS" >/dev/null || { echo "error: app signature is missing from SHA256SUMS" >&2; exit 1; }
APP_HASH="$(shasum -a 256 "$APP" | awk '{print $1}')"
RUNTIME_HASH="$(shasum -a 256 "$RUNTIME_ZIP" | awk '{print $1}')"
SIGNATURE_HASH="$(shasum -a 256 "$APP_SIGNATURE" | awk '{print $1}')"
grep -F "$APP_HASH  $(basename "$APP")" "$SHA256SUMS" >/dev/null || { echo "error: app checksum differs from SHA256SUMS" >&2; exit 1; }
grep -F "$RUNTIME_HASH  $(basename "$RUNTIME_ZIP")" "$SHA256SUMS" >/dev/null || { echo "error: runtime checksum differs from SHA256SUMS" >&2; exit 1; }
grep -F "$SIGNATURE_HASH  $(basename "$APP_SIGNATURE")" "$SHA256SUMS" >/dev/null || { echo "error: app signature checksum differs from SHA256SUMS" >&2; exit 1; }
[ "$RUNTIME_HASH" = "$RUNTIME_SHA256" ] || { echo "error: app embedded runtime checksum differs from runtime archive" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SIGNER="$SCRIPT_DIR/.build/release/WhisprStreamUpdateSigner"
[ -x "$UPDATE_SIGNER" ] || { echo "error: release update-signing tool is missing" >&2; exit 1; }
"$UPDATE_SIGNER" verify "$UPDATE_PUBLIC_KEY" "$APP" "$APP_SIGNATURE" >/dev/null

STAGING="$VALIDATION_TMP/runtime"
unzip -q "$RUNTIME_ZIP" -d "$STAGING"
TOP_LEVEL="$(find "$STAGING" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null || true)"
[ "$TOP_LEVEL" = "runtime" ] || { echo "error: runtime zip has the wrong top-level layout" >&2; exit 1; }
MANIFEST="$STAGING/runtime/manifest.json"
PYTHON="$STAGING/runtime/bin/python3.12"
[ -f "$MANIFEST" ] && [ -x "$PYTHON" ] || { echo "error: runtime manifest or Python executable missing" >&2; exit 1; }
MANIFEST_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtimeVersion"])' "$MANIFEST")"
MANIFEST_MIN_OS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minimumMacOS"])' "$MANIFEST")"
[ "$MANIFEST_VERSION" = "$RUNTIME_VERSION" ] || { echo "error: runtime manifest version disagrees with app" >&2; exit 1; }
[ "$MANIFEST_MIN_OS" = "$MIN_OS" ] || { echo "error: runtime and app minimum macOS versions disagree" >&2; exit 1; }
PYTHONNOUSERSITE=1 PYTHONPATH= PYTHONHOME= VIRTUAL_ENV= "$PYTHON" -s -u -c 'import mlx, numpy, huggingface_hub, mlx_qwen3_asr'

version_at_most() {
    [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

while IFS= read -r FILE; do
    BINARY_MIN_OS="$(vtool -show-build "$FILE" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    [ -n "$BINARY_MIN_OS" ] && version_at_most "$BINARY_MIN_OS" "$MIN_OS" || {
        echo "error: runtime binary requires macOS ${BINARY_MIN_OS:-unknown}: $FILE" >&2
        exit 1
    }
    codesign --verify --strict "$FILE"
done < <(find "$STAGING/runtime" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ {print $1}')

echo "release artifacts validated"
