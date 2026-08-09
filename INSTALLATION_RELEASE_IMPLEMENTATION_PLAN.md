# WhisprStream installation and open-source release implementation plan

## Purpose

This document is an implementation handoff for Luna. It turns the current
development build into an open-source macOS release that users can download
from GitHub without installing Python, Xcode, Homebrew, or any Python packages.

The release will not use the paid Apple Developer Program. Consequently, the
app cannot be Apple-notarized and macOS will identify it as coming from an
unknown developer. The installation documentation must explain Apple's normal
**Open Anyway** workflow clearly. Do not advise users to disable Gatekeeper or
run broad `xattr` commands.

This plan intentionally keeps the speech engine and speech models as separate
downloads. They have different purposes and lifecycles:

- The **speech engine** is a private, relocatable CPython 3.12 environment with
  MLX and WhisprStream's pinned Python dependencies.
- A **speech model** contains replaceable Qwen3-ASR weights. Users select and
  download one model after the engine is ready.

## Product decisions that are already made

1. Support macOS 14 or later on Apple silicon only.
2. Normal users never install or configure Python.
3. Keep Python 3.12 as an internal, pinned runtime detail.
4. Install the engine under
   `~/Library/Application Support/WhisprStream/Runtime`.
5. Keep models in the Hugging Face cache, honoring `HF_HUB_CACHE` and
   `HF_HOME` when intentionally supplied.
6. Keep engine installation and model installation as separate onboarding
   steps.
7. Publish the app and runtime as GitHub Release assets.
8. Start with a ZIP distribution rather than a DMG. An unnotarized DMG does not
   remove the Gatekeeper warning and adds packaging complexity.
9. Use a stable self-signed code-signing identity for releases. It does not make
   Gatekeeper trust the app, but it gives releases a consistent code identity
   and should reduce permission churn. Verify that behavior on clean Macs.
10. Add free-space checks before both engine and model downloads.
11. Never automatically delete partial downloads. Present the amount and ask
    before removing them.
12. Recommend Qwen3-ASR 0.6B for most Macs. Present Qwen3-ASR 1.7B as an
    optional, larger, slower model that is best suited to machines with at least
    16 GB of unified memory.

## Current implementation baseline

The existing code already provides most of the application-level workflow:

- `WhisprStreamApp.swift` checks whether the runtime and selected model exist,
  then opens onboarding when either is missing.
- `OnboardingView.swift` contains welcome, engine, model, permissions,
  preferences, output, optional Voice Shortcut, and ready steps.
- `RuntimeManager.swift` downloads a runtime ZIP over HTTPS, verifies a bundled
  SHA-256, extracts into a staging directory, and atomically swaps it into
  Application Support.
- `ModelDownloader.swift` invokes `model_download.py` using the private runtime.
- `ModelCatalog.swift` verifies that all model weight files referenced by a
  snapshot are present.
- `Permissions.swift` manages Microphone and Accessibility permission guidance.
- `AppUpdateManager.swift` checks stable GitHub releases and opens the release
  page for a manual update.
- `build-runtime.sh`, `build.sh`, and `RELEASING.md` describe a separate runtime
  and app release.

The current checked-out `WhisprStream.app` is not distributable. It uses the
development bundle identifier, has no release runtime URL, embeds an absolute
path to the maintainer's `.venv`, and is not signed by a portable release
identity. Some update-related source changes are also currently uncommitted.
Luna must preserve and incorporate those changes rather than overwriting them.

Measured development sizes on the maintainer's Mac are:

| Component | Current measured or estimated size |
| --- | ---: |
| Native app bundle | 3.3 MB installed |
| Python packages in `.venv` | 266 MB installed |
| Base Python 3.12 installation | approximately 73 MB installed |
| Expected relocatable engine | approximately 340–400 MB installed |
| Estimated compressed engine | approximately 100–150 MB download |
| Qwen3-ASR 0.6B snapshot | approximately 1.9 GB |
| Qwen3-ASR 1.7B complete snapshot | approximately 4.3 GB; verify during release |

The existing UI estimates of 1.2 GB and 4 GB must be corrected or replaced by
metadata-driven values. The incomplete 1.7B cache on the maintainer's Mac is
already approximately 5.5 GB, demonstrating why cleanup and preflight checks
are required.

