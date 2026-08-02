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

    /// Insert at the cursor. When off, the transcript only goes to the clipboard.
    @Published var autoInsert: Bool {
        didSet { defaults.set(autoInsert, forKey: Keys.autoInsert) }
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

    /// Domain terms biasing decoding — useful for technical jargon and names.
    ///
    /// Pushed to the running sidecar on every edit. Persisting alone is not
    /// enough: the sidecar reads its startup value from the environment, so a
    /// change made after launch would otherwise not apply until the next launch.
    @Published var contextTerms: String {
        didSet {
            defaults.set(contextTerms, forKey: Keys.contextTerms)
            onContextChange?(contextTerms)
        }
    }

    /// The vocabulary as discrete terms.
    ///
    /// Storage stays one whitespace-joined string: that is the exact text the
    /// model's system prompt receives, so keeping it as the source of truth means
    /// the UI can never drift from what is actually sent.
    var contextTermList: [String] {
        get { contextTerms.split(whereSeparator: \.isWhitespace).map(String.init) }
        set { contextTerms = newValue.joined(separator: " ") }
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

    /// Fired when the vocabulary changes, to push it to the live sidecar.
    var onContextChange: ((String) -> Void)?

    /// Fired when the model changes, to restart the sidecar on the new weights.
    var onModelChange: ((ASRModel) -> Void)?

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let triggerKey = "triggerKey"
        static let activationMode = "activationMode"
        static let autoInsert = "autoInsert"
        static let playSound = "playSound"
        static let insertSound = "insertSound"   // pre-pairs; read once to migrate
        static let soundTheme = "soundTheme"
        static let contextTerms = "contextTerms"
        static let model = "model"
        static let onboarded = "hasCompletedOnboarding"
    }

    private init() {
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: Keys.triggerKey) ?? "")
            ?? .rightOption
        activationMode = ActivationMode(rawValue: defaults.string(forKey: Keys.activationMode) ?? "")
            ?? .hold
        autoInsert = defaults.object(forKey: Keys.autoInsert) as? Bool ?? true
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? false
        // Migration: before pairs, the choice lived in `insertSound` as a bare
        // alert-sound name. Carry it over so an existing setting is preserved
        // rather than silently reset to a new default.
        soundTheme = SoundTheme(storageValue: defaults.string(forKey: Keys.soundTheme) ?? "")
            ?? SoundTheme(storageValue: defaults.string(forKey: Keys.insertSound) ?? "")
            ?? .pair(.openResolve)

        contextTerms = defaults.string(forKey: Keys.contextTerms) ?? ""
        model = ASRModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .small
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)

        warm(soundTheme)
    }
}
