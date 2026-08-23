# WhisprStream release checklist

WhisprStream ships a small native app and a separately downloadable Apple-silicon speech engine. Public builds are ZIPs, are not notarized, and use a stable self-signed identity.

## 1. Build and validate the runtime

Use a relocatable standalone CPython 3.12 distribution. Do not use Homebrew Python or a venv.

```bash
SIGNING_IDENTITY="WhisprStream Self-Signed" \
SOURCE_PYTHON=/path/to/python-build-standalone/install/bin/python3.12 \
RUNTIME_VERSION=1.0.0 RELEASE=1 \
WhisprStream/build-runtime.sh
```

The script installs only `requirements-macos-arm64.txt`, explicitly selects macOS 14 arm64 wheels regardless of the builder's macOS version, runs the import/version health check, rejects Mach-O files with a deployment target above macOS 14, checks for build-machine paths, signs and verifies every Mach-O file, writes `runtime/manifest.json`, and emits a machine-readable `.metadata.json` file with archive size, installed size, and SHA-256.

Create the runtime release asset as `WhisprStream-runtime-1.0.0-arm64.zip` and record its metadata.

## 2. Build the app

The app must embed an immutable tag-specific runtime URL, never `latest/download`:

The updater's Ed25519 private key lives only in the macOS login Keychain. Its
public key is checked in at `WhisprStream/update-public-key.txt` and embedded in
every build. Generate the key only once; subsequent invocations print the same
public key:

```bash
swift build -c release --package-path WhisprStream \
  --product WhisprStreamUpdateSigner
codesign --force --sign "WhisprStream Self-Signed" \
  WhisprStream/.build/release/WhisprStreamUpdateSigner
WhisprStream/.build/release/WhisprStreamUpdateSigner generate
```

Always use the stably signed release tool for `generate`, `export`, and `sign`.
Its code identity is what allows macOS Keychain access to survive later tool
rebuilds; do not create the production key with an ad-hoc debug executable.

Back up the private key to encrypted offline storage, never to this repository:

```bash
WhisprStream/.build/release/WhisprStreamUpdateSigner export \
  /path/outside/the/repository/WhisprStream-update-private-key.txt
```

Losing both the Keychain item and its backup breaks the automatic-update chain
for installed versions. Do not rotate this key as part of a normal release.

App version `1.0.1` intentionally reuses runtime version `1.0.0`; the runtime
version changes only when the standalone Python or dependency payload changes.

```bash
RELEASE=1 VERSION=1.0.1 BUILD_NUMBER=2 \
BUNDLE_IDENTIFIER="com.leoleo.whisprstream" \
SIGNING_IDENTITY="WhisprStream Self-Signed" \
RUNTIME_VERSION=1.0.0 \
RUNTIME_URL="https://github.com/Leo6Leo/whispr-stream/releases/download/v1.0.0/WhisprStream-runtime-1.0.0-arm64.zip" \
RUNTIME_SHA256="<64-character-runtime-sha256>" \
RUNTIME_ARCHIVE_BYTES="<archive-bytes>" \
RUNTIME_INSTALLED_BYTES="<installed-bytes>" \
WhisprStream/build.sh
```

`RELEASE=1` fails if any runtime value is missing, malformed, zero, non-HTTPS, or if the bundle identifier is not `com.leoleo.whisprstream`. It also fails without a signing identity; it never silently falls back to ad-hoc signing. Release compilation remaps the repository root to `/src`, strips linker-generated `N_OSO` debug records, and both the builder and validator reject executables containing `/Users/` or `/home/` build-machine paths.
The same release identity is also applied to the update-signing utility so it
can reuse the protected Keychain item when the utility is rebuilt.

Archive the app with macOS metadata preserved:

```bash
ditto -c -k --sequesterRsrc --keepParent \
  WhisprStream.app WhisprStream-macos-arm64.zip
WhisprStream/.build/release/WhisprStreamUpdateSigner sign \
  WhisprStream-macos-arm64.zip WhisprStream-macos-arm64.zip.ed25519
```

