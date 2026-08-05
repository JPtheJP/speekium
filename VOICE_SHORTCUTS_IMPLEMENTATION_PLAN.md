# Voice Shortcuts — Detailed Implementation Plan

Status: design approved for implementation; no implementation has been made yet.

Audience: Luna, or the next engineer implementing the feature.

## 1. Feature summary

Voice Shortcuts let a user associate a spoken trigger with literal text. When a
finished dictation consists of that trigger, WhisprStream inserts the saved text
instead of the recognized trigger.

Example:

```text
Trigger:     haha github
Replacement: https://github.com/Leo6Leo

Spoken audio:       "Haha, GitHub."
Raw ASR result:     "Haha, GitHub."
Delivered text:     "https://github.com/Leo6Leo"
```

A trigger may be either:

- A single word, such as `pineapple`
- A phrase, such as `haha github`

Both are valid. Single-word triggers must not be blocked, but the UI should warn
that they have a higher chance of accidental activation.

Use the product name **Voice Shortcuts** in the UI. Avoid calling the saved text
a model "prompt": this feature performs deterministic text substitution and does
not invoke an LLM.

## 2. V1 product decisions

These decisions are part of the v1 contract and should not be changed during
implementation without confirming with the product owner.

### 2.1 Boundary-aware trigger matching

A trigger matches anywhere in the final transcript when it appears as a complete
sequence of normalized tokens. This supports a trigger spoken by itself as well
as a trigger embedded in a sentence.

| Final ASR transcript | Saved trigger | Match? |
|---|---|---|
| `Haha, GitHub.` | `haha github` | Yes |
| `Pineapple!` | `pineapple` | Yes |
| `Open haha github` | `haha github` | Yes → `Open <replacement>` |
| `pineapple is my favorite` | `pineapple` | Yes → `<replacement> is my favorite` |

Replacement requires token boundaries, so a `pineapple` shortcut does not match
inside `pineapples` or another longer token. When a phrase and a single-word
shortcut could match at the same position, the longer phrase wins. Multiple
non-overlapping matches may expand in one transcript.

### 2.2 Exact normalized matching, not fuzzy matching

Matching may ignore case, whitespace variation, and punctuation, but it must not
use edit distance, semantic similarity, phonetic similarity, or substring
matching. A near-match must remain ordinary dictation.

Examples:

| Transcript | Trigger | Match? | Reason |
|---|---|---|---|
| `HAHA,   GITHUB!` | `haha github` | Yes | Case/space/punctuation normalization |
| `ha ha github` | `haha github` | No | Different spoken token sequence |
| `github` | `git hub` | No | Different token sequence |
| `résumé` | `resume` | No | Diacritics remain meaningful |

### 2.3 Final transcript only

Do not expand partial ASR results. The HUD continues to show raw live partials.
Expansion occurs once, after the final ASR event, immediately before the HUD's
final text and the clipboard/cursor delivery are updated.

This prevents the HUD from oscillating between a trigger and a long replacement
as streaming recognition changes.

### 2.4 Literal, one-pass replacement

- Insert the replacement verbatim, including its capitalization and newlines.
- Do not trim, reformat, or add punctuation to the replacement.
- Do not recursively run expansion on replacement text.
- A disabled shortcut never matches and is not sent to the ASR context.
- An unmatched transcript follows the existing behavior byte-for-byte.

## 3. User experience

### 3.1 Settings entry point

Add a **Shortcuts** tab to `SettingsView` with the symbol
`text.badge.plus`. The settings view is currently fixed at 580 x 460 and its own
comment notes that tab labels can overflow. Increase the width enough for five
tabs; start with 680 x 520 and visually verify the result on macOS.

The tab contains:

1. A short explanation: "Say a saved trigger anywhere in a dictation to expand it."
2. A list of saved shortcuts.
3. An Add button.
4. Empty-state guidance when there are no shortcuts.

Each list row shows:

- Enabled/disabled toggle
- Trigger as the primary label
- A one-line, truncated preview of the replacement
- Edit button
- Delete button

Deletion should require a confirmation when the replacement is non-empty. It
does not need Undo in v1.

### 3.2 Add/edit sheet

Use the same sheet for creating and editing a shortcut.

Fields:

