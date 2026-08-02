#!/bin/bash
# Build WhisprStream.app.
#
# The ASR runs as a Python sidecar, so the bundle records the interpreter to use.
# Pass a different one with:  PYTHON=/path/to/python ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(cd .. && pwd)"
PYTHON="${PYTHON:-$PROJECT_ROOT/.venv/bin/python}"
APP="${APP:-$PROJECT_ROOT/WhisprStream.app}"

if [ ! -x "$PYTHON" ]; then
    echo "error: no python at $PYTHON" >&2
    echo "       set PYTHON=/path/to/python and re-run" >&2
    exit 1
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
    <key>CFBundleIdentifier</key><string>dev.local.whisprstream</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WhisprStream</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisprStream transcribes your speech on-device.</string>
    <key>WhisprPythonPath</key><string>$PYTHON</string>
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
if security find-identity -v -p codesigning 2>/dev/null | grep -q "WhisprStream Self-Signed"; then
    IDENTITY="WhisprStream Self-Signed"
    echo "▸ signing with stable identity"
else
    echo "▸ signing ad-hoc (Accessibility must be re-granted after each rebuild)"
    echo "  to fix permanently, see: make-signing-cert.md"
fi

codesign --force --deep --sign "$IDENTITY" "$APP"

echo "✓ built $APP"
echo "  python: $PYTHON"
echo
echo "  open $APP"