## Target architecture

```text
GitHub Release
├── WhisprStream-macos-arm64.zip       user downloads this
├── WhisprStream-runtime-<version>-arm64.zip
└── SHA256SUMS

WhisprStream.app
├── native Swift executable
├── asr_server.py
├── asr_engine.py
├── model_download.py
└── Info.plist
    ├── immutable runtime URL
    ├── runtime archive SHA-256
    ├── required runtime version
    ├── expected archive bytes
    └── expected installed bytes

~/Library/Application Support/WhisprStream/Runtime
├── manifest.json
├── bin/python3.12
├── Python standard library
└── pinned MLX dependencies

Hugging Face cache
└── independently downloaded Qwen3-ASR snapshots
```

The app must always launch Python through an absolute URL supplied by
`RuntimeManager`. No production path may execute a bare `python`, `python3`, or
`/usr/bin/env python3` command.

## Workstream 1: make Python isolation robust

### Problem

`ASRService` and `ModelDownloader` correctly choose an explicit private Python
executable, but both currently copy the user's entire process environment into
the child. Variables such as `PYTHONPATH`, `PYTHONHOME`, `VIRTUAL_ENV`, Conda
state, user-site packages, and dynamic-library paths can still alter import or
linker behavior.

### Implementation

Create one shared environment builder, for example
`PythonProcessEnvironment.swift`, and use it for every Python subprocess.

1. Begin with the current environment so ordinary locale, proxy, certificate,
   and intentional Hugging Face settings continue to work.
2. Remove at least:

   - `PYTHONHOME`
   - `PYTHONPATH`
   - `PYTHONSTARTUP`
   - `PYTHONEXECUTABLE`
   - `VIRTUAL_ENV`
   - `CONDA_PREFIX`
   - `CONDA_DEFAULT_ENV`
   - `_OLD_VIRTUAL_PATH`
   - `LD_LIBRARY_PATH`
   - `DYLD_LIBRARY_PATH`
   - `DYLD_FRAMEWORK_PATH`
   - `DYLD_INSERT_LIBRARIES`

3. Set `PYTHONNOUSERSITE=1`.
4. Pass `-s` and `-u` to Python before the script path. `-s` prevents user site
   packages from being imported and `-u` keeps the JSON protocol unbuffered.
5. Preserve `HF_HOME`, `HF_HUB_CACHE`, HTTPS proxy variables, system certificate
   variables, and WhisprStream's own `WHISPR_*` variables.
6. Do not use Python's `-I` mode without adapting the resource import path;
   `asr_server.py` imports the sibling `asr_engine.py`, and `-I` removes the
   script directory from `sys.path`.
7. Keep `WHISPR_PYTHON` as an explicit developer override. Public builds must
   not contain a development Python path in `Info.plist`.

Update:

- `WhisprStream/Sources/WhisprStream/ASRService.swift`
- `WhisprStream/Sources/WhisprStream/ModelDownloader.swift`
- Any new Python-based helper introduced by this plan

### Acceptance criteria

- The app works when the user's shell has no Python.
- The app works when the user has Homebrew, pyenv, Conda, or a different Python
  version installed.
- A deliberately poisoned `PYTHONPATH` containing a fake `numpy` or
  `huggingface_hub` cannot affect the sidecar.
- User-site packages cannot replace the runtime's pinned packages.
- Intentional custom `HF_HOME` and `HF_HUB_CACHE` locations still work.

## Workstream 2: version and validate the speech engine

### Runtime manifest

Have `build-runtime.sh` create `runtime/manifest.json` after dependencies are
installed. Suggested schema:

```json
{
  "schemaVersion": 1,
  "runtimeVersion": "1.0.0",
  "pythonVersion": "3.12.12",
  "architecture": "arm64",
  "minimumMacOS": "14.0",
  "dependencySet": "mlx-qwen3-asr-0.3.5",
  "payloadBytes": 356000000
}
```

`runtimeVersion` is independent of the app version. Several app releases may
require the same runtime. Only change it when Python or the dependency set
changes incompatibly.

### App configuration

Add the following release values to `Info.plist` through `build.sh`:

- `WhisprRuntimeVersion`
- `WhisprRuntimeURL`
- `WhisprRuntimeSHA256`
- `WhisprRuntimeArchiveBytes`
- `WhisprRuntimeInstalledBytes`

