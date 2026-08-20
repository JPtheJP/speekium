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

    /// Removes sentence-style capitalization when dictation continues text
    /// immediately before the cursor. Unknown cursor context is deliberately a
    /// no-op, as are sentence boundaries, the pronoun "I", and acronyms.
    static func adjustedForCursor(_ text: String, precedingText: String?) -> String {
        guard !text.isEmpty,
              let precedingText,
              isContinuation(precedingText),
              let firstLetter = text.firstIndex(where: \.isLetter)
        else { return text }

        let word = text[firstLetter...].prefix {
            $0.isLetter || $0 == "'" || $0 == "’"
        }
        let wordText = String(word)
        let straightWord = wordText.replacingOccurrences(of: "’", with: "'")
        if straightWord == "I" || straightWord.hasPrefix("I'") || isAcronym(wordText) {
            return text
        }

        let letter = text[firstLetter]
        let lowered = String(letter).lowercased()
        guard lowered != String(letter) else { return text }

        var result = text
        result.replaceSubrange(firstLetter...firstLetter, with: lowered)
        return result
    }

    private static func isContinuation(_ precedingText: String) -> Bool {
        var end = precedingText.endIndex

        while end > precedingText.startIndex {
            let previous = precedingText.index(before: end)
            let character = precedingText[previous]
            guard character.isWhitespace else { break }
            if character == "\n" || character == "\r" { return false }
            end = previous
        }

        while end > precedingText.startIndex {
            let previous = precedingText.index(before: end)
            guard closingCharacters.contains(precedingText[previous]) else { break }
            end = previous
        }

        guard end > precedingText.startIndex else { return false }
        let character = precedingText[precedingText.index(before: end)]
        if sentenceTerminators.contains(character) { return false }
        if character.isLetter || character.isNumber { return true }
        return continuationPunctuation.contains(character)
    }

    private static func isAcronym(_ word: String) -> Bool {
        let casedLetters = word.filter {
            $0.isLetter && String($0).lowercased() != String($0).uppercased()
        }
        guard casedLetters.count >= 2 else { return false }
        return casedLetters.allSatisfy { String($0) == String($0).uppercased() }
    }

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？"
    ]

    private static let closingCharacters: Set<Character> = [
        "\"", "'", "”", "’", "»", "›", "」", "』", "】",
        ")", "]", "}", "）", "］", "｝"
    ]

    private static let continuationPunctuation: Set<Character> = [
        ",", ";", ":", "-", "–", "—", "/", "=", "+", "&",
        "，", "；", "：", "、"
    ]
}
