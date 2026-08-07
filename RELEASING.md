# Packaging a lightweight WhisprStream release

WhisprStream ships the menu-bar app separately from the Python/MLX speech
engine. This keeps the app archive small while allowing a user to download the
larger engine only once, after first launch.

## Runtime archive contract

Build the Apple-silicon runtime outside the app bundle, zip it, and upload the
zip to the matching GitHub Release. Its zip layout must be:

```text
runtime/
  bin/python3.12
  ...Python standard library and pinned MLX dependencies...
```

The runtime must be a self-contained, arm64 Python 3.12 environment: a venv
that points at the build machine's Python is not distributable. Sign the Python
binary and native libraries with the same Developer ID identity before creating
the archive.

[`WhisprStream/build-runtime.sh`](WhisprStream/build-runtime.sh) creates this
layout. It takes a relocatable CPython 3.12 distribution as input; a normal
Homebrew Python and a venv are intentionally not supported because they retain
machine-specific paths. For example:

```bash
SOURCE_PYTHON=/path/to/python-build-standalone/install/bin/python3.12 \
VERSION=1.0.0 WhisprStream/build-runtime.sh
```

Calculate its immutable checksum:

```bash
shasum -a 256 WhisprStream-runtime-1.0.0-arm64.zip
```

## Build an app release

`RELEASE=1` prevents the build script from writing the local development venv
path into `Info.plist`. It requires the runtime's HTTPS release URL and SHA-256:

```bash
RELEASE=1 VERSION=1.0.0 BUILD_NUMBER=1 \
BUNDLE_IDENTIFIER="com.leoleo.whisprstream" \
RUNTIME_URL="https://github.com/Leo6Leo/whispr-stream/releases/download/v1.0.0/WhisprStream-runtime-1.0.0-arm64.zip" \
RUNTIME_SHA256="<64-character-runtime-sha256>" \
WhisprStream/build.sh
```

The first launch verifies the archive before unpacking it to:

```text
~/Library/Application Support/WhisprStream/Runtime
```

It will not execute an archive with a missing or mismatched checksum.

## Test the first-run experience locally

Local builds normally use the existing development venv. To see the complete
first-run engine screen without deleting that venv, models, preferences, or
permissions, start the app binary with:

```bash
WHISPR_TEST_FIRST_RUN=1 WhisprStream.app/Contents/MacOS/WhisprStream
```

The flag hides every real runtime and model cache, then simulates both download
steps. Once complete, the app temporarily uses the local development Python
only for that test session. Each launch with the flag starts fresh; use the
**Reset simulated first run** button in Settings → Engine to repeat setup
without quitting. This developer-only mode never deletes or downloads anything.

For public distribution, replace the development signing in `build.sh` with a
Developer ID Application identity, hardened runtime, timestamp, and Apple
notarization. Archive the stapled application as a zip or DMG only after that.

## Homebrew

Homebrew should install the small, notarized app as a Cask. The app installs its
verified runtime at first launch, so the Cask does not need to run `pip` or
depend on a user-owned virtual environment. Publish it in a personal tap first,
then submit it to Homebrew/homebrew-cask once releases are stable.