Release builds must fail if any value is missing, malformed, zero, points to a
non-HTTPS URL, or still uses the development bundle identifier.

### RuntimeManager behavior

Refactor readiness from “an executable file exists” to “a compatible runtime is
installed.” A runtime is compatible only when:

1. `manifest.json` parses and has a supported schema.
2. Its runtime version equals the app's required runtime version. Exact matching
   is the safest initial policy.
3. It declares `arm64`, Python 3.12, and macOS 14 or later compatibility.
4. `bin/python3.12` exists and is executable.
5. A lightweight health check succeeds, such as importing `mlx`, `numpy`,
   `huggingface_hub`, and `mlx_qwen3_asr` and checking the expected versions.

Run the health check away from the main thread, cache its result for the
session, and apply a timeout. Do not load a speech model during this check.

Existing pre-manifest runtimes should be treated as incompatible and offered a
one-time engine reinstall. Keep the existing staging and rollback behavior so a
failed upgrade cannot destroy the working runtime.

Add an **Engine → Repair/Reinstall** action. It must explain that it replaces
the engine but does not delete models, preferences, vocabulary, or shortcuts.
Require confirmation before replacing an otherwise healthy runtime.

### Runtime build verification

Before archiving, `build-runtime.sh` must:

1. Confirm the source is relocatable CPython 3.12 for arm64.
2. Install only the pinned requirements.
3. Run the import/version health check using the staged interpreter.
4. Scan staged Python and native libraries for references to the build machine's
   source path. Fail if machine-specific absolute paths remain.
5. Sign all relevant Mach-O executables and libraries with the configured
   stable self-signed release identity.
6. Verify every signed Mach-O file with `codesign --verify --strict`.
7. Generate the manifest and calculate archive and installed byte counts.
8. Produce the ZIP, SHA-256, and machine-readable build metadata consumed by
   the app release build.

## Workstream 3: shared free-space preflight

### Storage service

Add a small testable service, for example `StorageCapacity.swift`.

- Resolve the relevant destination URL to the nearest existing parent.
- Read `volumeAvailableCapacityForImportantUsage` from URL resource values.
- Fall back to `FileManager.attributesOfFileSystem` and `.systemFreeSize` when
  necessary.
- Return byte counts as `Int64` and protect calculations against overflow.
- Use `ByteCountFormatter` for all user-facing values.
- Keep policy calculations outside SwiftUI so they can be unit-tested.

Use a 512 MB safety margin initially. Define it once rather than duplicating
magic values.

### Engine calculation

Check the volume containing Application Support before starting the request.

```text
required free bytes = archive bytes + installed bytes + safety margin
```

Both the downloaded archive and the extracted staging runtime temporarily exist
at the same time. During an upgrade, the old runtime also remains until the
atomic swap succeeds, but its space is already excluded from the reported free
capacity and should not be added again.

If capacity is insufficient:

- Do not start the network request.
- Show required and available values.
- Offer **Manage Storage…**, **Try Again**, and **Cancel**.
- Keep onboarding on the engine step.

Recheck immediately before extraction because capacity may have changed during
the download.

### Model calculation

The model cache may live on a different volume, so perform the check against the
resolved Hugging Face cache root rather than Application Support.

Extend `model_download.py` with a preflight mode that:

1. Resolves the same cache root `huggingface_hub` will use.
2. Queries Hugging Face file metadata.
3. Sums only files matched by the actual download patterns: JSON, TXT, and
   SafeTensors files.
4. Reports total model bytes, available bytes, cache root, installed reusable
   bytes when reliably knowable, and stale `.incomplete` bytes.
5. Exits without downloading.

Suggested newline-delimited response:

```json
{
  "type": "preflight",
  "model": "Qwen/Qwen3-ASR-0.6B",
  "totalBytes": 1881000000,
  "availableBytes": 9500000000,
  "incompleteBytes": 0,
  "requiredBytes": 2393000000,
  "cacheRoot": "/Users/example/.cache/huggingface/hub"
}
```

Use a two-phase `ModelDownloader` flow:

1. User presses **Download**.
2. Swift runs preflight and displays **Checking storage…**.
3. If enough space is available and no cleanup decision is required, start the
   download automatically.
