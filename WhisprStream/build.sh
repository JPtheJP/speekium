#!/bin/bash
# Build WhisprStream.app.
#
# The ASR runs as a Python sidecar. Local builds use a prepared venv; public
# releases download a separately versioned runtime after first launch.
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(cd .. && pwd)"
PYTHON="${PYTHON:-$PROJECT_ROOT/.venv/bin/python}"
APP="${APP:-$PROJECT_ROOT/WhisprStream.app}"
VERSION="${VERSION:-1.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
RELEASE="${RELEASE:-0}"
RUNTIME_URL="${RUNTIME_URL:-}"
RUNTIME_SHA256="${RUNTIME_SHA256:-}"
RUNTIME_VERSION="${RUNTIME_VERSION:-}"
RUNTIME_ARCHIVE_BYTES="${RUNTIME_ARCHIVE_BYTES:-}"
RUNTIME_INSTALLED_BYTES="${RUNTIME_INSTALLED_BYTES:-}"
UPDATE_REPOSITORY="${UPDATE_REPOSITORY:-Leo6Leo/whispr-stream}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-dev.local.whisprstream}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [ "$RELEASE" = "1" ]; then
    if [ -z "$RUNTIME_URL" ] || [ -z "$RUNTIME_SHA256" ] || [ -z "$RUNTIME_VERSION" ] \
        || [ -z "$RUNTIME_ARCHIVE_BYTES" ] || [ -z "$RUNTIME_INSTALLED_BYTES" ]; then
        echo "error: release builds require runtime URL, version, checksum, and byte metadata" >&2
        exit 1
    fi
    if ! [[ "$RUNTIME_URL" =~ ^https:// ]] || [[ "$RUNTIME_URL" == *"latest/download"* ]] \
        || ! [[ "$RUNTIME_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
        || ! [[ "$RUNTIME_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || ! [[ "$RUNTIME_ARCHIVE_BYTES" =~ ^[1-9][0-9]*$ ]] \
        || ! [[ "$RUNTIME_INSTALLED_BYTES" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: runtime URL must be immutable HTTPS, checksum must be SHA-256, and sizes must be positive integers" >&2
        exit 1
    fi
    if [ "$BUNDLE_IDENTIFIER" != "com.leoleo.whisprstream" ]; then
        echo "error: release builds require bundle identifier com.leoleo.whisprstream" >&2
        exit 1
    fi
    if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
        echo "error: RELEASE=1 requires SIGNING_IDENTITY; ad-hoc signing is not allowed" >&2
        exit 1
    fi
    DEVELOPMENT_PYTHON=""
    DEVELOPMENT_PYTHON_PLIST=""
else
    if [ ! -x "$PYTHON" ]; then
        echo "error: no python at $PYTHON" >&2
        echo "       set PYTHON=/path/to/python and re-run" >&2
        exit 1
    fi
    # Local builds continue to use the prepared venv. RELEASE=1 deliberately
    # clears this value so no developer-specific path is shipped to users.
    DEVELOPMENT_PYTHON="$PYTHON"
    DEVELOPMENT_PYTHON_PLIST="    <key>WhisprDevelopmentPythonPath</key><string>$DEVELOPMENT_PYTHON</string>"
fi

echo "▸ compiling"
if [ "$RELEASE" = "1" ]; then
    # Swift embeds source and object-file paths in optimized executables. Map
    # the repository root to a stable synthetic path so public artifacts never
    # disclose the builder's user name or local directory layout.
    swift build -c release \
        -Xswiftc -file-prefix-map \
        -Xswiftc "$PROJECT_ROOT=/src" \
        -Xcc "-fdebug-prefix-map=$PROJECT_ROOT=/src" \
        -Xcc "-ffile-prefix-map=$PROJECT_ROOT=/src"
else
    swift build -c release
fi

BIN=".build/release/WhisprStream"
[ -x "$BIN" ] || { echo "error: build produced no binary" >&2; exit 1; }

echo "▸ assembling $(basename "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/WhisprStream"
cp Resources/asr_server.py "$APP/Contents/Resources/"
cp Resources/model_download.py "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/asr_engine.py" "$APP/Contents/Resources/"

if [ "$RELEASE" = "1" ]; then
    # The linker records absolute object-file paths as N_OSO debug symbols;
    # remove those records after source paths have been remapped above.
    strip -S "$APP/Contents/MacOS/WhisprStream"
    if rg -a -q '(/Users/|/home/)' "$APP/Contents/MacOS/WhisprStream"; then
        echo "error: release executable contains a build-machine home path" >&2
        exit 1
    fi
fi

# Designed start/finish sounds. Regenerate with sound-design/render_sounds.py.
if [ -d Resources/Sounds ]; then
    mkdir -p "$APP/Contents/Resources/Sounds"
    cp Resources/Sounds/*.caf "$APP/Contents/Resources/Sounds/"
    echo "▸ bundling $(ls Resources/Sounds/*.caf | wc -l | tr -d ' ') sounds"
else
    echo "warning: no Resources/Sounds — run sound-design/render_sounds.py" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WhisprStream</string>
    <key>CFBundleDisplayName</key><string>WhisprStream</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WhisprStream</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisprStream transcribes your speech on-device.</string>
$DEVELOPMENT_PYTHON_PLIST
    <key>WhisprRuntimeURL</key><string>$RUNTIME_URL</string>
    <key>WhisprRuntimeSHA256</key><string>$RUNTIME_SHA256</string>
    <key>WhisprRuntimeVersion</key><string>$RUNTIME_VERSION</string>
    <key>WhisprRuntimeArchiveBytes</key><string>$RUNTIME_ARCHIVE_BYTES</string>
    <key>WhisprRuntimeInstalledBytes</key><string>$RUNTIME_INSTALLED_BYTES</string>
    <key>WhisprUpdateRepository</key><string>$UPDATE_REPOSITORY</string>
</dict>
</plist>
PLIST

# No entitlements: the app is not sandboxed, so com.apple.security.* keys buy
# nothing and attaching them to an ad-hoc signature confuses TCC. Microphone
# access comes from NSMicrophoneUsageDescription; Accessibility is granted by
# the user in System Settings.
#
# An ad-hoc signature is tied to the binary hash, so every rebuild looks like a
# different app to TCC and silently drops the Accessibility grant. A self-signed
# certificate keeps one identity across rebuilds, so the grant sticks.
IDENTITY="$SIGNING_IDENTITY"
if [ "$RELEASE" = "1" ]; then
    echo "▸ signing release with $IDENTITY"
else
    if security find-identity -p codesigning 2>/dev/null | grep -q "WhisprStream Self-Signed"; then
        IDENTITY="WhisprStream Self-Signed"
        echo "▸ signing with stable identity"
    else
        IDENTITY="-"
        echo "▸ signing ad-hoc (Accessibility must be re-granted after each rebuild)"
        echo "  to fix permanently, see: make-signing-cert.md"
    fi
fi

codesign --force --deep --sign "$IDENTITY" "$APP"
if [ "$RELEASE" = "1" ]; then
    codesign --verify --strict --deep "$APP"
    if /usr/libexec/PlistBuddy -c "Print :WhisprDevelopmentPythonPath" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
        echo "error: release Info.plist contains a development Python path" >&2
        exit 1
    fi
fi

echo "✓ built $APP"
if [ "$RELEASE" = "1" ]; then
    echo "  runtime: $RUNTIME_URL"
else
    echo "  python: $PYTHON"
fi
echo
echo "  open $APP"
