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
    @Published var phase: Phase = .loading
    @Published var committed: String = ""
    @Published var tail: String = ""
    @Published var level: CGFloat = 0        // 0...1 mic level, smoothed
    @Published var lastDurationMS: Int = 0
    @Published var lastAudioSecs: Double = 0

    /// Text shown in the HUD: settled prefix plus the still-changing tail.
    var displayText: String { committed + tail }

    var isVisible: Bool {
        switch phase {
        case .idle: return false
        default: return true
        }
    }

    func reset() {
        committed = ""
        tail = ""
        level = 0
    }
}
