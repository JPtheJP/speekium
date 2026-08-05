import Foundation

/// Applies the user's sentence-ending punctuation preference to final text.
enum TranscriptFormatter {
    /// Removes punctuation added at the end of a transcript and replaces it
    /// with a single space when punctuation is disabled. Internal punctuation
    /// and explicit punctuation in the middle of a sentence are preserved.
    static func format(_ text: String, usePunctuation: Bool) -> String {
        guard !usePunctuation else { return text }

        var result = text
        while let last = result.last, sentenceTerminators.contains(last) {
            result.removeLast()
        }
        return result + " "
    }

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？"
    ]
}
