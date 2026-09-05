# Speekium — Security Review

Date: 2026-08-20 · Scope: shipped macOS app (`Speekium/Sources`, `Speekium/Resources`),
build/release scripts, GitHub Pages site, repo hygiene. Reviewer: manual read of the
full source tree at commit after the WhisprStream→Speekium rebrand.

## Summary

Speekium has an unusually careful security posture for a self-signed, non-notarized
menu-bar app. The private speech runtime is **SHA-256-pinned in the app's own signed
Info.plist**, so its integrity is anchored to the app's code signature; HTTPS is enforced,
`latest/download` mutable URLs are rejected, and installs are staged atomically with
rollback. The Python sidecar has its `DYLD_*` / `PYTHON*` environment stripped, talks only
over stdin/stdout (no network listener), and the model-cache cleanup is hardened against
symlink attacks (`O_NOFOLLOW`, `is_symlink()` guards, scoped deletes). No secrets are
committed; no `eval`/`exec`/`pickle`/`shell=True`/`os.system` anywhere in shipped code.

The findings below are mostly **defense-in-depth hardening**. The one that deserves a real
fix is **F1** (environment overrides remain active in release builds, giving a local
arbitrary-code-execution vector into a Microphone- and Accessibility-privileged process).

| # | Severity | Status | Finding |
|---|----------|--------|---------|
| F1 | **Medium** | ✅ Fixed | `SPEEKIUM_PYTHON` / `SPEEKIUM_RUNTIME_DIRECTORY` overrides honored in release builds → arbitrary sidecar executable |
| F2 | Low | ✅ Fixed (superseded by upstream 1.0.2 `isSecureGitHubURL`) | Update check opens an unvalidated URL scheme from a network response |
| F3 | Low | ✅ Fixed | Log file is world-readable (0644) and holds app/usage metadata |
| F4 | Low | Open | Transcript pasteboard + synthetic Cmd-C/Cmd-V is the app's largest privacy surface (by design) |
| F5 | Info | Open | Python health-check program assembled by string interpolation |
| F6 | Info | ✅ Fixed (upstream 1.0.2 dropped `--deep`) | `codesign --deep` in `build.sh` (deprecated) |
| F7 | Info | Open | Root-level Python prototypes live alongside shipped code |

**F1–F3 were fixed** in the commit that follows this review; see the resolution notes
on each finding and the regression coverage in
[`SecurityHardeningTests.swift`](Speekium/Tests/SpeekiumTests/SecurityHardeningTests.swift).

**Upstream 1.0.2 merge (2026-09-05).** Upstream independently addressed several items: F1's env-override gating now also exists upstream (`isDevelopmentBuild`, additionally compile-time-disabled via `#if SPEEKIUM_RELEASE`; our `RuntimeEnvironment` remains for the sidecar model/engine/bits reads), F2 is superseded by upstream's `isSecureGitHubURL` in the new signed auto-updater (our `isTrustedReleaseURL` was dropped), F6 is resolved (upstream no longer signs with `--deep`), and the supply-chain note is addressed by hash-locked `requirements-*.lock` files. F3 (0600 log) and F4/F5/F7 are unchanged.

---

## F1 — Environment overrides active in release builds (Medium)

`RuntimeManager.executableURL` reads `SPEEKIUM_PYTHON` **unconditionally**, only skipping it
when `developerTestMode` is on (which itself requires a `dev.`-prefixed bundle id):

- [`RuntimeManager.swift:107`](Speekium/Sources/Speekium/RuntimeManager.swift:107) — returns `$SPEEKIUM_PYTHON` as the executable
- [`RuntimeManager.swift:158`](Speekium/Sources/Speekium/RuntimeManager.swift:158) — `refresh()` marks the engine `.ready` if `$SPEEKIUM_PYTHON` is executable
- [`RuntimeManager.swift:430`](Speekium/Sources/Speekium/RuntimeManager.swift:430) — `$SPEEKIUM_RUNTIME_DIRECTORY` redirects the managed-runtime location; its `bin/python3.12` is then executed by the health check ([`RuntimeManager.swift:316`](Speekium/Sources/Speekium/RuntimeManager.swift:316))

In a **release** build `developerTestMode` is `false`, so these paths are live. Result: an
attacker who can influence the app's launch environment (a LaunchAgent/LaunchDaemon plist
with `EnvironmentVariables`, `launchctl setenv SPEEKIUM_PYTHON …`, or any poisoned launch
context) causes Speekium to spawn an **arbitrary executable as its speech sidecar**.

