import SwiftUI

/// What the HUD is showing. Drives every animation in `HUDView`.
enum Phase: Equatable {
    case idle
    case loading
    case listening
    case thinking
    case inserted
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {
    static let dictationLimitSeconds: TimeInterval = 45
    static let dictationWarningLeadTimeSeconds: TimeInterval = 3

    @Published var phase: Phase = .loading
    @Published var committed: String = ""
    @Published var tail: String = ""
    @Published var level: CGFloat = 0        // 0...1 mic level, smoothed
    @Published var lastDurationMS: Int = 0
    @Published var lastAudioSecs: Double = 0
    @Published var dictationElapsedSeconds: TimeInterval = 0

    var onDictationLimitReached: (() -> Void)?

    private var dictationTimer: Timer?
    private var dictationStartedAt: Date?
    private var didReachDictationLimit = false

    /// Text shown in the HUD: settled prefix plus the still-changing tail.
    var displayText: String { committed + tail }

    var isApproachingDictationLimit: Bool {
        guard phase == .listening else { return false }
        return dictationElapsedSeconds >= Self.dictationLimitSeconds
            - Self.dictationWarningLeadTimeSeconds
    }

    var dictationRemainingSeconds: TimeInterval {
        max(0, Self.dictationLimitSeconds - dictationElapsedSeconds)
    }

    var dictationCountdownLabel: String {
        "\(Int(ceil(dictationRemainingSeconds)))s"
    }

    var isVisible: Bool {
        switch phase {
        case .idle: return false
        default: return true
        }
    }

    func reset() {
        stopDictationTimer()
        committed = ""
        tail = ""
        level = 0
        dictationElapsedSeconds = 0
    }

    func startDictationTimer() {
        stopDictationTimer()
        dictationElapsedSeconds = 0
        didReachDictationLimit = false
        let startedAt = Date()
        dictationStartedAt = startedAt
        dictationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let startedAt = self.dictationStartedAt else { return }
                self.dictationElapsedSeconds = Date().timeIntervalSince(startedAt)
                guard self.dictationElapsedSeconds >= Self.dictationLimitSeconds,
                      !self.didReachDictationLimit else { return }
                self.didReachDictationLimit = true
                self.onDictationLimitReached?()
            }
        }
    }

    func stopDictationTimer() {
        dictationTimer?.invalidate()
        dictationTimer = nil
        dictationStartedAt = nil
        didReachDictationLimit = false
    }
}