- **When I say** — single-line `TextField`
- **Insert this** — multiline native `NSTextView` wrapper with standard Cmd-V,
  selection, undo, contextual menu support, and explicit first-responder focus
- **Enabled** — toggle, default on for new shortcuts

Actions:

- Cancel
- Save

Save is disabled until validation succeeds. Editing uses a draft value and must
not mutate the saved shortcut until Save is selected.

### 3.3 Validation and warnings

Blocking validation:

- Trigger must contain at least one Unicode letter or number after normalization.
- Replacement must contain at least one non-whitespace character.
- The normalized trigger must not duplicate another saved trigger, including a
  disabled shortcut. A shortcut being edited is excluded from its own duplicate
  check.

Non-blocking warning:

- If the normalized trigger contains one token, display:
  "Single-word triggers can activate during ordinary dictation. Choose an
  unusual word for best results."

Do not maintain an English-only list of common words and do not reject short
words. WhisprStream supports mixed Chinese and English, so a language-specific
validator would give inconsistent behavior.

### 3.4 Suggested triggers

Show a "Suggested triggers" section in the Shortcuts tab. Suggestions are
examples only and open the editor with the trigger prefilled; they never create a
shortcut without the user's replacement text.

Use a rare `shortcut` prefix so the triggers are less likely to collide with
ordinary dictation:

- `shortcut github` — GitHub profile or repository
- `shortcut linkedin` — LinkedIn profile
- `shortcut website` — personal website
- `shortcut portfolio` — portfolio or project page
- `shortcut signature` — email signature
- `shortcut email` — reusable email reply
- `shortcut address` — mailing or office address
- `shortcut bio` — developer bio or profile

Keep these suggestions in a small static model so they can be revised without
changing matching logic. Hide a suggestion once its normalized trigger already
exists in the user's list.

### 3.5 Security copy

At the bottom of the tab, show a concise note:

> Shortcuts are stored locally and inserted through the macOS clipboard. Do not
> use them for passwords or API keys.

This feature is suitable for URLs, signatures, addresses, standard replies,
code fragments, and multiline templates. It is not a password manager.

## 4. Data model and persistence

### 4.1 New model

Create `Sources/WhisprStream/VoiceShortcut.swift`:

```swift
struct VoiceShortcut: Codable, Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var replacement: String
    var isEnabled: Bool
}
```

New shortcuts receive a new UUID. IDs remain stable across edits so rows animate
correctly and logs can identify a match without recording its content.

Do not add timestamps, usage counts, aliases, application filters, or match modes
to the v1 schema.

### 4.2 Settings storage

Add this to `Settings`:

```swift
@Published private(set) var voiceShortcuts: [VoiceShortcut]
```

Persist the array as JSON-encoded `Data` in `UserDefaults` under a versioned key:

```text
voiceShortcuts.v1
```

Provide mutation methods instead of exposing a public setter:

```swift
func addVoiceShortcut(_ shortcut: VoiceShortcut) throws
func updateVoiceShortcut(_ shortcut: VoiceShortcut) throws
func removeVoiceShortcut(id: UUID)
func setVoiceShortcutEnabled(id: UUID, enabled: Bool)
```

Define a small `VoiceShortcutValidationError` for an empty trigger, empty
replacement, and duplicate normalized trigger. The add/edit UI should normally
prevent these calls from throwing, but the settings layer remains the source of
truth and must still reject invalid programmatic mutations.

Every mutation must:

1. Validate/deduplicate using the shared trigger normalizer.
2. Update the published array.
3. Persist the full array.
4. Push the newly computed ASR context to the resident sidecar.

On decode failure, log a content-free error and initialize an empty array. Do not
crash app launch. Do not log the stored JSON, triggers, or replacements.

UserDefaults is acceptable for v1 because this is a small local preference set.
If future versions support large libraries, attachments, or syncing, migrate the
data to an Application Support file.

## 5. Trigger normalization and matching

### 5.1 One shared normalizer

Create the normalizer next to the model or in
`Sources/WhisprStream/TranscriptExpander.swift`. Storage validation, duplicate
detection, UI warnings, and runtime matching must all call the same function.
Do not duplicate normalization rules in the view.

Suggested representation:

```swift
struct NormalizedVoiceTrigger: Hashable {
    let tokens: [String]
    var key: String { tokens.joined(separator: "\u{1F}") }
}
```