4. The Python download mode repeats the capacity check immediately before
   `snapshot_download()` so preflight cannot become a stale guarantee.
5. If offline, distinguish “Could not check model information” from “Not enough
   storage.” Do not report an offline request as a storage failure.

For the first implementation, a conservative calculation is acceptable:

```text
required free bytes = complete model bytes + safety margin
```

This may overestimate when valid blobs can be reused, but it must never
underestimate because an interrupted download currently restarts.

### Expected thresholds and copy

Do not hard-code thresholds as the source of truth; use real metadata. For
offline explanatory copy, use conservative rounded estimates:

- 0.6B: approximately 1.9 GB installed; recommend at least 3 GB free for a full
  app + engine + default-model installation.
- 1.7B: approximately 4.3 GB installed; recommend at least 6 GB free for a full
  app + engine + large-model installation.
- Both models: approximately 6.7 GB installed; recommend about 8 GB free.

After the final release artifacts exist, update these values from actual
measurements.

## Workstream 4: partial model cleanup and accurate progress

### Cleanup behavior

An interrupted Hugging Face download creates process-unique `.incomplete`
files and does not resume them in the pinned dependency version. These files are
dead storage.

1. Detect `.incomplete` files only inside the selected model repository's
   `blobs` directory.
2. Never delete complete blobs, snapshots, another model, or the whole Hugging
   Face cache.
3. Never clean while any model downloader process is active.
4. Show the amount, for example: “An incomplete download is using 5.5 GB.”
5. Offer **Remove Incomplete Download**, followed by a confirmation explaining
   that the partial data cannot be resumed.
6. After deletion, rerun install-state and capacity checks.
7. Add the same cleanup action to Settings → Model for recovery outside
   onboarding.
8. Log filenames and aggregate bytes removed, but do not log home-directory
   paths unnecessarily.

Perform deletion in Python or in one narrowly scoped Swift service. In either
case, resolve and validate that every target is a regular file under the exact
selected repository's `blobs` directory before removing it.

### Progress correctness

The current watcher counts every byte in the repository, including stale
partial files. This can make a fresh attempt look complete immediately.

Before a download attempt, record existing files. During that attempt, report:

- Complete reusable blobs already present.
- Newly created or growing partial files belonging to this attempt.
- Do not count stale `.incomplete` files from earlier attempts.

Clamp the UI fraction between zero and one, but fix the underlying byte count
rather than relying on clamping. On completion, verify `ModelCatalog.state` is
`.installed`; a zero process exit by itself is not enough.

## Workstream 5: first-run and recovery UX

Keep engine and model as separate steps and use user-facing terms. Python should
appear only in developer documentation and diagnostic details.

### Welcome

- State: “Requires macOS 14 or later and an Apple-silicon Mac.”
- State that processing stays on the Mac.
- Give an approximate full-install total for the recommended model.

### Engine step

- Title: **Install the speech engine**.
- Explain that it is installed once and is separate from app updates and
  models.
- Show expected download size, installed size, and currently available space.
- Add states for checking storage, insufficient storage, downloading,
  verifying, installing, ready, incompatible, and failed.
- Keep checksum failure distinct from network and storage failures.
- Allow cancel during network download; never allow cancel during the atomic
  replacement operation unless interruption is proven safe.

### Model step

- Keep 0.6B and 1.7B separate.
- Mark 0.6B **Recommended** and describe it as the fastest, broadest-compatible
  option.
- Correct the approximate sizes to measured values.
- Describe 1.7B as “Larger and slower; may improve difficult audio.” Do not
  promise higher accuracy for every voice.
- Add “Best with 16 GB or more unified memory” as advice, not a hard block.
- Show available space and incomplete-download storage when applicable.
- Preserve cancel, retry, and model selection.

### Permissions

Microphone and Accessibility are required for the normal dictation workflow.
The current UI permits skipping them. If skip remains available:

- The final screen must not say **You're all set** when either permission is
  missing.
- Use a conditional state such as **Finish setup later** and list the missing
  permission with an **Open Settings** action.
- The menu-bar Setup Guide and Settings → Permissions must remain usable.

If both permissions are granted, the final screen can say **You're all set** and
show the selected trigger-key instruction.