Create `SHA256SUMS` for all three artifacts and run the read-only validator.
The validator checks the detached update signature, extracts the app with macOS
metadata preserved, and rejects an unexpected app version or build number:

```bash
shasum -a 256 WhisprStream-macos-arm64.zip \
  WhisprStream-macos-arm64.zip.ed25519 \
  WhisprStream-runtime-1.0.0-arm64.zip > SHA256SUMS
WhisprStream/validate-release.sh WhisprStream-macos-arm64.zip \
  WhisprStream-runtime-1.0.0-arm64.zip SHA256SUMS \
  WhisprStream-macos-arm64.zip.ed25519 1.0.1 2
```

## 3. Stable self-signing

Create one certificate using [`make-signing-cert.md`](WhisprStream/make-signing-cert.md), keep its private key outside the repository, and back it up securely. Reuse the same identity for every release; losing the key changes the app's code identity and may require permissions to be granted again.

Self-signing does not provide Apple trust, does not notarize the app, and does not remove the unknown-developer warning. Release notes must point users to **System Settings → Privacy & Security → Open Anyway**. Never tell users to disable Gatekeeper or run broad `xattr` commands.

## 4. Draft release and clean-Mac qualification

For this release, create a draft GitHub Release tagged `v1.0.1`, upload:

- `WhisprStream-macos-arm64.zip`
- `WhisprStream-macos-arm64.zip.ed25519`
- `WhisprStream-runtime-1.0.0-arm64.zip`
- `SHA256SUMS`

Then download both assets back from GitHub and verify their hashes. Before publishing, test the browser-downloaded, quarantined app on:

- a clean macOS 14 Apple-silicon Mac with no Python or Xcode;
- a Mac with Homebrew Python 3.13;
- an active Conda/pyenv environment and poisoned `PYTHONPATH`;
- an 8 GB base M-series Mac and a 16 GB or greater Mac;
- offline, insufficient-space, cancelled-download, checksum-failure, partial-model-cleanup, permission-skip, and update scenarios.

Record failure-state screenshots and logs. Verify that an app replacement preserves the runtime, model cache, and permissions; document any Accessibility re-grant honestly if macOS requires it.

## 5. Website and update checks

Confirm the website's download link resolves to the stable app asset and that all source links resolve to [github.com/Leo6Leo/whispr-stream](https://github.com/Leo6Leo/whispr-stream). The website must not advertise a Homebrew command until a real Cask exists.

In Settings → About, confirm that the update checker accepts exact stable semantic versions such as `v1.0.1`, ignores drafts and prereleases, rejects missing, oversized, duplicate, or incorrectly signed assets, and offers **Install and Relaunch** only after discovering both exact update assets. Test a valid signed update end to end from a writable copy in Applications, including relaunch after a quarantined download, plus tampered-signature and read-only-location failures. Quarantine is cleared only from a replacement that has passed the pinned Ed25519 signature and bundle checks. The manual GitHub button must remain available as recovery.

## Local developer test mode

Local builds can use the prepared venv. To exercise the first-run UI without touching real runtime, model, preference, or permission files:

```bash
# Quit any currently running WhisprStream menu-bar process first.
WHISPR_TEST_FIRST_RUN=1 WhisprStream.app/Contents/MacOS/WhisprStream
```

The flag belongs to the process being launched; opening the app from Finder,
or leaving an older menu-bar instance running, does not pass it to that
instance. Local builds also accept the equivalent explicit argument:

```bash
WhisprStream.app/Contents/MacOS/WhisprStream --whispr-test-first-run
```

The launch log records `developerTestMode=true` when the simulator is active.
In a local build, Settings → Engine also has “Enter simulated first run” for
testing without relaunching.

This mode is developer-only and is never included as a public runtime path.
