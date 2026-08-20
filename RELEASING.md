# Speekium release checklist

Speekium ships a small native app and a separately downloadable Apple-silicon speech engine. Public builds are ZIPs, are not notarized, and use a stable self-signed identity.

## 1. Build and validate the runtime

Use a relocatable standalone CPython 3.12 distribution. Do not use Homebrew Python or a venv.

```bash
SIGNING_IDENTITY="Speekium Self-Signed" \
SOURCE_PYTHON=/path/to/python-build-standalone/install/bin/python3.12 \
RUNTIME_VERSION=1.0.0 RELEASE=1 \
Speekium/build-runtime.sh
```

The script installs only `requirements-macos-arm64.txt`, runs the import/version health check, checks for build-machine paths, signs Mach-O files, verifies signatures, writes `runtime/manifest.json`, and emits a machine-readable `.metadata.json` file with archive size, installed size, and SHA-256.

Create the runtime release asset as `Speekium-runtime-1.0.0-arm64.zip` and record its metadata.

## 2. Build the app

The app must embed an immutable tag-specific runtime URL, never `latest/download`:

```bash
RELEASE=1 VERSION=1.0.0 BUILD_NUMBER=1 \
BUNDLE_IDENTIFIER="com.jpthejp.speekium" \
SIGNING_IDENTITY="Speekium Self-Signed" \
RUNTIME_VERSION=1.0.0 \
RUNTIME_URL="https://github.com/JPtheJP/speekium/releases/download/v1.0.0/Speekium-runtime-1.0.0-arm64.zip" \
RUNTIME_SHA256="<64-character-runtime-sha256>" \
RUNTIME_ARCHIVE_BYTES="<archive-bytes>" \
RUNTIME_INSTALLED_BYTES="<installed-bytes>" \
Speekium/build.sh
```

`RELEASE=1` fails if any runtime value is missing, malformed, zero, non-HTTPS, or if the bundle identifier is not `com.jpthejp.speekium`. It also fails without a signing identity; it never silently falls back to ad-hoc signing.

Archive the app with macOS metadata preserved:

```bash
ditto -c -k --sequesterRsrc --keepParent \
  Speekium.app Speekium-macos-arm64.zip
```

Create `SHA256SUMS` for both assets and run the read-only validator after extracting the app archive:

```bash
shasum -a 256 Speekium-macos-arm64.zip Speekium-runtime-1.0.0-arm64.zip > SHA256SUMS
Speekium/validate-release.sh Speekium-macos-arm64.zip \
  Speekium-runtime-1.0.0-arm64.zip SHA256SUMS
```

## 3. Stable self-signing

Create one certificate using [`make-signing-cert.md`](Speekium/make-signing-cert.md), keep its private key outside the repository, and back it up securely. Reuse the same identity for every release; losing the key changes the app's code identity and may require permissions to be granted again.

Self-signing does not provide Apple trust, does not notarize the app, and does not remove the unknown-developer warning. Release notes must point users to **System Settings → Privacy & Security → Open Anyway**. Never tell users to disable Gatekeeper or run broad `xattr` commands.

## 4. Draft release and clean-Mac qualification

For the first release, create a draft GitHub Release tagged `v1.0.0`, upload:

- `Speekium-macos-arm64.zip`
- `Speekium-runtime-1.0.0-arm64.zip`
- `SHA256SUMS`

Then download both assets back from GitHub and verify their hashes. Before publishing, test the browser-downloaded, quarantined app on:

- a clean macOS 14 Apple-silicon Mac with no Python or Xcode;
- a Mac with Homebrew Python 3.13;
- an active Conda/pyenv environment and poisoned `PYTHONPATH`;
- an 8 GB base M-series Mac and a 16 GB or greater Mac;
- offline, insufficient-space, cancelled-download, checksum-failure, partial-model-cleanup, permission-skip, and update scenarios.

Record failure-state screenshots and logs. Verify that an app replacement preserves the runtime, model cache, and permissions; document any Accessibility re-grant honestly if macOS requires it.

## 5. Website and update checks

Confirm the website's download link resolves to the stable app asset and that all source links resolve to [github.com/JPtheJP/speekium](https://github.com/JPtheJP/speekium). The website must not advertise a Homebrew command until a real Cask exists.

In Settings → About, confirm that the update checker accepts exact stable semantic versions such as `v1.0.1`, ignores drafts and prereleases, and opens the release page without modifying the running app.

## Local developer test mode

Local builds can use the prepared venv. To exercise the first-run UI without touching real runtime, model, preference, or permission files:

```bash
# Quit any currently running Speekium menu-bar process first.
SPEEKIUM_TEST_FIRST_RUN=1 Speekium.app/Contents/MacOS/Speekium
```

The flag belongs to the process being launched; opening the app from Finder,
or leaving an older menu-bar instance running, does not pass it to that
instance. Local builds also accept the equivalent explicit argument:

```bash
Speekium.app/Contents/MacOS/Speekium --speekium-test-first-run
```

The launch log records `developerTestMode=true` when the simulator is active.
In a local build, Settings → Engine also has “Enter simulated first run” for
testing without relaunching.

This mode is developer-only and is never included as a public runtime path.
