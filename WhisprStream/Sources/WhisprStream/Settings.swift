import AppKit
import SwiftUI

/// Modifier keys usable for push-to-talk.
///
/// Only modifiers are offered: they arrive as `.flagsChanged` and don't collide
/// with an app's own keyboard shortcuts the way a plain letter key would.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightOption, leftOption, rightCommand, rightControl, function

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .rightControl: return 62
        case .function: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .function: return .function
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right Option"
        case .leftOption: return "Left Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .function: return "Fn"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption, .leftOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .function: return "fn"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable {
    case hold, tap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hold: return "Hold to talk"
        case .tap: return "Tap to toggle"
        }
    }

    var detail: String {
        switch self {
        case .hold: return "Hold the key while speaking, release to insert."
        case .tap: return "Tap once to start, tap again to stop and insert."
        }
    }

    var symbol: String {
        switch self {
        case .hold: return "hand.tap.fill"
        case .tap: return "cursorarrow.click.2"
        }
    }
}

/// Language guidance for clips too short to provide reliable language context.
/// Longer utterances always keep automatic multilingual recognition.
enum ShortUtteranceLanguage: String, CaseIterable, Identifiable {
    case chinese, english, cantonese, arabic, german, french, spanish
    case portuguese, indonesian, italian, korean, russian, thai, vietnamese
    case japanese, turkish, hindi, malay, dutch, swedish, danish, finnish
    case polish, czech, filipino, persian, greek, hungarian, macedonian, romanian

    var id: String { rawValue }

    /// Canonical names accepted by Qwen3-ASR's forced-language prompt.
    var modelName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .cantonese: return "Cantonese"
        case .arabic: return "Arabic"
        case .german: return "German"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .korean: return "Korean"
        case .russian: return "Russian"
        case .thai: return "Thai"
        case .vietnamese: return "Vietnamese"
        case .japanese: return "Japanese"
        case .turkish: return "Turkish"
        case .hindi: return "Hindi"
        case .malay: return "Malay"
        case .dutch: return "Dutch"
        case .swedish: return "Swedish"
        case .danish: return "Danish"
        case .finnish: return "Finnish"
        case .polish: return "Polish"
        case .czech: return "Czech"
        case .filipino: return "Filipino"
        case .persian: return "Persian"
        case .greek: return "Greek"
        case .hungarian: return "Hungarian"
        case .macedonian: return "Macedonian"
        case .romanian: return "Romanian"
        }
    }
}

