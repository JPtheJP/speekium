#!/bin/bash
# System/package E2E for custom recording shortcuts.
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(cd .. && pwd)"
APP="$(printenv WHISPR_E2E_APP || true)"
if [ -z "$APP" ]; then APP="$PROJECT_ROOT/WhisprStream.app"; fi
EXPECTED_VERSION="$(printenv WHISPR_E2E_VERSION || true)"
if [ -z "$EXPECTED_VERSION" ]; then EXPECTED_VERSION=1.0.2; fi
EXPECTED_BUILD="$(printenv WHISPR_E2E_BUILD_NUMBER || true)"
if [ -z "$EXPECTED_BUILD" ]; then EXPECTED_BUILD=3; fi
SKIP_BUILD="$(printenv WHISPR_E2E_SKIP_BUILD || true)"
if [ -z "$SKIP_BUILD" ]; then SKIP_BUILD=0; fi
E2E_TMP="$(mktemp -d /tmp/whispr-trigger-shortcut-e2e.XXXXXX)"
STATUS="$E2E_TMP/status"
APP_LOG="$E2E_TMP/app.log"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$E2E_TMP"
}
trap cleanup EXIT

if [ "$SKIP_BUILD" != "1" ]; then
    echo "▸ building WhisprStream $EXPECTED_VERSION"
    VERSION="$EXPECTED_VERSION" \
        BUILD_NUMBER="$EXPECTED_BUILD" \
        RELEASE=0 \
        APP="$APP" \
        ./build.sh
fi

[ -d "$APP" ] || {
    echo "error: app not found at $APP" >&2
    exit 1
}

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
APP_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
APP_BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$EXPECTED_VERSION" ] || {
    echo "error: app version is $APP_VERSION; expected $EXPECTED_VERSION" >&2
    exit 1
}
[ "$APP_BUILD" = "$EXPECTED_BUILD" ] || {
    echo "error: app build is $APP_BUILD; expected $EXPECTED_BUILD" >&2
    exit 1
}
[[ "$APP_BUNDLE_IDENTIFIER" == dev.* ]] || {
    echo "error: packaged shortcut E2E is available only in a development bundle" >&2
    exit 1
}

echo "▸ launching packaged shortcut E2E"
"$APP/Contents/MacOS/WhisprStream" \
    --whispr-e2e-trigger-shortcut \
    "--whispr-e2e-status=$STATUS" >"$APP_LOG" 2>&1 &
APP_PID="$!"

for _ in {1..400}; do
    if [ -f "$STATUS" ] && [ "$(<"$STATUS")" = "completed" ]; then
        echo "✓ trigger-shortcut E2E passed"
        exit 0
    fi
    if [ -f "$STATUS" ] && [[ "$(<"$STATUS")" == failed:* ]]; then
        echo "error: $(<"$STATUS")" >&2
        cat "$APP_LOG" >&2
        exit 1
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        wait "$APP_PID" 2>/dev/null || true
        echo "error: packaged shortcut E2E exited without a status" >&2
        cat "$APP_LOG" >&2
        exit 1
    fi
    sleep 0.05
done

if [ -f "$STATUS" ]; then
    echo "error: $(<"$STATUS")" >&2
else
    echo "error: timed out waiting for packaged shortcut E2E" >&2
fi
cat "$APP_LOG" >&2
exit 1
