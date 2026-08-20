import Foundation

/// Converts spoken punctuation words to their literal symbols in final text.
///
/// ASR vocabulary can make the word after a symbol more reliable, but it does
/// not reliably turn "slash" into `/`. This pass handles that representation
/// after transcription and removes the spaces that would otherwise produce
/// `/ retest`.
enum SpokenSymbolNormalizer {
    private struct Token {
        let word: String
        let range: Range<String.Index>
    }

    private struct Replacement {
        let range: Range<String.Index>
        let text: String
    }

    private static let ordinaryVerbFollowups: Set<String> = [
        "a", "an", "and", "her", "his", "it", "my", "our", "the", "their",
        "them", "this", "that", "to", "up", "your"
    ]

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        var replacements: [Replacement] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let symbol: String
            let tokenStart: String.Index

            if token.word == "forward",
               index + 1 < tokens.count,
               tokens[index + 1].word == "slash",
               separatedOnlyByWhitespace(token.range.upperBound..<tokens[index + 1].range.lowerBound, in: text) {
                symbol = "/"
                tokenStart = token.range.lowerBound
                index += 1
            } else if token.word == "back",
                      index + 1 < tokens.count,
                      tokens[index + 1].word == "slash",
                      separatedOnlyByWhitespace(token.range.upperBound..<tokens[index + 1].range.lowerBound, in: text) {
                symbol = "\\"
                tokenStart = token.range.lowerBound
                index += 1
            } else if token.word == "backslash" {
                symbol = "\\"
                tokenStart = token.range.lowerBound
            } else if token.word == "slash" {
                // Keep common grammatical uses such as "slash the budget"
                // as words. A path-like phrase such as "slash retest" still
                // becomes `/retest`.
                if let next = nextToken(after: index, in: tokens),
                   ordinaryVerbFollowups.contains(next.word) {
                    index += 1
                    continue
                }
                symbol = "/"
                tokenStart = token.range.lowerBound
            } else {
                index += 1
                continue
            }

            let tokenEnd = tokens[index].range.upperBound
            replacements.append(Replacement(range: tokenStart..<tokenEnd, text: symbol))
            index += 1
        }

        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        result = removeWhitespaceAroundSymbols(result)
        return removeStandaloneTrailingPeriod(result)
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter else {
                index = text.index(after: index)
                continue
            }

            let start = index
            repeat {
                index = text.index(after: index)
            } while index < text.endIndex && text[index].isLetter

            let range = start..<index
            result.append(Token(word: String(text[range]).lowercased(), range: range))
        }
        return result
    }

    private static func nextToken(after index: Int, in tokens: [Token]) -> Token? {
        guard index + 1 < tokens.count else { return nil }
        return tokens[index + 1]
    }

    private static func separatedOnlyByWhitespace(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        text[range].allSatisfy(\.isWhitespace)
    }

    private static func removeWhitespaceAroundSymbols(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isWhitespace,
               result.last == "/" || result.last == "\\" {
                continue
            }
            if (character == "/" || character == "\\") {
                while let last = result.last, last.isWhitespace {
                    result.removeLast()
                }
            }
            result.append(character)
        }
        return result
    }

    private static func removeStandaloneTrailingPeriod(_ text: String) -> String {
        var first = text.startIndex
        while first < text.endIndex, text[first].isWhitespace {
            first = text.index(after: first)
        }
        guard first < text.endIndex, text[first] == "/" else { return text }

        var last = text.endIndex
        while last > first, text[text.index(before: last)].isWhitespace {
            last = text.index(before: last)
        }
        guard last > first else { return text }

        let period = text.index(before: last)
        guard text[period] == "." || text[period] == "。",
              !text[first..<period].contains(where: \.isWhitespace) else {
            return text
        }

        var result = text
        result.remove(at: period)
        return result
    }
}
