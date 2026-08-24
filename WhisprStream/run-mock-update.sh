#!/bin/bash
# Launch a disposable debug app against a signed loopback update feed.
set -euo pipefail

usage() {
    cat <<'EOF'
usage: run-mock-update.sh [success|tampered-signature|wrong-size|wrong-version] [--prepare-only]

The script never modifies /Applications or the repository's WhisprStream.app.
Quit any running WhisprStream instance first. Press Control-C when finished.
EOF
    exit 2
}

SCENARIO=success
PREPARE_ONLY=false
for argument in "$@"; do
    case "$argument" in
        success|tampered-signature|wrong-size|wrong-version) SCENARIO="$argument" ;;
        --prepare-only) PREPARE_ONLY=true ;;
        *) usage ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_APP="$REPOSITORY_ROOT/WhisprStream.app"
BUILD_DIR="$SCRIPT_DIR/.build/debug"
TEST_ROOT="$(mktemp -d /tmp/whisprstream-mock-update.XXXXXX)"
FEED_ROOT="$TEST_ROOT/feed"
INSTALL_ROOT="$TEST_ROOT/install"
TARGET_APP="$INSTALL_ROOT/WhisprStream.app"
REPLACEMENT_APP="$TEST_ROOT/replacement/WhisprStream.app"
ARCHIVE="$FEED_ROOT/WhisprStream-macos-arm64.zip"
SIGNATURE="$FEED_ROOT/WhisprStream-macos-arm64.zip.ed25519"
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    case "$TEST_ROOT" in
        /tmp/whisprstream-mock-update.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT INT TERM

[ -d "$TEMPLATE_APP" ] || {
    echo "error: build WhisprStream.app once before running the mock updater" >&2
    exit 1
}
if [ "$PREPARE_ONLY" = false ] && pgrep -x WhisprStream >/dev/null 2>&1; then
    echo "error: quit the currently running WhisprStream process first" >&2
    exit 1
fi

echo "Building current debug executables..."
swift build --package-path "$SCRIPT_DIR" >/dev/null
for executable in WhisprStream WhisprStreamUpdateInstaller; do
    [ -x "$BUILD_DIR/$executable" ] || {
        echo "error: SwiftPM did not build $executable" >&2
        exit 1
    }
done

mkdir -p "$FEED_ROOT" "$INSTALL_ROOT" "$(dirname "$REPLACEMENT_APP")"
cp -R "$TEMPLATE_APP" "$TARGET_APP"
cp -R "$TEMPLATE_APP" "$REPLACEMENT_APP"
cp "$BUILD_DIR/WhisprStream" "$TARGET_APP/Contents/MacOS/WhisprStream"
cp "$BUILD_DIR/WhisprStream" "$REPLACEMENT_APP/Contents/MacOS/WhisprStream"
cp "$BUILD_DIR/WhisprStreamUpdateInstaller" \
    "$TARGET_APP/Contents/Helpers/WhisprStreamUpdateInstaller"
cp "$BUILD_DIR/WhisprStreamUpdateInstaller" \
    "$REPLACEMENT_APP/Contents/Helpers/WhisprStreamUpdateInstaller"

KEY_LINES="$(swift -e '
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
')"
PRIVATE_KEY="$(printf '%s\n' "$KEY_LINES" | sed -n '1p')"
PUBLIC_KEY="$(printf '%s\n' "$KEY_LINES" | sed -n '2p')"
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || {
    echo "error: could not generate an ephemeral update-signing key" >&2
    exit 1
}

configure_app() {
    local app="$1"
    local version="$2"
    local plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
    /usr/libexec/PlistBuddy -c "Set :WhisprUpdatePublicKey $PUBLIC_KEY" "$plist"
    /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$plist"
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
    codesign --force --deep --sign - "$app" >/dev/null 2>&1
}

configure_app "$TARGET_APP" 1.0.1
if [ "$SCENARIO" = "wrong-version" ]; then
    configure_app "$REPLACEMENT_APP" 9.9.8
else
    configure_app "$REPLACEMENT_APP" 9.9.9
fi

ditto -c -k --sequesterRsrc --keepParent "$REPLACEMENT_APP" "$ARCHIVE"
ARCHIVE_SIGNATURE="$(swift -e '
import CryptoKit
import Foundation
let privateData = Data(base64Encoded: CommandLine.arguments[1])!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
print(try key.signature(for: archive).base64EncodedString())
' "$PRIVATE_KEY" "$ARCHIVE")"
printf '%s\n' "$ARCHIVE_SIGNATURE" >"$SIGNATURE"
if [ "$SCENARIO" = "tampered-signature" ]; then
    printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==' \
        >"$SIGNATURE"
