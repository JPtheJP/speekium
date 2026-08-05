import Foundation

/// Converts English number words in a finished transcript to digits.
///
/// This is deliberately a post-processing step rather than ASR prompt context:
/// context can bias the model, but it cannot guarantee that "twenty four" is
/// inserted as `24`. Only whitespace- or hyphen-separated number phrases are
/// considered, so ordinary words and punctuation are left alone.
enum SpokenNumberNormalizer {
    private enum Word {
        case digit(Int)
        case teen(Int)
        case tens(Int)
        case scale(Int64)
        case point
        case and
        case minus

        var isDigit: Bool {
            if case .digit = self { return true }
            return false
        }
    }

    private struct Token {
        let range: Range<String.Index>
        let word: Word?
    }

    private static let words: [String: Word] = [
        "zero": .digit(0), "oh": .digit(0),
        "one": .digit(1), "two": .digit(2), "three": .digit(3),
        "four": .digit(4), "five": .digit(5), "six": .digit(6),
        "seven": .digit(7), "eight": .digit(8), "nine": .digit(9),
        "ten": .teen(10), "eleven": .teen(11), "twelve": .teen(12),
        "thirteen": .teen(13), "fourteen": .teen(14), "fifteen": .teen(15),
        "sixteen": .teen(16), "seventeen": .teen(17), "eighteen": .teen(18),
        "nineteen": .teen(19),
        "twenty": .tens(20), "thirty": .tens(30), "forty": .tens(40),
        "fifty": .tens(50), "sixty": .tens(60), "seventy": .tens(70),
        "eighty": .tens(80), "ninety": .tens(90),
        "hundred": .scale(100), "thousand": .scale(1_000),
        "million": .scale(1_000_000), "billion": .scale(1_000_000_000),
        "trillion": .scale(1_000_000_000_000),
        "point": .point, "and": .and, "minus": .minus, "negative": .minus
    ]

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        var start = 0

        while start < tokens.count {
            guard tokens[start].word != nil else {
                start += 1
                continue
            }

            var end = start + 1
            while end < tokens.count,
                  tokens[end].word != nil,
                  separatedByWhitespaceOrHyphen(tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound,
                                                in: text) {
                end += 1
            }

            let words = tokens[start..<end].compactMap(\.word)
            if let number = parse(words) {
                replacements.append((
                    tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound,
                    number
                ))
            }
            start = end
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index].isLetter else {
                index = text.index(after: index)
                continue
            }

            let begin = index
            repeat {
                index = text.index(after: index)
            } while index < text.endIndex && text[index].isLetter

            let range = begin..<index
            let value = String(text[range]).lowercased()
            result.append(Token(range: range, word: words[value]))
        }
        return result
    }

    private static func separatedByWhitespaceOrHyphen(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        text[range].allSatisfy { $0.isWhitespace || $0 == "-" }
    }

    private static func parse(_ words: [Word]) -> String? {
        guard !words.isEmpty else { return nil }

        var words = words
        var negative = false
        if case .minus = words.first {
            negative = true
            words.removeFirst()
        }
        guard !words.isEmpty, !words.contains(where: { if case .minus = $0 { return true }; return false }) else {
            return nil
        }

        let pointIndices = words.indices.filter {
            if case .point = words[$0] { return true }
            return false
        }
        guard pointIndices.count <= 1 else { return nil }

        let integerWords: ArraySlice<Word>
        let fractionWords: ArraySlice<Word>
        if let point = pointIndices.first {
            guard point > words.startIndex, point + 1 < words.endIndex else { return nil }
            integerWords = words[..<point]
            fractionWords = words[(point + 1)...]
            guard fractionWords.allSatisfy(\.isDigit) else { return nil }
        } else {
            integerWords = words[...]
            fractionWords = []
        }

        guard let integer = parseInteger(Array(integerWords)) else { return nil }
        var output = (negative ? "-" : "") + integer
        if !fractionWords.isEmpty {
            output += "." + fractionWords.compactMap { word in
                guard case let .digit(value) = word else { return nil }
                return String(value)
            }.joined()
        }
        return output
    }

    private static func parseInteger(_ words: [Word]) -> String? {
        guard !words.isEmpty else { return nil }

        // A run of digit words is how people normally dictate identifiers,
        // phone numbers, and years: "one two three" -> 123.
        if words.allSatisfy(\.isDigit) {
            let digits = words.compactMap { word -> String? in
                guard case let .digit(value) = word else { return nil }
                return String(value)
            }.joined()
            return digits
        }

        var total: Int64 = 0
        var current: Int64 = 0
        var sawNumber = false
        var previousWasScale = false

        for (index, word) in words.enumerated() {
            switch word {
            case let .digit(value), let .teen(value), let .tens(value):
                current += Int64(value)
                sawNumber = true
                previousWasScale = false

            case let .scale(scale):
                guard sawNumber else { return nil }
                guard scale != 100 || !previousWasScale else { return nil }
                if scale == 100 {
                    current = max(current, 1)
                    guard current <= Int64.max / scale else { return nil }
                    current *= scale
                } else {
                    let group = max(current, 1)
                    guard group <= Int64.max / scale else { return nil }
                    let contribution = group * scale
                    guard total <= Int64.max - contribution else { return nil }
                    total += contribution
                    current = 0
                }
                previousWasScale = true

            case .and:
                // "and" is accepted only after a scale: "one hundred and
                // five". This avoids turning list-like speech such as
                // "one and two" into the number 12.
                guard previousWasScale,
                      index + 1 < words.count,
                      !isScale(words[index + 1]) else { return nil }

            case .point, .minus:
                return nil
            }
        }

        guard sawNumber else { return nil }
        guard total <= Int64.max - current else { return nil }
        return String(total + current)
    }

    private static func isScale(_ word: Word) -> Bool {
        if case .scale = word { return true }
        return false
    }
}
