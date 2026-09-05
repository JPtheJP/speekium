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
SIGNING_CERT_SHA1_FILE="$PROJECT_ROOT/WhisprStream/release-signing-certificate-sha1.txt"
PINNED_SIGNING_CERT_SHA1=""
if [ -f "$SIGNING_CERT_SHA1_FILE" ]; then
    PINNED_SIGNING_CERT_SHA1="$(tr -d '\r\n' < "$SIGNING_CERT_SHA1_FILE" \
        | tr '[:upper:]' '[:lower:]')"
fi
DEPENDENCY_SET="${DEPENDENCY_SET:-mlx-qwen3-asr-0.3.5+mlx-whisper-0.4.3}"
RUNTIME_MINIMUM_MACOS="${RUNTIME_MINIMUM_MACOS:-14.0}"
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
if [ "$RELEASE" = "1" ] && ! [[ "$PINNED_SIGNING_CERT_SHA1" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: release signing-certificate pin is missing or malformed" >&2
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
SITE_PACKAGES="$RUNTIME/lib/python3.12/site-packages"
case "$SITE_PACKAGES" in
    "$RUNTIME"/*) ;;
    *) echo "error: unsafe runtime site-packages path" >&2; exit 1 ;;
esac
# A standalone distribution may contain build-time packages. Start the shipped
# site-packages tree from the reviewed lock instead of inheriting them.
rm -rf "$SITE_PACKAGES"
mkdir -p "$SITE_PACKAGES"
"$SOURCE_PYTHON" -m pip install \
    --disable-pip-version-check \
    --no-cache-dir \
    --no-deps \
    --require-hashes \
    --platform "macosx_${RUNTIME_MINIMUM_MACOS/./_}_arm64" \
    --implementation cp \
    --python-version 3.12 \
    --abi cp312 \
    --only-binary=:all: \
    --upgrade \
    --target "$SITE_PACKAGES" \
    -r "$PROJECT_ROOT/requirements-macos-arm64.lock"
"$SOURCE_PYTHON" -m pip install \
    --disable-pip-version-check \
    --no-cache-dir \
    --no-deps \
    --require-hashes \
    --platform "macosx_${RUNTIME_MINIMUM_MACOS/./_}_arm64" \
    --implementation cp \
    --python-version 3.12 \
    --abi cp312 \
    --only-binary=:all: \
    --upgrade \
    --target "$SITE_PACKAGES" \
    -r "$PROJECT_ROOT/requirements-macos-arm64-nodeps.lock"

MLX_VERSION="$(awk -F'[ =]' '$1 == "mlx" {print $3}' "$PROJECT_ROOT/requirements-macos-arm64.lock")"
NUMPY_VERSION="$(awk -F'[ =]' '$1 == "numpy" {print $3}' "$PROJECT_ROOT/requirements-macos-arm64.lock")"
HF_VERSION="$(awk -F'[ =]' '$1 == "huggingface-hub" {print $3}' "$PROJECT_ROOT/requirements-macos-arm64.lock")"
ASR_VERSION="$(awk -F'[ =]' '$1 == "mlx-qwen3-asr" {print $3}' "$PROJECT_ROOT/requirements-macos-arm64.lock")"
WHISPER_VERSION="$(awk -F'[ =]' '$1 == "mlx-whisper" {print $3}' "$PROJECT_ROOT/requirements-macos-arm64-nodeps.lock")"
INSTALLED_BYTES="$(du -sk "$RUNTIME" | awk '{print $1 * 1024}')"
cat > "$RUNTIME/manifest.json" <<MANIFEST
{
  "schemaVersion": 1,
  "runtimeVersion": "$RUNTIME_VERSION",
  "pythonVersion": "$($RUNTIME_PYTHON -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')",
  "architecture": "arm64",
  "minimumMacOS": "$RUNTIME_MINIMUM_MACOS",
  "dependencySet": "$DEPENDENCY_SET",
  "payloadBytes": $INSTALLED_BYTES,
  "dependencyVersions": {
    "mlx": "$MLX_VERSION",
    "numpy": "$NUMPY_VERSION",
    "huggingface-hub": "$HF_VERSION",
    "mlx-qwen3-asr": "$ASR_VERSION",
    "mlx-whisper": "$WHISPER_VERSION"
  }
}
MANIFEST

echo "▸ validating relocatability and imports"
PYTHONNOUSERSITE=1 PYTHONPATH= PYTHONHOME= VIRTUAL_ENV= \
    "$RUNTIME_PYTHON" -s -u -c 'import mlx, numpy, huggingface_hub, mlx_qwen3_asr, mlx_whisper; print("health check: ok")'
for SOURCE_PATH in "$SOURCE_PREFIX" "$PROJECT_ROOT"; do
    if rg -a -F -l --hidden --no-messages "$SOURCE_PATH" "$RUNTIME" >/dev/null; then
        echo "error: runtime contains build-machine path $SOURCE_PATH" >&2
        exit 1
    fi
done

version_at_most() {
    [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

echo "▸ validating Mach-O deployment targets"
while IFS= read -r FILE; do
    MINIMUM_OS="$(vtool -show-build "$FILE" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    if [ -z "$MINIMUM_OS" ] || ! version_at_most "$MINIMUM_OS" "$RUNTIME_MINIMUM_MACOS"; then
        echo "error: $FILE requires macOS ${MINIMUM_OS:-unknown}, above runtime minimum $RUNTIME_MINIMUM_MACOS" >&2
        exit 1
    fi
done < <(find "$RUNTIME" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ {print $1}')

if [ "$RELEASE" = "1" ]; then
    echo "▸ signing Mach-O runtime files"
    while IFS= read -r FILE; do
        codesign --force --sign "$SIGNING_IDENTITY" "$FILE"
    done < <(find "$RUNTIME" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ {print $1}')

    while IFS= read -r FILE; do
        codesign --verify --strict \
            -R="certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" "$FILE"
    done < <(find "$RUNTIME" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ {print $1}')
fi

# Imports above may have created bytecode. Remove it while the tree is still in
# private build staging; installed runtimes are authenticated without mutation.
python3 "$PROJECT_ROOT/WhisprStream/runtime-content-sha256.py" \
    --remove-bytecode "$RUNTIME" >/dev/null
find "$RUNTIME" -type d -name .pytest_cache -prune -exec rm -rf {} +

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

RUNTIME_CONTENT_SHA256="$(
    python3 "$PROJECT_ROOT/WhisprStream/runtime-content-sha256.py" "$RUNTIME"
)"

echo "▸ creating $(basename "$OUTPUT")"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$STAGING" && ditto -c -k --keepParent runtime "$OUTPUT")
ARCHIVE_TOP_LEVEL="$(zipinfo -1 "$OUTPUT" | awk -F/ 'NF {print $1}' | sort -u)"
if [ "$ARCHIVE_TOP_LEVEL" != "runtime" ]; then
    echo "error: runtime archive must contain exactly one top-level runtime directory" >&2
    exit 1
fi
ROUNDTRIP="$STAGING/roundtrip"
mkdir -p "$ROUNDTRIP"
ditto -x -k "$OUTPUT" "$ROUNDTRIP"
ROUNDTRIP_CONTENT_SHA256="$(
    python3 "$PROJECT_ROOT/WhisprStream/runtime-content-sha256.py" "$ROUNDTRIP/runtime"
)"
[ "$ROUNDTRIP_CONTENT_SHA256" = "$RUNTIME_CONTENT_SHA256" ] || {
    echo "error: archived runtime extracts to a different authenticated tree" >&2
    exit 1
}
ARCHIVE_BYTES="$(stat -f%z "$OUTPUT")"
ARCHIVE_SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
cat > "${OUTPUT%.zip}.metadata.json" <<META
{
  "runtimeVersion": "$RUNTIME_VERSION",
  "archive": "$(basename "$OUTPUT")",
  "archiveBytes": $ARCHIVE_BYTES,
  "installedBytes": $INSTALLED_BYTES,
  "sha256": "$ARCHIVE_SHA256",
  "contentSha256": "$RUNTIME_CONTENT_SHA256"
}
META

echo "✓ runtime archive created"
echo "archive bytes: $ARCHIVE_BYTES"
echo "installed bytes: $INSTALLED_BYTES"
echo "sha256: $ARCHIVE_SHA256"
echo "content sha256: $RUNTIME_CONTENT_SHA256"
