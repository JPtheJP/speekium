#!/bin/bash
# Prepare an Apple Silicon Mac to build and run WhisprStream.
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(pwd)"
VENV="${VENV:-$PROJECT_ROOT/.venv}"

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: WhisprStream requires an Apple Silicon Mac (arm64)" >&2
    exit 1
fi

PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    if command -v python3.12 >/dev/null 2>&1; then
        PYTHON="$(command -v python3.12)"
    elif command -v python3 >/dev/null 2>&1; then
        PYTHON="$(command -v python3)"
    else
        echo "error: Python 3 is required; install Python 3.12 and retry" >&2
        exit 1
    fi
fi

PYTHON_VERSION="$($PYTHON -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
if [ "$PYTHON_VERSION" != "3.12" ]; then
    echo "error: use Python 3.12 for the MLX environment (found $PYTHON_VERSION)" >&2
    echo "       install it with: brew install python@3.12" >&2
    echo "       or retry with: PYTHON=/path/to/python3.12 ./setup-mac.sh" >&2
    exit 1
fi

echo "▸ creating virtual environment at $VENV"
"$PYTHON" -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
echo "▸ installing Apple Silicon ASR dependencies"
"$VENV/bin/python" -m pip install -r requirements-macos-arm64.txt
"$VENV/bin/python" -m pip install --no-deps -r requirements-macos-arm64-nodeps.txt

echo "✓ setup complete"
echo "  next: ./WhisprStream/build.sh"
echo "  then: open WhisprStream.app"
