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
RUNTIME_VERSION="${RUNTIME_VERSION:-${VERSION:?set RUNTIME_VERSION, e.g. 1.0.0}}"
OUTPUT="${OUTPUT:-$PROJECT_ROOT/WhisprStream-runtime-$RUNTIME_VERSION-arm64.zip}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
DEPENDENCY_SET="${DEPENDENCY_SET:-mlx-qwen3-asr-0.3.5}"
RELEASE="${RELEASE:-1}"
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
file "$SOURCE_PYTHON" | grep -q 'arm64' || {
    echo "error: SOURCE_PYTHON must be an arm64 executable" >&2
    exit 1
}
if [ "$RELEASE" = "1" ] && { [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; }; then
    echo "error: RELEASE=1 requires SIGNING_IDENTITY; ad-hoc signing is not allowed" >&2
    exit 1
fi

PYTHON_VERSION="$($SOURCE_PYTHON -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
if [ "$PYTHON_VERSION" != "3.12" ]; then
    echo "error: runtime requires Python 3.12 (found $PYTHON_VERSION)" >&2
    exit 1
fi

SOURCE_PREFIX="$($SOURCE_PYTHON -c 'import sys; print(sys.prefix)')"
SOURCE_BASE_PREFIX="$($SOURCE_PYTHON -c 'import sys; print(sys.base_prefix)')"
if [ ! -d "$SOURCE_PREFIX" ]; then
    echo "error: could not find Python prefix $SOURCE_PREFIX" >&2
    exit 1
fi
if [ "$SOURCE_PREFIX" != "$SOURCE_BASE_PREFIX" ]; then
    echo "error: SOURCE_PYTHON is a virtual environment; use standalone CPython 3.12" >&2
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
"$RUNTIME_PYTHON" -m pip install --disable-pip-version-check --no-cache-dir -r "$PROJECT_ROOT/requirements-macos-arm64.txt"

# The release is code-signed after this script runs. Removing bytecode caches
# and pip's cache makes the archive smaller without removing runtime content.
find "$RUNTIME" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$RUNTIME" -type d -name .pytest_cache -prune -exec rm -rf {} +

MLX_VERSION="$(awk -F== '$1 == "mlx" {print $2}' "$PROJECT_ROOT/requirements-macos-arm64.txt")"
NUMPY_VERSION="$(awk -F== '$1 == "numpy" {print $2}' "$PROJECT_ROOT/requirements-macos-arm64.txt")"
HF_VERSION="$(awk -F== '$1 == "huggingface-hub" {print $2}' "$PROJECT_ROOT/requirements-macos-arm64.txt")"
ASR_VERSION="$(awk -F== '$1 == "mlx-qwen3-asr" {print $2}' "$PROJECT_ROOT/requirements-macos-arm64.txt")"
INSTALLED_BYTES="$(du -sk "$RUNTIME" | awk '{print $1 * 1024}')"
cat > "$RUNTIME/manifest.json" <<MANIFEST
{
  "schemaVersion": 1,
  "runtimeVersion": "$RUNTIME_VERSION",
  "pythonVersion": "$($RUNTIME_PYTHON -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')",
  "architecture": "arm64",
  "minimumMacOS": "14.0",
  "dependencySet": "$DEPENDENCY_SET",
  "payloadBytes": $INSTALLED_BYTES,
  "dependencyVersions": {
    "mlx": "$MLX_VERSION",
    "numpy": "$NUMPY_VERSION",
    "huggingface-hub": "$HF_VERSION",
    "mlx-qwen3-asr": "$ASR_VERSION"
  }
}
MANIFEST

echo "▸ validating relocatability and imports"
PYTHONNOUSERSITE=1 PYTHONPATH= PYTHONHOME= VIRTUAL_ENV= \
    "$RUNTIME_PYTHON" -s -u -c 'import mlx, numpy, huggingface_hub, mlx_qwen3_asr; print("health check: ok")'
for SOURCE_PATH in "$SOURCE_PREFIX" "$PROJECT_ROOT"; do
    if rg -a -F -l --hidden --no-messages "$SOURCE_PATH" "$RUNTIME" >/dev/null; then
        echo "error: runtime contains build-machine path $SOURCE_PATH" >&2
        exit 1
    fi
done

if [ "$RELEASE" = "1" ]; then
    echo "▸ signing Mach-O runtime files"
    while IFS= read -r FILE; do
        codesign --force --sign "$SIGNING_IDENTITY" "$FILE"
    done < <(find "$RUNTIME" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ {print $1}')

    while IFS= read -r FILE; do
        codesign --verify --strict "$FILE"
    done < <(find "$RUNTIME" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ {print $1}')
fi

INSTALLED_BYTES="$(du -sk "$RUNTIME" | awk '{print $1 * 1024}')"
python3 - "$RUNTIME/manifest.json" "$INSTALLED_BYTES" <<'PY'
import json, sys
path, payload = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["payloadBytes"] = payload
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY

echo "▸ creating $(basename "$OUTPUT")"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$STAGING" && ditto -c -k runtime "$OUTPUT")
ARCHIVE_BYTES="$(stat -f%z "$OUTPUT")"
ARCHIVE_SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
cat > "${OUTPUT%.zip}.metadata.json" <<META
{
  "runtimeVersion": "$RUNTIME_VERSION",
  "archive": "$(basename "$OUTPUT")",
  "archiveBytes": $ARCHIVE_BYTES,
  "installedBytes": $INSTALLED_BYTES,
  "sha256": "$ARCHIVE_SHA256"
}
META

echo "✓ runtime archive created"
echo "archive bytes: $ARCHIVE_BYTES"
echo "installed bytes: $INSTALLED_BYTES"
echo "sha256: $ARCHIVE_SHA256"