Why this matters more than a typical "attacker already has your env" shrug: Speekium holds
**Microphone and Accessibility** TCC grants and posts synthetic keystrokes into other apps.
The sidecar is deliberately handed a sanitized environment (`DYLD_INSERT_LIBRARIES` etc.
stripped in [`PythonProcessEnvironment.swift:9`](Speekium/Sources/Speekium/PythonProcessEnvironment.swift:9)) precisely to stop injection into that
privileged context — but `SPEEKIUM_PYTHON` lets an attacker skip the injection and simply
*be* the sidecar. The runtime-URL overrides (`SPEEKIUM_RUNTIME_URL` / `_SHA256`,
[`RuntimeManager.swift:391`](Speekium/Sources/Speekium/RuntimeManager.swift:391)) are weaker (still checksum- and HTTPS-gated) but similarly
shouldn't be reachable in release.

**Recommendation.** Gate every `SPEEKIUM_*` override behind `isDevelopmentBuild`
(`dev.` bundle-id prefix) or `DeveloperTestMode`, the same way `developmentPythonURL`
already restricts the Info.plist dev path. In release, only the managed runtime directory
and the signed Info.plist values should be trusted. The `SPEEKIUM_MODEL` / `SPEEKIUM_BITS`
overrides ([`SpeekiumApp.swift:205`](Speekium/Sources/Speekium/SpeekiumApp.swift:205)) are lower risk but belong on the same gate.

**✅ Resolution.** Added [`RuntimeEnvironment`](Speekium/Sources/Speekium/RuntimeEnvironment.swift), a pure gate that returns an
override value only when the bundle identifier is a `dev.` development build; a
release fails closed (a nil identifier is treated as release). Every `SPEEKIUM_*`
read in `RuntimeManager` and `SpeekiumApp.makeService` now flows through it, so a
poisoned launch environment cannot redirect the sidecar executable, runtime
location, download source, or model in a shipped build. Regression:
`testReleaseBuildIgnoresEveryOverrideVariable`, `testDevelopmentBuildHonorsOverrideVariables`,
`testMissingBundleIdentifierIsTreatedAsRelease`.

## F2 — Unvalidated URL scheme opened from a network response (Low)

`AppUpdateManager.openAvailableRelease()` opens the release page with no scheme check:

- [`AppUpdateManager.swift:75`](Speekium/Sources/Speekium/AppUpdateManager.swift:75) — `NSWorkspace.shared.open(release.pageURL)`
- `pageURL` is decoded from the GitHub API `html_url` field ([`AppUpdateManager.swift:100`](Speekium/Sources/Speekium/AppUpdateManager.swift:100))

Normally this is an `https://github.com/…` URL from GitHub over TLS, so exposure is small.
But the value originates in a network response, and the update repository is itself
overridable (`SPEEKIUM_UPDATE_REPOSITORY` env / Info.plist, [`AppUpdateManager.swift:32`](Speekium/Sources/Speekium/AppUpdateManager.swift:32)),
so a non-`https` scheme (e.g. `file:`) opened via `NSWorkspace` is worth precluding.

**Recommendation.** Before opening, require `pageURL.scheme == "https"` (and ideally
`host == "github.com"`); otherwise fall back to the repository's releases page.

**✅ Resolution.** Added `AppUpdateManager.isTrustedReleaseURL` (requires scheme
`https` and host `github.com`, case-insensitive). It is enforced both when the
release is decoded (`fetchLatestRelease` throws `.untrustedReleaseURL` otherwise, so
an untrusted URL never reaches `.available`) and again as a guard in
`openAvailableRelease` before `NSWorkspace.open`. Regression:
`testTrustedReleaseURLAcceptsGitHubHTTPS`, `testTrustedReleaseURLRejectsUnexpectedSchemesAndHosts`
(covers `file:`, `javascript:`, plain `http`, and `github.com.evil.example` look-alikes).

## F3 — World-readable log with usage metadata (Low)

- [`Log.swift:21`](Speekium/Sources/Speekium/Log.swift:21) and [`ASRService.swift:67`](Speekium/Sources/Speekium/ASRService.swift:67) create `~/Library/Logs/Speekium.log` with default 0644 perms.

