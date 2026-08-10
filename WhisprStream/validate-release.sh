#!/bin/bash
# Read-only validation for finished WhisprStream release artifacts.
set -euo pipefail

APP="${1:?usage: validate-release.sh WhisprStream-macos-arm64.app.zip runtime.zip SHA256SUMS}"
RUNTIME_ZIP="${2:?usage: validate-release.sh app.zip runtime.zip SHA256SUMS}"
SHA256SUMS="${3:?usage: validate-release.sh app.zip runtime.zip SHA256SUMS}"

for FILE in "$APP" "$RUNTIME_ZIP" "$SHA256SUMS"; do
    [ -f "$FILE" ] || { echo "error: missing $FILE" >&2; exit 1; }
done

VALIDATION_TMP="$(mktemp -d "${TMPDIR:-/tmp}/whisprstream-release-check.XXXXXX")"
trap 'rm -rf "$VALIDATION_TMP"' EXIT
if [ -d "$APP" ]; then
    APP_DIR="$APP"
else
    unzip -q "$APP" -d "$VALIDATION_TMP/app"
    APP_DIR="$(find "$VALIDATION_TMP/app" -maxdepth 2 -type d -name __MACOSX -prune -o -type d -name 'WhisprStream.app' -print -quit)"
    [ -n "$APP_DIR" ] || { echo "error: app archive has no WhisprStream.app" >&2; exit 1; }
fi

BIN="$APP_DIR/Contents/MacOS/WhisprStream"
[ -x "$BIN" ] || { echo "error: app executable is missing" >&2; exit 1; }
file "$BIN" | grep -q 'arm64' || { echo "error: app is not arm64" >&2; exit 1; }
if rg -a -q '(/Users/|/home/)' "$BIN"; then
    echo "error: app executable contains a build-machine home path" >&2
    exit 1
fi
codesign --verify --strict --deep "$APP_DIR"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_DIR/Contents/Info.plist" 2>/dev/null; }
BUNDLE_ID="$(plist CFBundleIdentifier)"
MIN_OS="$(plist LSMinimumSystemVersion)"
DEV_PYTHON="$(plist WhisprDevelopmentPythonPath || true)"
RUNTIME_VERSION="$(plist WhisprRuntimeVersion)"
RUNTIME_URL="$(plist WhisprRuntimeURL)"
RUNTIME_SHA256="$(plist WhisprRuntimeSHA256)"
ARCHIVE_BYTES="$(plist WhisprRuntimeArchiveBytes)"
INSTALLED_BYTES="$(plist WhisprRuntimeInstalledBytes)"

[ "$BUNDLE_ID" = "com.leoleo.whisprstream" ] || { echo "error: development bundle identifier" >&2; exit 1; }
[ "$MIN_OS" = "14.0" ] || { echo "error: minimum macOS must be 14.0" >&2; exit 1; }
[ -z "$DEV_PYTHON" ] || { echo "error: development Python path is embedded" >&2; exit 1; }
[[ "$RUNTIME_URL" =~ ^https:// ]] && [[ "$RUNTIME_URL" != *latest/download* ]] || { echo "error: runtime URL is not immutable HTTPS" >&2; exit 1; }
[[ "$RUNTIME_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "error: invalid runtime SHA-256" >&2; exit 1; }
[[ "$RUNTIME_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid runtime version" >&2; exit 1; }
[[ "$ARCHIVE_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid runtime archive bytes" >&2; exit 1; }
[[ "$INSTALLED_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid runtime installed bytes" >&2; exit 1; }

grep -F "  $(basename "$APP")" "$SHA256SUMS" >/dev/null || { echo "error: app is missing from SHA256SUMS" >&2; exit 1; }
grep -F "  $(basename "$RUNTIME_ZIP")" "$SHA256SUMS" >/dev/null || { echo "error: runtime is missing from SHA256SUMS" >&2; exit 1; }
APP_HASH="$(shasum -a 256 "$APP" | awk '{print $1}')"
RUNTIME_HASH="$(shasum -a 256 "$RUNTIME_ZIP" | awk '{print $1}')"
grep -F "$APP_HASH  $(basename "$APP")" "$SHA256SUMS" >/dev/null || { echo "error: app checksum differs from SHA256SUMS" >&2; exit 1; }
grep -F "$RUNTIME_HASH  $(basename "$RUNTIME_ZIP")" "$SHA256SUMS" >/dev/null || { echo "error: runtime checksum differs from SHA256SUMS" >&2; exit 1; }
[ "$RUNTIME_HASH" = "$RUNTIME_SHA256" ] || { echo "error: app embedded runtime checksum differs from runtime archive" >&2; exit 1; }

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