fi
set +e
swift -e '
import CryptoKit
import Darwin
import Foundation
let publicData = Data(base64Encoded: CommandLine.arguments[1])!
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let encoded = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let signature = Data(base64Encoded: encoded)!
exit(key.isValidSignature(signature, for: archive) ? 0 : 1)
' "$PUBLIC_KEY" "$ARCHIVE" "$SIGNATURE" >/dev/null 2>&1
SIGNATURE_STATUS=$?
set -e
if [ "$SCENARIO" = "tampered-signature" ]; then
    [ "$SIGNATURE_STATUS" -ne 0 ] || {
        echo "error: tampered-signature scenario unexpectedly has a valid signature" >&2
        exit 1
    }
else
    [ "$SIGNATURE_STATUS" -eq 0 ] || {
        echo "error: generated update signature is invalid" >&2
        exit 1
    }
fi

PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"
BASE_URL="http://127.0.0.1:$PORT"
ARCHIVE_BYTES="$(stat -f %z "$ARCHIVE")"
if [ "$SCENARIO" = "wrong-size" ]; then
    ARCHIVE_BYTES="$((ARCHIVE_BYTES + 1))"
fi
SIGNATURE_BYTES="$(stat -f %z "$SIGNATURE")"
python3 -c '
import json, sys
output, base_url, archive_bytes, signature_bytes = sys.argv[1:]
payload = {
    "tag_name": "v9.9.9",
    "html_url": "https://github.com/Leo6Leo/whispr-stream/releases/tag/v9.9.9",
    "draft": False,
    "prerelease": False,
    "assets": [
        {
            "name": "WhisprStream-macos-arm64.zip",
            "browser_download_url": base_url + "/WhisprStream-macos-arm64.zip",
            "size": int(archive_bytes),
        },
        {
            "name": "WhisprStream-macos-arm64.zip.ed25519",
            "browser_download_url": base_url + "/WhisprStream-macos-arm64.zip.ed25519",
            "size": int(signature_bytes),
        },
    ],
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
' "$FEED_ROOT/latest.json" "$BASE_URL" "$ARCHIVE_BYTES" "$SIGNATURE_BYTES"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED_ROOT" \
    >"$TEST_ROOT/server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..50}; do
    if curl -fsS "$BASE_URL/latest.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
curl -fsS "$BASE_URL/latest.json" >/dev/null || {
    echo "error: local update server did not start" >&2
    exit 1
}

if [ "$PREPARE_ONLY" = true ]; then
    curl -fsS "$BASE_URL/WhisprStream-macos-arm64.zip" \
        -o "$TEST_ROOT/downloaded.zip"
    curl -fsS "$BASE_URL/WhisprStream-macos-arm64.zip.ed25519" \
        -o "$TEST_ROOT/downloaded.zip.ed25519"
    cmp "$ARCHIVE" "$TEST_ROOT/downloaded.zip"
    cmp "$SIGNATURE" "$TEST_ROOT/downloaded.zip.ed25519"
    echo "Mock feed preparation check passed for scenario: $SCENARIO"
    echo "The repository app and /Applications were not touched."
    exit 0
fi

echo
echo "Mock update scenario: $SCENARIO"
echo "Temporary app: $TARGET_APP"
echo "Feed: $BASE_URL/latest.json"
echo "Open the menu-bar app, then Settings -> About -> Install and Relaunch."
echo "Press Control-C here when the test is finished; all temporary files will be removed."
echo

WHISPR_UPDATE_REPOSITORY=Leo6Leo/whispr-stream \
WHISPR_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" \
WHISPR_UPDATE_FEED_URL="$BASE_URL/latest.json" \
    "$TARGET_APP/Contents/MacOS/WhisprStream" &
APP_PID=$!
REPORTED_INSTALL=false
while kill -0 "$SERVER_PID" 2>/dev/null; do
    if [ "$REPORTED_INSTALL" = false ] && [ -f "$TARGET_APP/Contents/Info.plist" ]; then
        INSTALLED_VERSION="$(/usr/libexec/PlistBuddy \
            -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
        if [ "$INSTALLED_VERSION" = "9.9.9" ]; then
            echo "Mock version 9.9.9 is installed and the replacement was relaunched."
            REPORTED_INSTALL=true
        fi
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null && [ "$SCENARIO" != "success" ]; then
        echo "The initial app process exited. Review the About screen or log before stopping the harness."
        APP_PID=0
    fi
    sleep 0.5
done
