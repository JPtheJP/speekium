#!/bin/bash
# System E2E for context-aware capitalization and cross-app insertion.
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(cd .. && pwd)"
APP="${SPEEKIUM_E2E_APP:-$PROJECT_ROOT/Speekium.app}"
EXPECTED="Hello this testing works. "
E2E_TMP="$(mktemp -d /tmp/speekium-context-e2e.XXXXXX)"
HELPER_APP="$E2E_TMP/ContextAwareEditor.app"
HELPER="$HELPER_APP/Contents/MacOS/ContextAwareEditor"
HELPER_PLIST="$HELPER_APP/Contents/Info.plist"
READY="$E2E_TMP/ready"
RESULT="$E2E_TMP/result"
STATUS="$E2E_TMP/status"
HELPER_PID=""

cleanup() {
    if [ -n "$HELPER_PID" ]; then
        kill "$HELPER_PID" 2>/dev/null || true
        wait "$HELPER_PID" 2>/dev/null || true
    fi
    rm -rf "$E2E_TMP"
}
trap cleanup EXIT

echo "▸ building Speekium"
./build.sh

echo "▸ compiling destination editor"
mkdir -p "$HELPER_APP/Contents/MacOS"
xcrun swiftc E2E/ContextAwareEditor.swift -framework AppKit -o "$HELPER"
plutil -create xml1 "$HELPER_PLIST"
plutil -insert CFBundleName -string ContextAwareEditor "$HELPER_PLIST"
plutil -insert CFBundleDisplayName -string ContextAwareEditor "$HELPER_PLIST"
plutil -insert CFBundleIdentifier -string dev.local.speekium-context-e2e "$HELPER_PLIST"
plutil -insert CFBundleVersion -string 1 "$HELPER_PLIST"
plutil -insert CFBundleShortVersionString -string 1.0 "$HELPER_PLIST"
plutil -insert CFBundlePackageType -string APPL "$HELPER_PLIST"
plutil -insert CFBundleExecutable -string ContextAwareEditor "$HELPER_PLIST"
codesign --force --deep --sign - "$HELPER_APP"

echo "▸ launching destination editor"
open -n "$HELPER_APP" --args "$READY" "$RESULT"

for _ in {1..100}; do
    [ -f "$READY" ] && break
    sleep 0.05
done
[ -f "$READY" ] || {
    echo "error: timed out waiting for destination editor" >&2
    exit 1
}
HELPER_PID="$(<"$READY")"
kill -0 "$HELPER_PID" 2>/dev/null || {
    echo "error: destination editor exited before the probe" >&2
    exit 1
}

echo "▸ probing context, adjusting capitalization, and inserting"
open -g -n "$APP" --args \
    --speekium-e2e-context-aware-capitalization \
    "--speekium-e2e-status=$STATUS" \
    "--speekium-e2e-target-pid=$HELPER_PID"

for _ in {1..100}; do
    if [ -f "$STATUS" ] && [ "$(<"$STATUS")" = "completed" ] \
        && [ -f "$RESULT" ] && [ "$(<"$RESULT")" = "$EXPECTED" ]; then
        echo "✓ context-aware capitalization E2E passed"
        echo "  observed: $(<"$RESULT")"
        exit 0
    fi
    if [ -f "$STATUS" ] && [[ "$(<"$STATUS")" == failed:* ]]; then
        echo "error: $(<"$STATUS")" >&2
        exit 1
    fi
    sleep 0.05
done

OBSERVED="<missing>"
[ -f "$RESULT" ] && OBSERVED="$(<"$RESULT")"
echo "error: expected '$EXPECTED', observed '$OBSERVED'" >&2
exit 1