Normalization algorithm:

1. Apply Unicode compatibility composition/width normalization.
2. Case-fold in a locale-independent manner.
3. Scan Unicode characters into tokens made from letters and numbers.
4. Treat punctuation, symbols, and whitespace as token separators.
5. Preserve diacritics.
6. Discard empty tokens.

The same algorithm is applied to the saved trigger and the final ASR transcript.
Matching is equality of the complete token arrays.

This intentionally makes `Haha, GitHub.` match `haha github` and `I opened
Haha, GitHub.` become `I opened <replacement>.`, while preventing a single-word
trigger from matching a word inside a longer token.

Implementation note: test the chosen Swift Unicode APIs with CJK. A Chinese
phrase without spaces may normalize to one token; that is valid. Do not assume
that every language separates words with ASCII spaces.

### 5.2 Expander API

Create `Sources/WhisprStream/TranscriptExpander.swift` with a pure API similar to:

```swift
struct TranscriptExpansionResult: Equatable {
    let text: String
    let matchedShortcutID: UUID?

    var didExpand: Bool { matchedShortcutID != nil }
}

enum TranscriptExpander {
    static func expand(
        _ transcript: String,
        using shortcuts: [VoiceShortcut]
    ) -> TranscriptExpansionResult
}
```

Behavior:

1. Tokenize and normalize the complete transcript once.
2. Ignore disabled shortcuts.
3. Scan for contiguous token-sequence matches.
4. Prefer the longest phrase at each position.
5. Replace all non-overlapping matches, preserving text outside each match.
6. If the entire utterance is one match, return only the replacement so
   ASR-added terminal punctuation is not pasted after a URL or template.
7. Return the original transcript unchanged if no shortcut matches.

Validated settings prevent duplicate keys. If corrupt or legacy data somehow
contains duplicates, the first saved shortcut wins deterministically and a
content-free warning is logged.

The expected shortcut count is small and utterances are capped at 45 seconds, so
a linear scan is sufficient. Do not introduce a trie, regex engine, or database.

## 6. ASR recognition integration

The Qwen ASR context is soft recognition guidance, not the expansion mechanism.
Expansion remains deterministic in Swift.

### 6.1 Combined ASR context

Replace the vocabulary-only computed property with a combined property:

```swift
var asrContext: String
```

Its newline-separated contents are:

1. Existing vocabulary entries, in their existing order
2. Enabled shortcut triggers, in shortcut list order

Deduplicate identical literal lines while preserving the first occurrence. Do
not add replacement values to the context. Do not add disabled triggers.

Keep `vocabularyContext` only if another caller still needs it; otherwise migrate
call sites to `asrContext` to prevent the two concepts from drifting.

### 6.2 Live updates

The current sidecar accepts live context updates through `ASRService.setContext`.
Reuse that protocol without modifying Python.

Required Swift changes:

- `makeService()` passes `settings.asrContext` at sidecar startup.
- Vocabulary mutations invoke `onContextChange?(asrContext)`.
- Shortcut add/edit/delete/enable mutations invoke
  `onContextChange?(asrContext)`.

No model reload should occur when a shortcut changes.

### 6.3 Recognition limitations

Context bias improves the chance that a rare phrase is returned as saved, but it
does not guarantee hotword recognition. In particular, `haha` might be returned
as `ha ha` or `哈哈` depending on speech and language context. V1 must not paper
over this with fuzzy matching because that raises false activations.

The UI documentation should recommend phonetically distinctive triggers. A
future alias feature can safely handle known alternate transcriptions.

## 7. Final transcript integration

Modify only the `.final` branch in `AppDelegate.handle(_:)`.

Current logical order:

```text
final ASR text -> HUD committed text -> TextInserter.deliver
```

New logical order:

```text
final ASR text
    -> TranscriptExpander.expand
    -> expanded/original output
    -> HUD committed text
    -> TextInserter.deliver
```

Requirements:

- Keep the existing empty-transcript early return before expansion.
- Put the expanded text in `state.committed`, so the HUD confirms what was
  actually delivered.
- Pass the same expanded text to both cursor insertion and clipboard copying.
- Preserve duration metrics and sound behavior.
- Do not change partial-event handling.
- Log only shortcut ID and character counts when a shortcut matches.

Example safe log:

```text
voice shortcut matched id=<uuid> inputChars=13 outputChars=31
```

## 8. Logging and privacy hardening

`TextInserter` currently logs the first 20 characters read back from the
pasteboard. Remove that content from the log as part of this feature. Replace it
with success and length metadata, for example:

```text
pasteboard write=true chars=31
```

Do not log:

- Replacement content
- Raw transcript when a shortcut matches
- Trigger content
- Persisted JSON
- Clipboard readback

This prevents long templates or private snippets from being copied into
`~/Library/Logs/WhisprStream.log`. Clipboard-based insertion still means other
macOS clipboard managers may observe the text, which is why credentials remain
out of scope.

## 9. Files to add or modify

### Add

- `WhisprStream/Sources/WhisprStream/VoiceShortcut.swift`
  - Model and shared trigger normalization/validation types
- `WhisprStream/Sources/WhisprStream/TranscriptExpander.swift`
  - Pure matching and expansion logic
- `WhisprStream/Sources/WhisprStream/VoiceShortcutsView.swift`
  - Settings tab, rows, empty state, and add/edit sheet
- `WhisprStream/Tests/WhisprStreamTests/TranscriptExpanderTests.swift`
  - Normalization and expansion unit tests
- `WhisprStream/Tests/WhisprStreamTests/VoiceShortcutSettingsTests.swift`
  - Persistence/context tests if settings storage is made injectable

### Modify

- `WhisprStream/Sources/WhisprStream/Settings.swift`
  - Published shortcut collection, persistence, mutations, combined ASR context
- `WhisprStream/Sources/WhisprStream/SettingsView.swift`
  - Add Shortcuts tab and update window dimensions
- `WhisprStream/Sources/WhisprStream/WhisprStreamApp.swift`
  - Use combined context and expand final transcript before delivery
- `WhisprStream/Sources/WhisprStream/TextInserter.swift`
  - Remove clipboard content from logs
- `WhisprStream/Package.swift`
  - Add the Swift test target
- `HANDOFF.md`
  - Document the shipped feature and new files after implementation is verified

### No Python change expected

- `WhisprStream/Resources/asr_server.py`
- `WhisprStream/Resources/asr_engine.py`

The existing `context` command is sufficient.

## 10. Implementation sequence

Implement in this order so each stage is independently testable.

### Phase 1 — Pure domain logic

1. Add `VoiceShortcut`.
2. Add shared normalization and validation.
3. Add `TranscriptExpander`.
4. Add a SwiftPM test target.
5. Write and run normalization/expansion tests.

Do not touch UI or ASR wiring until these tests pass.

### Phase 2 — Settings and persistence

1. Load/save `[VoiceShortcut]` through the versioned UserDefaults key.
2. Add mutation methods and duplicate protection.
3. Add the combined `asrContext`.
4. Ensure both vocabulary and shortcut mutations invoke live context updates.
5. Add persistence/context tests where practical.

### Phase 3 — Runtime integration

1. Pass `settings.asrContext` when creating the sidecar.
2. Expand the final transcript before updating the HUD or inserting text.
3. Add content-free match logging.
4. Redact clipboard readback logging.
5. Build and manually verify existing dictation before adding UI.

### Phase 4 — Settings UI

1. Add the Shortcuts tab.
2. Add list, empty state, enabled toggle, and deletion.
3. Add create/edit sheet with draft state.
4. Add blocking validation and single-word warning.
5. Add the clipboard security note.
6. Visually verify tab sizing, long replacement previews, multiline editing,
   VoiceOver labels, keyboard focus, and dark mode.

### Phase 5 — Recognition QA and documentation

1. Test real spoken single-word and phrase triggers.
2. Test both ASR models.
3. Test Chinese, English, and mixed-language dictation.
4. Confirm context changes apply without restarting the model.
5. Update `HANDOFF.md` only after all acceptance criteria pass.

## 11. Automated test matrix

At minimum, include these tests.

### Normalization

- `haha github` equals `Haha, GitHub.`
- `pineapple` equals `PINEAPPLE!`
- Repeated spaces and newlines normalize as separators.
- Leading and trailing punctuation is ignored.
- Internal punctuation separates tokens.
- `haha` does not equal `ha ha`.
- `resume` does not equal `résumé`.
- A Chinese trigger matches the same phrase with terminal Chinese punctuation.
- A mixed Chinese/English phrase matches with case differences in English.
- Punctuation-only input is invalid.

