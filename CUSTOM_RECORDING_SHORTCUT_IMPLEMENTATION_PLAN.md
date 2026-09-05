# Arbitrary Recording Shortcut — Implementation Plan

Issue: [#4 — Support arbitrary custom recording shortcuts](https://github.com/JPtheJP/speekium/issues/4)

Prepared: 2026-08-23

Implementation target analyzed: `codex/release-v1.0.1` at commit `983f3fc`

Baseline status:

- Worktree was clean during analysis.
- The branch was 12 commits ahead of `origin/master`.
- `swift test` passed all 77 existing tests before implementation.
- macOS deployment target is 14; the package uses Swift tools 6.0 and Swift 5 language mode.
- No third-party dependency is required for this feature.

## 1. Objective

Replace the fixed trigger-key picker with a real keyboard shortcut recorder while preserving every existing trigger and activation behavior.

Required results:

- Capture modifier chords such as Control + Option + Shift + Semicolon.
- Capture Hyper + Space, where Hyper means Command + Control + Option + Shift.
- Capture unmodified extended function keys F13 through F24.
- Continue supporting Right Option, Left Option, Right Command, Right Control, and Fn as modifier-only triggers.
- Preserve Hold to Talk and Tap to Toggle semantics.
- Persist the shortcut across relaunches.
- Display the shortcut consistently in Settings, onboarding, the menu-bar hint, and the first-dictation coach.
- Prevent the active dictation shortcut from firing while the recorder is listening for a replacement.
- Reject invalid shortcuts without changing the saved shortcut.
- Provide an explicit reset to Right Option.

The implementation should be a focused hotkey/preferences change. It must not alter audio capture, ASR, transcript delivery, or voice-shortcut expansion.

## 2. Current implementation map

### 2.1 Data and persistence

`Speekium/Sources/Speekium/Settings.swift`

- `TriggerKey` is a five-case enum containing a physical modifier key code, aggregate modifier flag, label, and symbol.
- `Settings.triggerKey` is persisted as a raw string under the unversioned `triggerKey` UserDefaults key.
- The default is Right Option.
- `Settings.activationMode` is persisted independently and must remain independent.
- Changes call `Settings.onChange`, which causes the runtime monitor to rebind.

### 2.2 Runtime monitoring

`Speekium/Sources/Speekium/HotKeyMonitor.swift`

- The monitor listens only for `.flagsChanged` events.
- A global NSEvent monitor handles other applications; a local NSEvent monitor handles Speekium itself.
- It matches one modifier key code and infers press/release from the modifier flag.
- It contains the Hold to Talk and Tap to Toggle state machine.
- Rebinding stops an active dictation, changes the configuration, and reinstalls monitors.
- External timeout cancellation is already supported.

### 2.3 Runtime wiring and user-facing copies

`Speekium/Sources/Speekium/SpeekiumApp.swift`

- Constructs and starts `HotKeyMonitor`.
- Rebinds it through `Settings.onChange`.
- Builds the menu-bar hint from `TriggerKey.symbol` and `TriggerKey.label`.
- Passes the trigger to the first-dictation coach.

`Speekium/Sources/Speekium/SettingsView.swift`

- General → Dictation contains a segmented activation-mode picker and a fixed trigger-key picker.

`Speekium/Sources/Speekium/OnboardingView.swift`

- The preferences step uses the same fixed trigger-key choices.
- The ready step interpolates the selected key label.

`Speekium/Sources/Speekium/FirstDictationCoach.swift`

- Accepts `TriggerKey` and renders a fixed-width key cap and instruction.

`Speekium/Sources/Speekium/AppWindows.swift`

- Threads `TriggerKey` into the first-dictation coach panel.

### 2.4 Existing coverage

`Speekium/Tests/SpeekiumTests/HotKeyMonitorTests.swift`

- Covers only external timeout recovery for Right Option in hold/tap modes.

`Speekium/Tests/SpeekiumTests/VoiceShortcutSettingsTests.swift`

- Covers first-dictation coach copy for Right Option and Fn.
- Provides the existing isolated UserDefaults test pattern.

There are currently no tests for trigger persistence, legacy migration, arbitrary key events, display formatting, invalid shortcut handling, suspension, or rebinding while suspended.

## 3. Recommended architecture

Keep NSEvent monitoring and extend it to key events. Do not introduce a CGEvent tap or a third-party global-hotkey package in this issue.

Reasons:

- The application already requires Accessibility permission and already uses paired global/local NSEvent monitors successfully.
- NSEvent global monitors can observe `.keyDown`, `.keyUp`, and `.flagsChanged` events.
- Hold behavior maps naturally to primary-key down/up edges.
- The issue does not require consuming the shortcut event before the frontmost app sees it.
- A CGEvent tap would add run-loop ownership, timeout recovery, event suppression decisions, and more release risk than this feature needs.

Consequence: a user-selected chord can still be seen by the active application or macOS. Exact matching and UI guidance reduce accidental conflicts, but consuming shortcuts and exhaustive system-conflict detection remain follow-up work.

## 4. Domain model

### 4.1 Add a versioned shortcut value

Create `Speekium/Sources/Speekium/TriggerShortcut.swift`.

Recommended responsibilities:

- Stable, Codable representation of the physical primary key and allowed modifiers.
- Conversion from the five legacy `TriggerKey` presets.
- Validation of captured candidates.
- Normalized conversion between persisted modifiers and `NSEvent.ModifierFlags`.
- Compact display text, long display text, and accessibility/spoken text.
- Semantic identification of printable keys, named keys, function keys, and modifier-only keys.

Recommended public shape:

```swift
struct TriggerShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: TriggerModifiers
    let key: TriggerKeyDescriptor

    static let defaultValue = TriggerShortcut.modifierOnly(.rightOption)
}

struct TriggerModifiers: OptionSet, Codable, Equatable {
    let rawValue: UInt8

    static let command = TriggerModifiers(rawValue: 1 << 0)
    static let control = TriggerModifiers(rawValue: 1 << 1)
    static let option  = TriggerModifiers(rawValue: 1 << 2)
    static let shift   = TriggerModifiers(rawValue: 1 << 3)
}

enum TriggerKeyDescriptor: Codable, Equatable {
    case modifier(TriggerKey)
    case printable(fallbackLabel: String)
    case function(number: Int)
    case named(NamedTriggerKey)
}
```

The exact Codable encoding may differ, but it must be explicit and covered by round-trip tests. Do not persist raw `NSEvent.ModifierFlags` values: they include device/system flags and couple stored data to AppKit bit assignments. Persist only the four supported logical modifiers.

Retain `TriggerKey` as the representation of the existing modifier-only presets. It should no longer be the complete saved preference. Add conversions such as:

```swift
extension TriggerShortcut {
    static func modifierOnly(_ key: TriggerKey) -> TriggerShortcut
}
```

### 4.2 Primary-key semantics

The model must store the real `NSEvent.keyCode` observed during recording. This is the value used for runtime matching and is essential for programmable keyboards.

Store semantic identity alongside the key code for validation and display:

- Function keys: store the function number obtained from `NSEvent.specialKey`.
- Printable keys: store `charactersIgnoringModifiers` as a fallback label.
- Named keys: map Space, Tab, Return, Delete, arrows, Home, End, Page Up, and Page Down to stable names/symbols.
- Modifier-only keys: store the existing `TriggerKey` case so left/right identity remains available.

Important F-key detail: Carbon virtual-key constants define F13 through F20 but not F21 through F24. AppKit's `NSEvent.SpecialKey` defines F13 through F35. Therefore:

- Detect and label F13–F24 through `event.specialKey`, not a Carbon-only key-code table.
- Persist the actual observed `event.keyCode` for matching after relaunch.
- Persist the semantic function number for display after relaunch.

This design supports QMK/VIA devices even when a high function key has no public Carbon `kVK_*` constant.

### 4.3 Modifier normalization

Only Command, Control, Option, and Shift participate in a chord.

Create one conversion function that intersects incoming AppKit flags with those four values. Ignore Caps Lock, Numeric Pad, Help, and Function for ordinary chord matching. Fn remains supported as its existing modifier-only trigger.

Use standard macOS display order everywhere:

1. Control (`⌃`)
2. Option (`⌥`)
3. Shift (`⇧`)
4. Command (`⌘`)
5. Primary key

Examples:

- `⌃⌥⇧;`
- `⌃⌥⇧⌘Space`
- `F13`
- `⌥ Right Option`

Also provide a spoken/accessibility form, for example `Control Option Shift Semicolon`, rather than reading only glyphs.

### 4.4 Validation policy

Implement one shared validator used by the recorder, Settings loading, and tests.

Accept:

- Any non-modifier primary key with one or more of Command, Control, Option, or Shift.
- Unmodified F13 through F24.
- The five existing modifier-only presets.
- Modified F-keys, including F1–F24, if the event is otherwise valid.

Reject:

- An unmodified letter, number, punctuation key, Space, Return, Tab, arrow, or navigation key.
- Escape as a saved shortcut; Escape cancels recording.
- Caps Lock as a primary modifier trigger.
- A chord whose primary event cannot provide a stable key code.
- Unsupported media/system events that are not normal keyboard key events.
- Empty/corrupt decoded values.

Suggested error cases:

```swift
enum TriggerShortcutValidationError: LocalizedError, Equatable {
    case ordinaryKeyRequiresModifier
    case escapeIsReserved
    case unsupportedKey
    case invalidStoredShortcut
}
```

The recorder must keep listening after a rejected candidate and show a concise inline explanation. It must not overwrite the currently saved shortcut until a valid candidate is explicitly saved.

### 4.5 Matching policy

Match the four supported chord modifiers exactly on the primary key-down edge. This prevents a configured `⌥;` shortcut from also firing for `⌃⌥⇧;`.

Ignore Caps Lock and other non-participating device flags when comparing.

After a hold-mode chord has started, releasing any required modifier before the primary key should stop dictation. The later primary-key-up event must not call stop a second time.

Left/right identity is preserved only for modifier-only presets. AppKit's aggregate modifier flags do not reliably distinguish left and right modifiers within a chord, so a captured Control + Option + Shift + Semicolon chord should be described and matched using logical modifiers, regardless of which side produced them.

## 5. Persistence and migration

### 5.1 New key

Add a versioned UserDefaults data key:

```swift
static let triggerShortcut = "triggerShortcut.v1"
```

Encode `TriggerShortcut` as JSON data, following the repository's existing versioned-data precedent for Voice Shortcuts.

### 5.2 Loading order

In `Settings.init(defaults:)`:

1. If `triggerShortcut.v1` exists, decode and validate it.
2. If decoding or validation fails, log the failure and continue to legacy migration.
3. Read the old `triggerKey` string and map any valid `TriggerKey` to a modifier-only `TriggerShortcut`.
4. If neither source is valid, use Right Option.
5. Persist the migrated/fallback value to `triggerShortcut.v1` so subsequent launches use one path.

Do not delete the legacy `triggerKey` key in this release. Leaving it in place makes downgrade behavior less surprising. New custom chords cannot be represented in the old key; the old value simply remains the last legacy fallback.

### 5.3 Settings API

Replace:

```swift
@Published var triggerKey: TriggerKey
```

with:

```swift
@Published var triggerShortcut: TriggerShortcut
```

Its `didSet` should:

- Ignore no-op assignments.
- Encode and persist the new value.
- Invoke the hotkey-configuration callback once.

Add:

```swift
func resetTriggerShortcut() {
    triggerShortcut = .defaultValue
}
```

Rename the broad `onChange` callback to `onHotKeyConfigurationChange` if the refactor remains localized. Both `activationMode` and `triggerShortcut` should invoke it. If renaming would create noisy unrelated churn, keeping `onChange` is acceptable, but the plan's intent should be documented in code.

### 5.4 Transient recorder state

The hotkey monitor must know when the recorder is active. Add non-persisted capture state to `Settings`:

```swift
@Published private(set) var isCapturingTriggerShortcut = false
var onTriggerShortcutCaptureChange: ((Bool) -> Void)?

func beginTriggerShortcutCapture()
func endTriggerShortcutCapture()
```

These methods must be idempotent. The recorder must call `end` on Save, Cancel, and disappearance/window closure.

Keeping this state in `Settings` avoids threading a monitor reference into SwiftUI views and allows the same recorder control to work in both Settings and onboarding. It is runtime coordination state, not a saved preference.

## 6. HotKeyMonitor refactor

### 6.1 API

Change the monitor to accept `TriggerShortcut`:

```swift
init(shortcut: TriggerShortcut, mode: ActivationMode)
func rebind(shortcut: TriggerShortcut, mode: ActivationMode)
```

Listen for:

```swift
[.flagsChanged, .keyDown, .keyUp]
```

Continue using paired global and local monitors. The local monitor must return the original event unchanged.

### 6.2 State

Track these concepts separately:

- `isPhysicalTriggerDown`: protects against duplicate edges and auto-repeat.
- `isActive`: whether dictation is logically active in hold/tap mode.
- `isSuspended`: whether monitors should remain uninstalled while recording a replacement shortcut.

Do not overload one Boolean for all three states.

### 6.3 Modifier-only path

Preserve the current behavior for `.modifier` descriptors:

- Consume only `.flagsChanged` events for the configured physical modifier key code.
- Determine down/up from that modifier's aggregate flag.
- Ignore repeats/duplicate flag-change notifications.
- Run the existing hold/tap transition logic.

This is the backward-compatibility path and should remain directly covered by tests.

### 6.4 Chord/F-key path

For non-modifier primary keys:

On `.keyDown`:

1. Require the configured key code.
2. Ignore `event.isARepeat`.
3. Normalize and exactly compare the four supported modifiers.
4. If this is a new press edge, run the hold/tap press transition.

On `.keyUp`:

1. Require the configured key code.
2. Clear the physical-down state regardless of current modifier flags.
3. In hold mode, stop only if dictation is still active.
4. In tap mode, do not toggle on release.

On `.flagsChanged` while an active hold-mode chord is down:

- If any required modifier is no longer present, clear the physical-down state and stop once.
- Do not stop merely because an unrelated extra modifier was pressed after activation.

This release-order handling prevents a stuck recording when the user releases Control/Option/Shift before the primary key.

### 6.5 Shared activation transitions

Extract press/release behavior into small internal methods, for example:

```swift
private func handlePressEdge()
private func handleReleaseEdge()
```

Both modifier-only and chord paths should call the same activation-mode state machine. Avoid duplicating Hold to Talk and Tap to Toggle logic.

### 6.6 Suspend and resume

Add:

```swift
func suspend()
func resume()
```

Required behavior:

- `suspend` is idempotent.
- If dictation is active, `suspend` calls `onStop` exactly once and clears active state.
- `suspend` removes both event monitors and clears physical edge state.
- `resume` reinstalls monitors using the latest bound shortcut and mode.
- `rebind` updates configuration while suspended but does not reinstall monitors.
- `start` respects `isSuspended`.
- `stop` remains the application-lifecycle teardown and removes monitors.

This detail is essential. Saving a new shortcut changes `Settings.triggerShortcut`, which causes `rebind`. If `rebind` always starts monitors, the newly captured key could trigger dictation before the recorder closes. A first-class suspended state prevents that race.

### 6.7 External cancellation

Preserve `cancelActiveDictation()` behavior for the 45-second timeout and other external stops.

For a chord held during an external stop:

- Clear logical active state.
- Keep enough physical-edge state to ignore repeat key-down events until the real key-up arrives.
- Ensure the next complete press starts immediately in tap mode and normally in hold mode.

## 7. Shortcut recorder UI

### 7.1 New file and implementation surface

Create `Speekium/Sources/Speekium/TriggerShortcutRecorder.swift`.

Use an `NSViewRepresentable` backed by a small `NSView` subclass rather than relying only on SwiftUI keyboard shortcuts.

The AppKit view should:

- Return `true` from `acceptsFirstResponder`.
- Request first-responder status after entering the window.
- Override `keyDown(with:)` to capture ordinary/function/named primary keys.
- Override `flagsChanged(with:)` to capture the five supported modifier-only presets.
- Ignore repeated key-down events.
- Treat Escape as Cancel.
- Send raw events to the shared candidate factory/validator rather than reproducing validation inside the view.

Local capture does not require global Accessibility monitoring; it only needs the Settings/onboarding window to be active.

### 7.2 Interaction flow

Recommended sheet flow:

1. User presses Change….
2. Call `settings.beginTriggerShortcutCapture()` before requesting first responder.
3. Show `Press your desired shortcut` and the current saved shortcut.
4. The next valid event becomes a candidate and is rendered as a key cap.
5. Invalid events show an inline message and leave the saved value untouched.
6. Save assigns the candidate while capture state is still active.
7. Dismiss the sheet, then call `settings.endTriggerShortcutCapture()`.
8. Cancel/Escape dismisses without assignment and ends capture.

Assigning before ending capture is intentional: the monitor receives the rebind while suspended, then resumes once with the new configuration.

Disable Save until a valid candidate exists. Add `.keyboardShortcut(.defaultAction)` to Save only after the recorder view has already intercepted candidate keystrokes. Escape must remain the cancel path.

### 7.3 General Settings layout

In `GeneralTab`, keep the activation segmented control and replace the fixed trigger picker with a row similar to:

```text
Recording shortcut       ⌃⌥⇧;      Change…
                                      Reset to Default
```

Requirements:

- Display the compact shortcut and a useful accessibility label.
- Change… opens the recorder sheet.
- Reset to Default calls `settings.resetTriggerShortcut()`.
- Disable Reset when the shortcut is already Right Option.
- The footer continues to show the selected activation mode's detail.

### 7.4 Onboarding

Replace `KeyPicker` with a compact form of the same recorder control, or refactor `KeyPicker` to present the current `TriggerShortcut` plus Change….

Do not leave onboarding bound to `TriggerKey`, because a user reopening Setup Guide with a custom shortcut must see the actual saved shortcut rather than a missing/incorrect picker selection.

The recorder can be used before the runtime hotkey exists; the capture-state callback is optional and therefore safe at this stage.

### 7.5 Window lifecycle

The recorder must end capture in all exit paths:

- Save
- Cancel button
- Escape
- Sheet dismissal
- Parent window close
- SwiftUI view disappearance

Use idempotent Settings methods so duplicate cleanup calls are harmless.

## 8. Runtime and copy updates

### 8.1 SpeekiumApp.swift

Update all `settings.triggerKey` references to `settings.triggerShortcut`.

- Construct/rebind `HotKeyMonitor` with the new value.
- Set `settings.onTriggerShortcutCaptureChange` after constructing the monitor:

```swift
settings.onTriggerShortcutCaptureChange = { [weak self] capturing in
    guard let hotkey = self?.hotkey else { return }
    capturing ? hotkey.suspend() : hotkey.resume()
}
```

- Clear the callback or safely tear down the monitor during termination if needed.
- Build the menu hint from one formatter property instead of concatenating symbol and label fields.

Example menu hints:

- `Hold ⌃⌥⇧; to dictate`
- `Tap F13 to dictate`
- `Hold ⌥ Right Option to dictate`

### 8.2 Onboarding copy

Update `readyBlurb` to use the shortcut's readable display name.

Examples:

- `Hold Control Option Shift Semicolon anywhere, speak, and let go.`
- `Tap F13 to start, speak, and tap it again.`

Use readable words where a glyph-heavy string would be unclear in a sentence.

### 8.3 FirstDictationCoach.swift and AppWindows.swift

Change panel/view/window APIs from `TriggerKey` to `TriggerShortcut`.

The current animated key cap is 108 points wide. Make it adapt to longer chords:

- Increase its maximum width or compute width from the rendered shortcut.
- Preserve a compact single-line display for combinations such as `⌃⌥⇧⌘Space`.
- Keep a readable accessibility label.
- Update the instruction factory to accept `TriggerShortcut`.

### 8.4 Permission copy

Generic phrases such as `trigger key` can remain, but `recording shortcut` is clearer after this feature. Update Settings and onboarding permission descriptions together if changing terminology.

## 9. File-by-file implementation checklist

### New: `Sources/Speekium/TriggerShortcut.swift`

- Add `TriggerModifiers`.
- Add semantic primary-key descriptors.
- Add `TriggerShortcut` and default/legacy constructors.
- Add AppKit event-to-candidate conversion.
- Add validation and localized errors.
- Add display/accessibility formatting.
- Add F13–F24 recognition through `NSEvent.SpecialKey`.

### New: `Sources/Speekium/TriggerShortcutRecorder.swift`

- Add the first-responder AppKit capture view.
- Add SwiftUI wrapper/coordinator.
- Add recorder sheet and reusable display/control.
- Implement Save, Cancel, Escape, invalid-message, and cleanup paths.

### Modify: `Sources/Speekium/Settings.swift`

- Retain `TriggerKey` as legacy modifier-only metadata.
- Replace `triggerKey` preference with `triggerShortcut`.
- Add `triggerShortcut.v1` persistence and legacy migration.
- Add reset API.
- Add transient capture-state coordination.
- Update/rename the hotkey configuration callback.

### Modify: `Sources/Speekium/HotKeyMonitor.swift`

- Accept `TriggerShortcut`.
- Monitor flags-changed, key-down, and key-up events.
- Branch modifier-only and chord matching.
- Share activation transitions.
- Add exact modifier matching, repeat suppression, release-order handling, and suspension.
- Preserve timeout cancellation.

### Modify: `Sources/Speekium/SettingsView.swift`

- Replace the fixed picker with the reusable recorder control.
- Add Change… and Reset to Default.
- Present validation without modifying the saved value.

### Modify: `Sources/Speekium/OnboardingView.swift`

- Use the new recorder control/value.
- Update ready-step text.
- Remove bindings that assume every value is a `TriggerKey` enum case.

### Modify: `Sources/Speekium/SpeekiumApp.swift`

- Construct and rebind with `triggerShortcut`.
- Wire recorder suspension.
- Update menu hint formatting.
- Pass the new value to the first-dictation coach.

### Modify: `Sources/Speekium/FirstDictationCoach.swift`

- Accept/display arbitrary shortcuts.
- Update instruction formatting and adaptive layout.

### Modify: `Sources/Speekium/AppWindows.swift`

- Thread `TriggerShortcut` into coach creation.

### Modify: documentation

- `README.md`: keep Right Option as the default quick-start instruction, then mention Settings → General → Recording Shortcut and examples such as F13/custom chords.
- `HANDOFF.md`: change the HotKeyMonitor architecture note from flags-changed-only to flags-changed plus key-down/up.
- `INSTALL.md`: no structural change is required; update terminology only if the Settings label changes.

## 10. Automated test plan

### 10.1 New `TriggerShortcutTests.swift`

Add tests for:

- Default value is Right Option.
- Every legacy `TriggerKey` converts to a valid modifier-only shortcut.
- Codable round-trip preserves key code, logical modifiers, semantic key identity, and fallback label.
- Modifier normalization includes only Command/Control/Option/Shift.
- Display order is Control, Option, Shift, Command.
- Semicolon chord displays as `⌃⌥⇧;`.
- Hyper + Space displays correctly and has a readable accessibility label.
- F13, F14, F18, F20, F21, and F24 semantic identities format correctly.
- Unmodified F13–F24 validate.
- Unmodified ordinary keys fail with `ordinaryKeyRequiresModifier`.
- Escape fails/cancels.
- Modified printable, named, and function keys validate.
- Caps Lock and unsupported media/system events fail gracefully.

Event conversion tests should use synthetic `NSEvent.keyEvent` values where AppKit permits. F21–F24 must still receive manual hardware QA because public Carbon key-code constants do not cover them.

### 10.2 Settings persistence/migration tests

Add to a dedicated `TriggerShortcutSettingsTests.swift` or the existing Settings test file:

- New defaults load Right Option and persist `triggerShortcut.v1`.
- Legacy `triggerKey = leftOption` migrates to the equivalent modifier-only shortcut.
- Repeat construction uses the new data key.
- A custom semicolon chord survives a Settings reload.
- An F13 shortcut survives a Settings reload.
- Corrupt new data falls back to a valid legacy key.
- Corrupt new data plus invalid legacy data falls back to Right Option.
- Reset returns to Right Option and persists.
- No-op assignment does not rebind unnecessarily.
- Activation mode still persists independently.
- Capture state is not persisted.

### 10.3 Expand `HotKeyMonitorTests.swift`

Keep existing timeout tests and add:

- Legacy Right Option hold: press starts, release stops.
- Legacy modifier tap: alternate press edges start and stop.
- Custom chord hold: matching key-down starts and key-up stops.
- Custom chord tap: key-up does not toggle; second valid key-down stops.
- Missing modifier does not trigger.
- Extra supported modifier does not trigger under exact-match policy.
- Caps Lock does not prevent an otherwise exact match.
- Unrelated key events do not change state.
- Repeated key-down events do not duplicate start/stop.
- Releasing a required modifier before the primary key stops hold mode once.
- Later primary-key-up after modifier-first release does not stop twice.
- Unmodified F13 works in both hold and tap modes.
- External timeout suppresses a later hold release for a chord.
- External timeout makes the next tap start normally for a chord.
- `suspend()` stops an active dictation exactly once and ignores events.
- `rebind()` while suspended changes configuration without reinstalling/activating.
- `resume()` uses the newly rebound shortcut.
- Save/resume while the capture key is still physically held does not trigger.

To make monitor installation testable without real global hooks, keep event handling internal and consider injecting monitor installation/removal only if suspension tests cannot otherwise observe behavior. Avoid introducing abstraction solely for coverage if the state machine can be tested directly.

### 10.4 Coach/copy tests

Update the existing first-dictation coach test to cover:

- Right Option hold copy.
- F13 tap copy.
- A multi-modifier semicolon chord.
- Hyper + Space layout/accessibility formatting helper.

### 10.5 Required command

Run from `Speekium/`:

```bash
swift test
```

The pre-change baseline is 77 passing tests. Luna should report the new total and confirm zero failures.

## 11. Manual QA matrix

Automated tests cannot prove global event delivery from real programmable keyboards. Complete this matrix on a signed development build with Accessibility permission granted.

### 11.1 Shortcuts

- Right Option (legacy default)
- Left Option
- Right Command
- Right Control
- Fn
- Control + Option + Shift + Semicolon
- Hyper + Space
- F13
- F14
- F18
- F20
- F21
- F22
- F23
- F24

For F21–F24, use a real QMK/VIA mapping if available and record the observed `NSEvent.keyCode` in QA notes.

### 11.2 Modes

Run every representative shortcut in both:

- Hold to Talk
- Tap to Toggle

Verify key-repeat and release-order behavior, especially releasing modifiers before the primary key.

### 11.3 Recorder safety

- Press Change… and then press the currently active shortcut; dictation must not begin.
- Record a new shortcut, keep the keys held briefly, save, and release; dictation must not begin.
- Cancel with Escape; the old shortcut must resume.
- Close the sheet/window without saving; the old shortcut must resume.
- Enter an invalid unmodified letter; show an error and keep listening.
- Reset to Default; Right Option must work immediately.

### 11.4 Persistence and surfaces

- Relaunch after setting a chord and after setting F13.
- Confirm Settings, onboarding, menu-bar hint, and first-dictation coach show the same shortcut.
- Reopen Setup Guide when a custom shortcut is already saved.
- Confirm activation mode remains unchanged when changing/resetting the shortcut.

### 11.5 Keyboard/application coverage

- US keyboard layout
- At least one non-US layout relevant to early feedback, preferably Polish or German
- QMK/VIA programmable keyboard
- TextEdit or Notes
- Terminal
- iTerm2 for trigger detection only; text insertion compatibility is tracked separately in issue #5
- VS Code or Cursor
- Slack
- Chrome

The selected shortcut should trigger consistently. Because NSEvent monitors are observational, also note whether the active app performs its own action for the chosen chord. That is conflict information, not a failure unless Speekium itself misbehaves.

### 11.6 Permission failure

- Revoke Accessibility and verify the local recorder still captures while Settings is active.
- Verify global triggering remains unavailable without Accessibility, matching current behavior.
- Re-grant Accessibility and confirm monitoring resumes without corrupting the saved shortcut.

## 12. Implementation sequence for Luna

Recommended commit sequence:

### Commit 1 — Shortcut model and migration

- Add `TriggerShortcut.swift`.
- Refactor Settings persistence to `triggerShortcut.v1`.
- Add migration, validation, formatting, and Settings tests.
- Temporarily adapt existing callers through conversion helpers if needed to keep the commit compiling.

Exit condition: new model round-trips, legacy defaults migrate, and tests pass.

### Commit 2 — Runtime event state machine

- Refactor `HotKeyMonitor` to the new model.
- Add key-down/up monitoring, chord matching, F-key support, release-order handling, suspension, and expanded tests.
- Update `SpeekiumApp` construction/rebinding enough to compile.

Exit condition: all runtime state-machine tests pass and modifier-only behavior is unchanged.

### Commit 3 — Recorder and monitor coordination

- Add the AppKit recorder view and SwiftUI sheet/control.
- Add Settings capture state and AppDelegate suspend/resume wiring.
- Replace the General Settings picker.

Exit condition: old/new shortcuts cannot fire while the recorder is active; Save/Cancel/close are safe.

### Commit 4 — Onboarding, coach, menu, and docs

- Reuse the recorder control in onboarding.
- Update menu hints, ready copy, coach APIs/layout, AppWindows, README, and HANDOFF.
- Update copy/formatting tests.

Exit condition: every user-facing surface renders the persisted shortcut consistently.

### Commit 5 — QA fixes only

- Run the real-device/application matrix.
- Fix only defects found by QA.
- Record any event-code peculiarities for F21–F24 in the PR description.

## 13. Risks and mitigations

### Risk: recorder fires the current/new shortcut

Mitigation: explicit HotKeyMonitor suspension; rebind remains suspended; resume only after sheet cleanup.

### Risk: hold dictation becomes stuck when release order changes

Mitigation: observe both primary key-up and required-modifier loss; centralize idempotent release-edge logic; test both orders.

### Risk: F21–F24 lack Carbon virtual-key constants

Mitigation: use `NSEvent.SpecialKey` for semantic recognition and persist the observed event key code. Require QMK/VIA manual QA.

### Risk: custom keyboard layout displays the wrong character

Mitigation: persist a captured `charactersIgnoringModifiers` fallback and use explicit names for special keys. If adding current-layout translation, keep the captured label as fallback for IMEs/non-Unicode layouts.

### Risk: invalid/corrupt preference prevents dictation

Mitigation: validate on decode, migrate/fallback deterministically, log failure, and always end with Right Option as a valid default.

### Risk: custom chord conflicts with macOS or the active app

Mitigation in this issue: exact modifier matching, validation, and explanatory UI. Do not claim conflict-free behavior.

Future option: use Carbon hotkey registration or a CGEvent tap if event consumption/conflict reservation becomes a product requirement.

### Risk: long chord clips the coach/menu UI

Mitigation: one shared formatter plus adaptive coach width; test Hyper + Space and accessibility labels.

### Risk: refactor breaks first-run setup

Mitigation: reuse one control/model in General Settings and onboarding; test default/migrated/custom values; manually reopen Setup Guide with a custom value.

## 14. Explicit non-goals for issue #4

Do not include these in the first implementation unless separately approved:

- Multiple recording shortcuts.
- Shortcut-to-language-profile mapping.
- Import/export of recording shortcuts.
- Full macOS/application shortcut conflict database.
- Event suppression/consumption through CGEvent taps.
- Per-application shortcuts.
- Global shortcut enable/disable scheduling.
- Changes to Voice Shortcuts, ASR context, or transcript insertion.

The issue's `Nice to have` conflict detection can be a follow-up. A small non-blocking warning for a few obvious system chords is acceptable only after the required behavior and tests are complete.

## 15. Definition of done

Implementation is complete only when all of the following are true:

- A user can record Control + Option + Shift + Semicolon and Hyper + Space.
- A user can record and use F13 through F24 from a programmable keyboard.
- The five previous modifier presets still work in both activation modes.
- The saved shortcut survives relaunch and legacy preferences migrate without user action.
- The same shortcut is displayed in General Settings, onboarding, menu-bar hint, and first-dictation coach.
- Invalid input leaves the previous shortcut unchanged and provides actionable feedback.
- Reset to Default immediately restores Right Option.
- The hotkey never starts dictation while the recorder is active, including during Save/rebind.
- Releasing the primary key or required modifiers cannot strand hold-mode dictation.
- Existing timeout cancellation still works.
- `swift test` passes with expanded model, persistence, monitor, and coach coverage.
- Real QMK/VIA QA confirms F21–F24 behavior and records observed key codes.
- README/HANDOFF descriptions match the shipped implementation.

## 16. Handoff note for Luna

Implement against commit `983f3fc` (or a descendant containing the same release work). The analyzed branch is not at `origin/master`; starting from an older branch will miss current onboarding, first-dictation coach, update, and Voice Shortcut code referenced by this plan.

Before editing:

1. Confirm `git status` is clean.
2. Confirm the expected commit/branch.
3. Run `swift test` and preserve the 77-test green baseline.
4. Treat the migration and recorder-suspension tests as required, not optional polish.

In the final PR description, include:

- The saved schema and migration behavior.
- The exact matching policy.
- The F13–F24 devices tested and observed key codes.
- Hold/tap manual QA results.
- Confirmation that recorder capture cannot trigger dictation.
- Final automated test count.
