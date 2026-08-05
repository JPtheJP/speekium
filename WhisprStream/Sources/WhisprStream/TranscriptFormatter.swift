import Foundation

/// Applies the user's sentence-ending punctuation preference to final text.
enum TranscriptFormatter {
    /// Removes punctuation added at the end of a transcript when punctuation
    /// is disabled. Internal punctuation and closing quotes/brackets are
    /// preserved. Cursor-separating whitespace is added only on the insertion
    /// path so the HUD and retained clipboard stay clean.
    static func format(_ text: String, usePunctuation: Bool) -> String {
        guard !usePunctuation else { return text }

        var result = text
        while result.last?.isWhitespace == true {
            result.removeLast()
        }

        var closingSuffix: [Character] = []
        while let last = result.last, closingCharacters.contains(last) {
            closingSuffix.append(last)
            result.removeLast()
        }
        while let last = result.last, sentenceTerminators.contains(last) {
            result.removeLast()
        }
        result.append(contentsOf: closingSuffix.reversed())
        return result
    }

    /// Text pasted at the cursor always ends at a word boundary so consecutive
    /// dictations cannot become `Hello.World`. This synthetic separator is not
    /// used for clipboard-only output.
    static func textForInsertion(_ text: String) -> String {
        guard !text.isEmpty, text.last?.isWhitespace != true else { return text }
        return text + " "
    }

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？"
    ]

    private static let closingCharacters: Set<Character> = [
        "\"", "'", "”", "’", "»", "›", "」", "』", "】",
        ")", "]", "}", "）", "］", "｝"
    ]
}
