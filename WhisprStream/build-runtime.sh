#!/bin/bash
# Create the separately downloadable Apple-silicon Python/MLX runtime.
#
# SOURCE_PYTHON must come from a relocatable, standalone CPython 3.12
# distribution (for example python-build-standalone). Do not point it at a
# Homebrew Python or a venv: those refer back to paths which do not exist on a
# user's Mac after the archive is extracted.
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(cd .. && pwd)"
SOURCE_PYTHON="${SOURCE_PYTHON:?set SOURCE_PYTHON to a standalone Python 3.12 executable}"
VERSION="${VERSION:?set VERSION, e.g. 1.0.0}"
OUTPUT="${OUTPUT:-$PROJECT_ROOT/WhisprStream-runtime-$VERSION-arm64.zip}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/whisprstream-runtime.XXXXXX")"
RUNTIME="$STAGING/runtime"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: the WhisprStream runtime is Apple-silicon only" >&2
    exit 1
fi
if [ ! -x "$SOURCE_PYTHON" ]; then
    echo "error: no executable Python at $SOURCE_PYTHON" >&2
    exit 1
fi

PYTHON_VERSION="$($SOURCE_PYTHON -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
if [ "$PYTHON_VERSION" != "3.12" ]; then
    echo "error: runtime requires Python 3.12 (found $PYTHON_VERSION)" >&2
    exit 1
fi

SOURCE_PREFIX="$($SOURCE_PYTHON -c 'import sys; print(sys.prefix)')"
if [ ! -d "$SOURCE_PREFIX" ]; then
    echo "error: could not find Python prefix $SOURCE_PREFIX" >&2
    exit 1
fi

echo "▸ copying standalone Python"
ditto "$SOURCE_PREFIX" "$RUNTIME"
RUNTIME_PYTHON="$RUNTIME/bin/python3.12"
if [ ! -x "$RUNTIME_PYTHON" ] && [ -x "$RUNTIME/bin/python3" ]; then
    ln -s python3 "$RUNTIME_PYTHON"
fi
if [ ! -x "$RUNTIME_PYTHON" ]; then
    echo "error: copied distribution has no bin/python3.12" >&2
    exit 1
fi

echo "▸ installing pinned ASR dependencies"
"$RUNTIME_PYTHON" -m pip install --upgrade pip
"$RUNTIME_PYTHON" -m pip install --no-cache-dir -r "$PROJECT_ROOT/requirements-macos-arm64.txt"

# The release is code-signed after this script runs. Removing bytecode caches
# and pip's cache makes the archive smaller without removing runtime content.
find "$RUNTIME" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$RUNTIME" -type d -name .pytest_cache -prune -exec rm -rf {} +

echo "▸ creating $(basename "$OUTPUT")"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$STAGING" && ditto -c -k runtime "$OUTPUT")

echo "✓ runtime archive created"
shasum -a 256 "$OUTPUT"
