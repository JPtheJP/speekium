import Foundation

struct VoiceShortcut: Codable, Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var replacement: String
    var isEnabled: Bool
}

struct VoiceShortcutSuggestion: Identifiable, Hashable {
    let trigger: String
    let detail: String
    let symbol: String

    var id: String { trigger }
}

enum VoiceShortcutSuggestions {
    /// Suggestions are deliberately unusual and easy to pronounce. They are
    /// examples only: selecting one opens the editor with the trigger filled in
    /// but never creates a shortcut without a user-provided replacement.
    static let all: [VoiceShortcutSuggestion] = [
        VoiceShortcutSuggestion(trigger: "shortcut github", detail: "GitHub profile or repository", symbol: "chevron.left.forwardslash.chevron.right"),
        VoiceShortcutSuggestion(trigger: "shortcut linkedin", detail: "LinkedIn profile", symbol: "person.crop.square.filled.and.at.rectangle"),
        VoiceShortcutSuggestion(trigger: "shortcut website", detail: "Personal website", symbol: "globe"),
        VoiceShortcutSuggestion(trigger: "shortcut portfolio", detail: "Portfolio or project page", symbol: "briefcase"),
        VoiceShortcutSuggestion(trigger: "shortcut signature", detail: "Email signature", symbol: "signature"),
        VoiceShortcutSuggestion(trigger: "shortcut email", detail: "Reusable email reply", symbol: "envelope"),
        VoiceShortcutSuggestion(trigger: "shortcut address", detail: "Mailing or office address", symbol: "mappin.and.ellipse"),
        VoiceShortcutSuggestion(trigger: "shortcut bio", detail: "Developer bio or profile", symbol: "person.text.rectangle")
    ]
}

struct NormalizedVoiceTrigger: Hashable {
    let tokens: [String]

    var key: String {
        tokens.joined(separator: "\u{1F}")
    }
}

struct VoiceTriggerToken {
    let value: String
    let range: Range<String.Index>
}

enum VoiceShortcutValidationError: Error, Equatable {
    case emptyTrigger
    case emptyReplacement
    case duplicateTrigger
}

enum VoiceShortcutValidation {
    static func tokenized(_ text: String) -> [VoiceTriggerToken] {
        var tokens: [VoiceTriggerToken] = []
        var tokenStart: String.Index?

        func flush(through end: String.Index) {
            guard let tokenStart else { return }
            let raw = String(text[tokenStart..<end])
            let value = raw
                .precomposedStringWithCompatibilityMapping
                .lowercased()
            if !value.isEmpty {
                tokens.append(VoiceTriggerToken(value: value, range: tokenStart..<end))
            }
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if tokenStart == nil { tokenStart = index }
            } else if tokenStart != nil {
                flush(through: index)
                tokenStart = nil
            }
            index = text.index(after: index)
        }
        flush(through: text.endIndex)
        return tokens
    }

    static func normalizedTrigger(_ text: String) -> NormalizedVoiceTrigger {
        NormalizedVoiceTrigger(tokens: tokenized(text).map(\.value))
    }

    static func validate(
        _ shortcut: VoiceShortcut,
        against existing: [VoiceShortcut],
        excluding excludedID: UUID? = nil
    ) throws {
        let normalized = normalizedTrigger(shortcut.trigger)
        guard !normalized.tokens.isEmpty else {
            throw VoiceShortcutValidationError.emptyTrigger
        }
        guard shortcut.replacement.contains(where: { !$0.isWhitespace }) else {
            throw VoiceShortcutValidationError.emptyReplacement
        }

        let duplicate = existing.contains { other in
            guard other.id != excludedID else { return false }
            return normalizedTrigger(other.trigger) == normalized
        }
        guard !duplicate else {
            throw VoiceShortcutValidationError.duplicateTrigger
        }
    }
}
