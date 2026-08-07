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
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
RELEASE="${RELEASE:-0}"
RUNTIME_URL="${RUNTIME_URL:-}"
RUNTIME_SHA256="${RUNTIME_SHA256:-}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-dev.local.whisprstream}"

if [ "$RELEASE" = "1" ]; then
    if [ -z "$RUNTIME_URL" ] || [ -z "$RUNTIME_SHA256" ]; then
        echo "error: release builds require RUNTIME_URL and RUNTIME_SHA256" >&2
        exit 1
    fi
    if ! [[ "$RUNTIME_URL" =~ ^https:// ]] || ! [[ "$RUNTIME_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "error: RUNTIME_URL must be HTTPS and RUNTIME_SHA256 must be a SHA-256 hash" >&2
        exit 1
    fi
    DEVELOPMENT_PYTHON=""
else
    if [ ! -x "$PYTHON" ]; then
        echo "error: no python at $PYTHON" >&2
        echo "       set PYTHON=/path/to/python and re-run" >&2
        exit 1
    fi
    # Local builds continue to use the prepared venv. RELEASE=1 deliberately
    # clears this value so no developer-specific path is shipped to users.
    DEVELOPMENT_PYTHON="$PYTHON"
fi

echo "▸ compiling"
swift build -c release

BIN=".build/release/WhisprStream"
[ -x "$BIN" ] || { echo "error: build produced no binary" >&2; exit 1; }

echo "▸ assembling $(basename "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/WhisprStream"
cp Resources/asr_server.py "$APP/Contents/Resources/"
cp Resources/model_download.py "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/asr_engine.py" "$APP/Contents/Resources/"

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
    <key>WhisprDevelopmentPythonPath</key><string>$DEVELOPMENT_PYTHON</string>
    <key>WhisprRuntimeURL</key><string>$RUNTIME_URL</string>
    <key>WhisprRuntimeSHA256</key><string>$RUNTIME_SHA256</string>
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
IDENTITY="-"
# The -v flag filters to identities whose certificate chain is trusted. A local
# self-signed identity can still sign successfully (and gives TCC a stable leaf
# certificate) even when Keychain reports the chain as untrusted, so look
# through all matching code-signing identities instead.
if security find-identity -p codesigning 2>/dev/null | grep -q "WhisprStream Self-Signed"; then
    IDENTITY="WhisprStream Self-Signed"
    echo "▸ signing with stable identity"
else
    echo "▸ signing ad-hoc (Accessibility must be re-granted after each rebuild)"
    echo "  to fix permanently, see: make-signing-cert.md"
fi

codesign --force --deep --sign "$IDENTITY" "$APP"

echo "✓ built $APP"
if [ "$RELEASE" = "1" ]; then
    echo "  runtime: $RUNTIME_URL"
else
    echo "  python: $PYTHON"
fi
echo
echo "  open $APP"