The log deliberately records **no transcript text** (only character counts, timings, the
frontmost app's bundle id, and Accessibility trust state — good discipline). Still, on a
multi-user Mac those entries plus raw sidecar stderr are readable by other local accounts.

**Recommendation.** Create the file `0600`, and consider size-capping/rotating it.

**✅ Resolution.** Both creators now route through `Log.ensureSecureLogFile`, which
creates the log `0600` and tightens a file left `0644` by an earlier version
(`perms & 0o077 != 0`). `ASRService`'s duplicate `logURL`/creation was removed in
favor of the shared helper. Regression: `testEnsureSecureLogFileCreatesOwnerOnlyFile`,
`testEnsureSecureLogFileTightensAWorldReadableFile`. (Size-capping/rotation is still
open.)

## F4 — Transcript pasteboard + synthetic input is the main privacy surface (Low, by design)

`TextInserter` is inherently powerful and correct for what it does, but it's worth
documenting as the app's largest exposure:

- Finished transcripts are written to `NSPasteboard.general` ([`TextInserter.swift:69`](Speekium/Sources/Speekium/TextInserter.swift:69)); with
  Universal Clipboard/Handoff enabled these sync to the user's other Apple devices.
- A synthetic **Cmd-V** is posted into the frontmost app ([`TextInserter.swift:589`](Speekium/Sources/Speekium/TextInserter.swift:589)).
- The context-aware-capitalization probe synthesizes **Cmd-C + Cmd-Shift-Left** to read the
  line *before the cursor* out of arbitrary third-party apps ([`TextInserter.swift:133`](Speekium/Sources/Speekium/TextInserter.swift:133)).

All of this is reversible (the previous clipboard is snapshotted and restored, and the probe
restores caret + clipboard), race-guarded via `changeCount`, and off unless the relevant
setting is on. No bug — but the transient clipboard write leaks the transcript to Handoff
and to clipboard managers.

**Recommendation.** Flag the transient pasteboard item with
`org.nspasteboard.ConcealedType` (and/or `org.nspasteboard.AutoGeneratedType`) so password
managers and clipboard history tools skip it, and document the cursor-context probe's
behavior in the privacy copy since it reads neighboring app text.

## F5 — Health-check Python assembled by string interpolation (Info)

[`RuntimeManager.swift:26-39`](Speekium/Sources/Speekium/RuntimeManager.swift:26) builds a `python -c` program by interpolating the manifest's
`dependencyVersions` JSON directly into source (`expected = \(expectedJSON)`). The input is
checksum-verified and code-signed, so it is **not attacker-controlled** — but generating code
by interpolation is a fragile pattern (JSON vs. Python literal edge cases) and an easy place
for a future change to introduce injection.

**Recommendation.** Pass the expected-versions JSON to the child via an environment variable
or argv and `json.loads` it inside the program, instead of embedding it in the source string.

## F6 — `codesign --deep` in build.sh (Info)

- [`Speekium/build.sh`](Speekium/build.sh) signs with `codesign --force --deep --sign …`.

`--deep` is deprecated by Apple and unreliable for nested code (it can leave embedded
binaries under-signed). It's a dev/self-signed path here, so impact is low, but the
recommended practice is to sign nested code inside-out and drop `--deep`.

## F7 — Root-level Python prototypes alongside shipped code (Info)

`speekium.py`, `speekium_live.py`, `stream_from_file.py`, `live_stream.py`,
`record_sample.py` at the repo root are **not** copied into the app bundle (only
`asr_server.py`, `model_download.py`, `asr_engine.py` are — see [`build.sh`](Speekium/build.sh)). They use
`subprocess.run([...])` with list arguments and `pbcopy`/`pbpaste` (no shell, no injection),
so they're fine on their own. The only note: keeping them at the top level invites confusion
with shipped code in future audits.

**Recommendation.** Move them under `prototypes/` (or note their status in the README) so the
shipped Python surface is unambiguous.

---

## Positive controls worth preserving

- **Runtime integrity anchored to the app signature.** SHA-256 pinned in the signed
  Info.plist; verified before extraction ([`RuntimeManager.swift:471`](Speekium/Sources/Speekium/RuntimeManager.swift:471)); HTTPS enforced and
  `latest/download` rejected at build and install time.
- **Atomic, reversible install.** Staged extraction, layout/manifest/compat validation, then
  move-into-place with `Runtime.previous` rollback ([`RuntimeManager.swift:465-526`](Speekium/Sources/Speekium/RuntimeManager.swift:465)).
- **Subprocess hardening.** `DYLD_*`, `PYTHONPATH`, `PYTHONHOME`, virtualenv/conda vars
  stripped; `PYTHONNOUSERSITE=1`; `-s` (no user site) for every sidecar invocation.
- **Model-cache cleanup hardening.** `O_NOFOLLOW`, `is_symlink()` refusals, `resolve()` +
  parent-directory checks, and an OS-owned flock so cleanup only ever touches `.incomplete`
  blobs in the selected repo ([`model_download.py:109-256`](Speekium/Resources/model_download.py:109)).
- **Closed allowlists.** Model ids and short-utterance languages are fixed enums, not
  free-text; repo ids validated against a strict regex before use.
- **No network listener.** The ASR sidecar is stdin/stdout only; the transitive
  GCDWebServer dependency is never started.
- **Robust IPC.** SIGPIPE suppressed on the sidecar pipe ([`ASRService.swift:44`](Speekium/Sources/Speekium/ASRService.swift:44)); partial
  writes handled; generation counters prevent stale-process events.
- **Clean repo.** No API keys, tokens, or private keys committed; signing key kept out of
  the repo by policy ([`RELEASING.md`](RELEASING.md)).

## Suggested priority

1. **F1** — gate `SPEEKIUM_*` overrides to development builds (small, high-value change).
2. **F2**, **F3** — one-line scheme check; `0600` log perms.
3. **F4** — conceal the transient pasteboard write; document the cursor probe.
4. **F5–F7** — opportunistic hardening.