### Expansion

- Enabled single-word trigger expands.
- Enabled phrase trigger expands.
- Disabled trigger does not expand.
- Trigger inside a longer sentence expands at token boundaries.
- Near-match does not expand.
- Multiline replacement is returned byte-for-byte.
- Replacement containing another trigger is not recursively expanded.
- No match returns the original transcript exactly.
- Duplicate normalized triggers are rejected.
- Corrupt duplicate data resolves deterministically without exposing content.

### ASR context

- Existing vocabulary remains present and ordered.
- Enabled triggers are included.
- Disabled triggers are excluded.
- Replacement text is never included.
- A trigger edit pushes a live context update.
- Enabling/disabling pushes a live context update.
- Adding/removing pushes a live context update.
- Vocabulary edits still push the combined context.

## 12. Manual QA checklist

### Regression

- Ordinary dictation with no shortcuts behaves exactly as before.
- Ordinary dictation that does not contain a complete trigger token sequence is unchanged.
- Live HUD partials still update normally.
- Empty or sub-0.3-second dictation still dismisses without insertion.
- Insert-at-cursor and copy-to-clipboard toggles retain current behavior.
- Vocabulary editing still applies live.
- Switching speech models still works.

### Shortcut behavior

- Create, edit, disable, re-enable, and delete a shortcut.
- Restart the app and verify persistence.
- Speak a single-word trigger by itself.
- Speak a phrase trigger by itself.
- Speak the trigger with different casing/punctuation in the final transcript.
- Speak the trigger inside a sentence and confirm only the trigger expands.
- Confirm multiline text pastes correctly.
- Confirm the HUD shows the delivered replacement after final recognition.
- Confirm disabled/deleted triggers stop biasing ASR without an app restart.

### Recognition evaluation

Use the user's real voice, not synthetic speech. For each selected trigger:

1. Record at least 10 standalone attempts.
2. Note the exact failed ASR variants.
3. Test several ordinary negative utterances containing related words.
4. Prefer changing the trigger wording over adding fuzzy matching.

A reasonable v1 release target is at least 9/10 successful recognitions for the
recommended example triggers, with no false expansion in the negative set.

### Privacy

- Search the app log after using a shortcut.
- Verify neither the trigger nor replacement appears.
- Verify ordinary pasteboard logs no longer include content readback.

## 13. Acceptance criteria

The feature is complete only when all of the following are true:

1. Users can save, edit, enable/disable, and delete Voice Shortcuts.
2. Both single-word and phrase triggers are accepted.
3. Single-word triggers show a warning but are not blocked.
4. A complete final transcript containing an enabled normalized trigger is
   expanded with the saved text.
5. A trigger embedded in a longer transcript expands only at token boundaries.
6. Matching ignores case, punctuation, and whitespace variation but is not fuzzy.
7. Longer phrase matches win over shorter matches at the same position.
8. Replacements preserve multiline and Unicode content exactly.
9. The expanded text is shown in the final HUD state and sent consistently to
   both output paths.
10. Enabled triggers are added to the resident ASR context and update live.
11. Replacement values are never sent to ASR.
12. Existing vocabulary and ordinary dictation behavior do not regress.
13. Shortcut and clipboard content do not appear in logs.
14. The app builds successfully and all new unit tests pass.
15. Real-voice QA is completed on both supported ASR models.

## 14. Explicit non-goals for v1

- Fuzzy, phonetic, semantic, or edit-distance matching
- Multiple spoken aliases for one shortcut
- Dynamic variables such as date, time, or clipboard contents
- Cursor-placement markers
- Rich text, images, or files
- Per-application shortcuts
- Cloud sync or sharing
- Import/export
- Usage analytics or counts
- Secure password/API-key storage
- A Python-side hotword engine

These can be layered onto the model later without changing the core final-event
interception point.

## 15. Likely future extension

The safest next enhancement is aliases. If real-voice testing shows that a saved
trigger such as `haha github` is consistently transcribed as `ha ha github`, let
one shortcut own multiple exact normalized aliases. This is safer and more
explainable than global fuzzy matching.

Application-specific matching should remain a separate, explicit mode because
its false-activation profile is materially different from global shortcuts.