/// User preferences, persisted to UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var triggerKey: TriggerKey {
        didSet { defaults.set(triggerKey.rawValue, forKey: Keys.triggerKey); onChange?() }
    }

    @Published var activationMode: ActivationMode {
        didSet { defaults.set(activationMode.rawValue, forKey: Keys.activationMode); onChange?() }
    }

    /// Insert the transcript at the active app's cursor.
    @Published var autoInsert: Bool {
        didSet { defaults.set(autoInsert, forKey: Keys.autoInsert) }
    }

    /// Keep the finished transcript on the clipboard after dictation.
    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    /// Keep sentence-ending punctuation from the speech model. When disabled,
    /// finished dictations end with a space instead so the next dictation does
    /// not run into the previous one.
    @Published var usePunctuation: Bool {
        didSet { defaults.set(usePunctuation, forKey: Keys.usePunctuation) }
    }

    /// A user-selected tie-breaker for context-poor, very short recordings.
    /// Changing it restarts the sidecar because preview reuse must never cross
    /// between forced- and automatically-detected language modes.
    @Published var shortUtteranceLanguage: ShortUtteranceLanguage {
        didSet {
            guard shortUtteranceLanguage != oldValue else { return }
            defaults.set(shortUtteranceLanguage.rawValue, forKey: Keys.shortUtteranceLanguage)
            onShortUtteranceLanguageChange?(shortUtteranceLanguage)
        }
    }

    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }

    /// Which sound plays around a dictation — a designed pair, or one of
    /// macOS's own alert sounds as before.
    @Published var soundTheme: SoundTheme {
        didSet {
            defaults.set(soundTheme.storageValue, forKey: Keys.soundTheme)
            warm(soundTheme)
        }
    }

    /// Every playable macOS alert sound, system then user.
    static var availableSounds: [String] { SoundPlayer.available }

    /// Registers the files up front so the first play isn't slower than the rest.
    private func warm(_ theme: SoundTheme) {
        switch theme {
        case let .pair(pair):
            SoundPlayer.shared.prepareBundled(pair.startFile)
            SoundPlayer.shared.prepareBundled(pair.finishFile)
        case let .system(name):
            SoundPlayer.shared.prepare(name)
        }
    }

    /// Called when dictation begins.
    ///
    /// Only pairs have a start half. A macOS alert sound stays finish-only, which
    /// is exactly how the app behaved before pairs existed.
    func playStart() {
        guard playSound, case let .pair(pair) = soundTheme else { return }
        SoundPlayer.shared.playBundled(pair.startFile)
    }

    /// Called when a transcript is inserted.
    func playFeedback() {
        guard playSound else { return }
        playFinishSound()
    }

    private func playFinishSound() {
        switch soundTheme {
        case let .pair(pair): SoundPlayer.shared.playBundled(pair.finishFile)
        case let .system(name): SoundPlayer.shared.play(name)
        }
    }

    /// Auditions the whole cycle: start, then finish once the start has rung.
    ///
    /// Ignores the enable toggle — the user pressed the button, so they want to
    /// hear it.
    func previewSound() {
        guard case let .pair(pair) = soundTheme else {
            playFinishSound()
            return
        }
        SoundPlayer.shared.playBundled(pair.startFile)
        let gap = pair.startDuration + 0.28
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.playFinishSound()
        }
    }

    /// Vocabulary entries used to bias decoding. Each entry may be a word or a
    /// phrase; the array is the source of truth so spaces do not become data
    /// delimiters.
    ///
    /// The running sidecar receives a newline-separated prompt whenever this
    /// array changes. Persisting alone is not enough: the sidecar reads its
    /// startup value from the environment, so edits must also be pushed live.
    @Published private(set) var vocabularyEntries: [String] {
        didSet {
            defaults.set(vocabularyEntries, forKey: Keys.vocabularyEntries)
            onContextChange?(asrContext)
        }
    }

    /// Vocabulary plus enabled Voice Shortcut triggers, sent to the resident
    /// ASR sidecar as newline-separated soft recognition context.
    var asrContext: String {
        var lines: [String] = []
        var seen = Set<String>()
        for line in vocabularyEntries + voiceShortcuts.filter(\.isEnabled).map(\.trigger) {
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    @Published private(set) var voiceShortcuts: [VoiceShortcut] {
        didSet {
            guard voiceShortcuts != oldValue else { return }
            persistVoiceShortcuts()
            onContextChange?(asrContext)
        }
    }

    func addVoiceShortcut(_ shortcut: VoiceShortcut) throws {
        try VoiceShortcutValidation.validate(shortcut, against: voiceShortcuts)
        voiceShortcuts.append(shortcut)
    }

    func updateVoiceShortcut(_ shortcut: VoiceShortcut) throws {
        try VoiceShortcutValidation.validate(
            shortcut,
            against: voiceShortcuts,
            excluding: shortcut.id
        )
        guard let index = voiceShortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        voiceShortcuts[index] = shortcut
    }

    func removeVoiceShortcut(id: UUID) {
        voiceShortcuts.removeAll { $0.id == id }
    }

    func setVoiceShortcutEnabled(id: UUID, enabled: Bool) {
        guard let index = voiceShortcuts.firstIndex(where: { $0.id == id }),
              voiceShortcuts[index].isEnabled != enabled else { return }
        voiceShortcuts[index].isEnabled = enabled
    }

    private func persistVoiceShortcuts() {
        guard let data = try? JSONEncoder().encode(voiceShortcuts) else {
            Log.write("voice shortcuts save failed")
            return
        }
        defaults.set(data, forKey: Keys.voiceShortcuts)
    }

    /// Replaces the complete vocabulary after applying the same normalization
    /// and case-sensitive de-duplication used by manual entry and imports.
    func setVocabulary(_ entries: [String]) {
        vocabularyEntries = VocabularyEntry.normalizedUnique(entries)
    }

    /// Which speech model the sidecar loads.
    ///
    /// Unlike the vocabulary this cannot be applied live — the weights are loaded
    /// once at sidecar start — so changing it restarts the sidecar and pays the
    /// model load again.
    @Published var model: ASRModel {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model.rawValue, forKey: Keys.model)
            onModelChange?(model)
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    /// True while the sidecar is reloading after a model switch. Drives the
    /// Settings UI only; the HUD has its own `.loading` phase.
    @Published var isReloadingModel = false

    /// Fired when a change requires the hotkey monitor to be rebound.
    var onChange: (() -> Void)?

    /// Fired when vocabulary or Voice Shortcuts change, to push the combined
    /// context to the live sidecar.
    var onContextChange: ((String) -> Void)?

    /// Fired when the model changes, to restart the sidecar on the new weights.
    var onModelChange: ((ASRModel) -> Void)?

    /// Fired when short-utterance language guidance changes. Like the model,
    /// this is a sidecar startup option and therefore requires a restart.
    var onShortUtteranceLanguageChange: ((ShortUtteranceLanguage) -> Void)?

    private let defaults: UserDefaults

    private enum Keys {
        static let triggerKey = "triggerKey"
        static let activationMode = "activationMode"
        static let autoInsert = "autoInsert"
        static let copyToClipboard = "copyToClipboard"
        static let usePunctuation = "usePunctuation"
        static let shortUtteranceLanguage = "shortUtteranceLanguage"
        static let playSound = "playSound"
        static let insertSound = "insertSound"   // pre-pairs; read once to migrate
        static let soundTheme = "soundTheme"
        static let contextTerms = "contextTerms"
        static let vocabularyEntries = "vocabularyEntries"
        static let voiceShortcuts = "voiceShortcuts.v1"
        static let model = "model"
        static let onboarded = "hasCompletedOnboarding"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: Keys.triggerKey) ?? "")
            ?? .rightOption
        activationMode = ActivationMode(rawValue: defaults.string(forKey: Keys.activationMode) ?? "")
            ?? .hold
        autoInsert = defaults.object(forKey: Keys.autoInsert) as? Bool ?? true
        copyToClipboard = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        usePunctuation = defaults.object(forKey: Keys.usePunctuation) as? Bool ?? true
        shortUtteranceLanguage = ShortUtteranceLanguage(
            rawValue: defaults.string(forKey: Keys.shortUtteranceLanguage) ?? ""
        ) ?? .english
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? false
        // Migration: before pairs, the choice lived in `insertSound` as a bare
        // alert-sound name. Carry it over so an existing setting is preserved
        // rather than silently reset to a new default.
        soundTheme = SoundTheme(storageValue: defaults.string(forKey: Keys.soundTheme) ?? "")
            ?? SoundTheme(storageValue: defaults.string(forKey: Keys.insertSound) ?? "")
            ?? .pair(.openResolve)

        if let stored = defaults.array(forKey: Keys.vocabularyEntries) as? [String] {
            vocabularyEntries = VocabularyEntry.normalizedUnique(stored)
        } else {
            // Legacy versions stored a whitespace-delimited string. That format
            // cannot recover phrases, but migrating it preserves every existing
            // single-word entry and gives future edits a lossless representation.
            let legacy = defaults.string(forKey: Keys.contextTerms) ?? ""
            let entries = legacy.split(whereSeparator: \.isWhitespace).map(String.init)
            let migrated = VocabularyEntry.normalizedUnique(entries)
            defaults.set(migrated, forKey: Keys.vocabularyEntries)
            vocabularyEntries = migrated
        }
        if let data = defaults.data(forKey: Keys.voiceShortcuts) {
            do {
                voiceShortcuts = try JSONDecoder().decode([VoiceShortcut].self, from: data)
            } catch {
                Log.write("voice shortcuts load failed; starting empty")
                voiceShortcuts = []
            }
        } else {
            voiceShortcuts = []
        }
        model = ASRModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .small
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)

        warm(soundTheme)
    }
}