### Recovery

Users must be able to recover without deleting files manually:

- Missing engine: reopen setup at or guide directly to the engine step.
- Incompatible engine: offer update/reinstall.
- Failed engine health check: offer repair and show a concise diagnostic.
- Missing selected model: open model installation.
- Partial model: offer scoped cleanup and retry.
- Revoked permissions: show status and deep-link to System Settings.
- Closing onboarding early: keep the menu-bar icon and Setup Guide available.

A future improvement may add an actual first-dictation test field. Do not make
that a release blocker unless Luna can start the engine before onboarding's
completion without duplicating lifecycle ownership.

## Workstream 6: hardware and performance guidance

Do not block supported Apple-silicon Macs based on chip tier. Chip generation,
GPU size, memory bandwidth, thermal design, available unified memory, and other
workloads change latency, not basic compatibility.

Use these initial recommendations:

| Hardware | 0.6B | 1.7B |
| --- | --- | --- |
| Base M-series, 8 GB | Recommended | Allowed but warn about memory pressure and slower response |
| Any M-series, 16 GB or more | Recommended | Reasonable optional choice |
| Pro, Max, or Ultra | Very fast | Best target for the larger model |

If the app reads `ProcessInfo.processInfo.physicalMemory`, use it only to tailor
advisory text. Do not prevent a download because the Mac has 8 GB. Do not attempt
to infer accuracy from the chip.

Before publishing strong performance claims, benchmark at least:

- Base M1 with 8 GB.
- A recent base M-series machine with 16 GB.
- One Pro or Max machine.

For both models, record cold model-load time, warm final-transcription latency,
live-preview latency, peak memory, and sustained behavior across repeated
utterances. Use the same audio fixtures and report the chip, memory, macOS,
model revision, and runtime version.

## Workstream 7: no-fee signing and GitHub packaging

### Stable release identity

Create one self-signed code-signing certificate dedicated to WhisprStream and
reuse it for every public release.

- Keep its private key outside the repository and out of GitHub Release assets.
- Back it up securely; losing it changes the app's identity.
- Add a `SIGNING_IDENTITY` input to the release scripts.
- Make `RELEASE=1` fail rather than silently falling back to ad-hoc signing.
- Use a permanent bundle identifier, such as the already documented
  `com.leoleo.whisprstream`, and never change it after release.
- Verify signatures before archiving.

The documentation must be explicit: self-signing does not provide Apple trust,
does not notarize the software, and does not remove Gatekeeper's unknown
developer warning.

### Release artifacts

Use these names:

- `WhisprStream-macos-arm64.zip` for the user-facing app asset. Keep this name
  stable so the website can use GitHub's `latest/download` URL.
- `WhisprStream-runtime-<runtime-version>-arm64.zip` for the engine asset.
- `SHA256SUMS` for both files.

Use `ditto -c -k --sequesterRsrc --keepParent` to preserve macOS metadata and the
application bundle. The runtime URL embedded in a released app must be the
immutable tag-specific URL, not `latest/download`, so a published app's checksum
always refers to the same bytes.

Suggested first release order:

1. Create a draft GitHub release tagged `v1.0.0`.
2. Build, validate, sign, and upload the runtime.
3. Record its final SHA-256, archive bytes, installed bytes, and runtime version.
4. Build the app with those immutable values.
5. Verify that no development Python path exists in its `Info.plist`.
6. Sign the app with the stable self-signed identity.
7. Archive and calculate its SHA-256.
8. Download both assets back from GitHub and verify their hashes.
9. Test the downloaded, quarantined app on a clean Mac.
10. Publish the release only after the clean-Mac test succeeds.

### Gatekeeper instructions

Release notes and installation documentation must tell users:

1. Download `WhisprStream-macos-arm64.zip` from the GitHub Release.
2. Extract it and move WhisprStream to Applications.
3. Attempt to open it normally.
4. If macOS blocks it, open System Settings → Privacy & Security, find the
   WhisprStream message under Security, click **Open Anyway**, authenticate, and
   confirm **Open**.

On macOS versions where Control-click → Open is still offered, it may be noted
as an alternative, but **Open Anyway** is the canonical cross-version guidance.
Never instruct users to disable Gatekeeper globally.

### Updates

Keep the initial manual update design:

- Settings → About checks GitHub's latest stable release.
- **Download Update…** opens the release page.
- The user replaces the old app in Applications.
- The runtime and models remain in user storage.

Before release, commit and test the currently uncommitted update-manager work.
Only accept exact stable semantic versions such as `v1.0.1` unless broader
version support is deliberately added.

Test whether the stable self-signed identity preserves Microphone and
Accessibility grants across replacement. If macOS still requires
Accessibility to be re-granted, document that honestly in update notes.

## Workstream 8: website and documentation

### Website

Replace placeholder `href="#"` values.

- Main Download button:
  `https://github.com/Leo6Leo/whispr-stream/releases/latest/download/WhisprStream-macos-arm64.zip`
- Source buttons:
  `https://github.com/Leo6Leo/whispr-stream`
- Remove `brew install whisprstream` until a real Homebrew Cask exists.

Near the download button, state:

> Free and open source · macOS 14 or later · Apple silicon · approximately
> 3 GB free space recommended

Add a short unknown-developer note linking to installation instructions. Do not
describe the app as notarized or Apple-verified.

### README

Split requirements into two audiences:

- **Install the app:** macOS 14+, Apple silicon, approximately 3 GB free for the
  recommended model.
- **Build from source:** Xcode and Python 3.12.

The primary quick start should be the GitHub Release installation. Move
`setup-mac.sh` and source-build commands into a clearly labeled developer
section.

### Installation guide

Add `INSTALL.md` containing:

- Compatibility requirements.
- Download, Applications-folder, and Open Anyway steps.
- Engine and model size expectations.
- Why engine and model are separate.
- Microphone and Accessibility instructions.
- Menu-bar behavior and how to reopen Setup Guide.
- Storage cleanup and repair instructions.
- Update procedure.
- Uninstall procedure listing the app, Application Support runtime, optional
  model cache, settings, and logs separately. Never imply that removing the app
  automatically deletes models.

### Release documentation

Update `RELEASING.md` with exact commands and a checklist for:

- Runtime build and health validation.
- Stable self-signing.
- Artifact sizes and hashes.
- App build with immutable runtime metadata.
- Clean-machine Gatekeeper test.
- First-run download test.
- Update test over the previous release.
- Website download-link verification.

## Workstream 9: tests and validation

### Swift unit tests

Add coverage for:

- Storage arithmetic and formatting.
- Enough-space, exactly-enough, insufficient, unavailable-capacity, and overflow
  cases.
- Runtime manifest parsing and unsupported schema.
- Compatible, incompatible, corrupt, and missing runtimes.
- Runtime archive checksum mismatch and invalid layout.
- Atomic upgrade success and rollback after failure.
- Release configuration validation.
- Sanitization of Python child environments.
- Model preflight JSON parsing and UI-state transitions.
- Conditional final onboarding text when permissions are missing.
- Runtime version persistence across app patch updates.

Refactor filesystem, capacity, network, and process-launch dependencies behind
small injectable interfaces where necessary. Avoid tests that mutate the real
Application Support or Hugging Face cache.

### Python tests

Add `tests/test_model_download.py` using temporary directories and mocked Hub
metadata. Cover:

- Pattern-filtered total calculation.
- Custom cache-root resolution.
- Capacity success and failure.
- Detection and byte counting of stale `.incomplete` files.
- Cleanup restricted to the selected repository.
- Refusal to clean while an active attempt is represented.
- Progress excluding stale partial files.
- Network metadata failure distinct from storage failure.

Keep the current ASR tests passing.

### Release validation script

Create a read-only validation command for finished artifacts. It should fail if:

- The app is not arm64.
- The minimum macOS version is wrong.
- The bundle identifier is a development identifier.
- A development Python path is present.
- Runtime URL, checksum, size metadata, or required version is missing.
- The app or runtime Mach-O signatures do not verify.
- The runtime ZIP has the wrong top-level layout.
- The runtime manifest and app requirement disagree.
- Runtime imports fail.
- Any archive checksum differs from `SHA256SUMS`.

### Clean-Mac manual matrix

Test browser-downloaded artifacts, not local build output, because Gatekeeper
quarantine behavior is part of the product.

Required scenarios:

1. Fresh supported Mac with no developer tools or user Python.
2. Mac with Homebrew Python 3.13.
3. Mac with active Conda/pyenv environment and poisoned `PYTHONPATH`.
4. macOS 14 and the newest supported macOS release.
5. Base M-series 8 GB and at least one 16 GB or greater Mac.
6. Offline before engine download.
7. Insufficient space before engine download.
8. Cancelled engine download and retry.
9. Corrupt or wrong-checksum engine archive.
10. Insufficient space before model download.
11. Cancelled model download, visible partial storage, confirmed cleanup, retry.
12. Permission denial, skip, later grant, and recovery through Settings.
13. App update over the previous version with runtime/model preservation.
14. Runtime-version upgrade with successful replacement and simulated rollback.

Record screenshots and logs for every failure-state message before release.

## Suggested implementation order

### Phase 0: preserve and baseline

- Inventory the current uncommitted update and release changes.
- Create a dedicated implementation branch without discarding user work.
- Run the existing Swift and Python tests and record the baseline.

### Phase 1: runtime correctness

- Add sanitized Python environments.
- Add runtime manifest generation, parsing, compatibility, and health checks.
- Add runtime repair/reinstall.
- Add unit tests.

### Phase 2: storage and model recovery

- Add the shared capacity service.
- Add engine preflight and extraction recheck.
- Add model metadata preflight.
- Add scoped partial cleanup.
- Correct progress accounting and size labels.
- Add Swift and Python tests.

### Phase 3: onboarding polish

- Integrate capacity and cleanup states.
- Add hardware guidance.
- Correct the permission-skipped final state.
- Verify every cancel, retry, and reopen path.

### Phase 4: reproducible release packaging

- Harden `build-runtime.sh` and `build.sh` inputs.
- Add stable self-signing and artifact validation.
- Produce a release candidate from relocatable Python.
- Measure final archive and installed sizes and update fallback copy.

### Phase 5: documentation and distribution

- Add `INSTALL.md`.
- Update README and RELEASING.
- Replace website placeholders and remove unsupported Homebrew instructions.
- Create a draft GitHub Release with app, runtime, and hashes.

### Phase 6: clean-machine release qualification

- Execute the manual matrix.
- Fix release-blocking failures.
- Download and revalidate final assets.
- Publish only after the complete fresh-install and update paths pass.

## Release blockers versus follow-ups

### Required before the first public binary release

- Relocatable private runtime with no maintainer-machine paths.
- Stable bundle identifier and stable self-signed release identity.
- No development Python path in public builds.
- Runtime checksum, manifest, version, and health validation.
- Free-space checks for engine and model.
- Correct model-size copy.
- Safe incomplete-download cleanup or, at minimum, clear detection and manual
  cleanup through the app.
- Accurate GitHub download and Gatekeeper instructions.
- Website links that point to real assets and no false Homebrew command.
- Clean-Mac verification without Python or Xcode installed.

### Reasonable follow-ups

- First-dictation test field inside onboarding.
- Automated GitHub Actions release builds.
- A real Homebrew Cask.
- Rich runtime download progress using `URLSessionDownloadDelegate`.
- Automated benchmark collection and chip-specific measured guidance.
- A paid Developer ID and notarization if funding becomes available later.

## Definition of done

The installation and release work is complete when all of the following are
true:

1. A user on a clean Apple-silicon Mac can download one app ZIP from a GitHub
   Release, approve it through macOS Privacy & Security, and move through
   onboarding without Terminal.
2. The user does not need Python, Xcode, Homebrew, pip, Conda, or pyenv.
3. Existing Python installations and environment variables cannot change the
   runtime's interpreter or imported packages.
4. Engine and model downloads remain visibly separate.
5. Both downloads refuse to start when free space is insufficient and explain
   required versus available space.
6. Interrupted model data is reported and can be removed safely with explicit
   confirmation.
7. A valid engine and model survive app replacement during an ordinary update.
8. An incompatible engine is detected and replaced atomically.
9. Permission-denied and permission-skipped states never claim the app is fully
   ready.
10. The website, README, installation guide, release notes, and actual assets
    agree on compatibility, sizes, filenames, and installation steps.
11. Automated tests pass and the clean-Mac manual matrix has recorded results.
12. Final GitHub assets match their published SHA-256 values.

