import Foundation

struct TranscriptExpansionResult: Equatable {
    let text: String
    let matchedShortcutID: UUID?

    var didExpand: Bool { matchedShortcutID != nil }
}

enum TranscriptExpander {
    static func expand(
        _ transcript: String,
        using shortcuts: [VoiceShortcut]
    ) -> TranscriptExpansionResult {
        let transcriptTokens = VoiceShortcutValidation.tokenized(transcript)
        guard !transcriptTokens.isEmpty else {
            return TranscriptExpansionResult(text: transcript, matchedShortcutID: nil)
        }

        struct Candidate {
            let shortcut: VoiceShortcut
            let tokens: [String]
        }

        var seenKeys = Set<String>()
        let candidates = shortcuts.compactMap { shortcut -> Candidate? in
            guard shortcut.isEnabled else { return nil }
            let normalized = VoiceShortcutValidation.normalizedTrigger(shortcut.trigger)
            guard !normalized.tokens.isEmpty else { return nil }
            guard seenKeys.insert(normalized.key).inserted else {
                Log.write("voice shortcut duplicate normalized trigger; first match wins")
                return nil
            }
            return Candidate(shortcut: shortcut, tokens: normalized.tokens)
        }
        // Prefer phrases over single-word triggers when both could match at the
        // same position (for example, "blue" and "blue pineapple").
        let ordered = candidates.sorted { $0.tokens.count > $1.tokens.count }

        struct Replacement {
            let range: Range<String.Index>
            let text: String
            let shortcutID: UUID
            let tokenCount: Int
        }

        var replacements: [Replacement] = []
        var tokenIndex = 0
        var firstMatchedID: UUID?
        while tokenIndex < transcriptTokens.count {
            guard let match = ordered.first(where: { candidate in
                let end = tokenIndex + candidate.tokens.count
                guard end <= transcriptTokens.count else { return false }
                return zip(candidate.tokens, transcriptTokens[tokenIndex..<end])
                    .allSatisfy { $0 == $1.value }
            }) else {
                tokenIndex += 1
                continue
            }

            let lastTokenIndex = tokenIndex + match.tokens.count - 1
            let firstToken = transcriptTokens[tokenIndex]
            let lastToken = transcriptTokens[lastTokenIndex]
            replacements.append(Replacement(
                range: firstToken.range.lowerBound..<lastToken.range.upperBound,
                text: match.shortcut.replacement,
                shortcutID: match.shortcut.id,
                tokenCount: match.tokens.count
            ))
            firstMatchedID = firstMatchedID ?? match.shortcut.id
            tokenIndex = lastTokenIndex + 1
        }

        guard !replacements.isEmpty else {
            return TranscriptExpansionResult(text: transcript, matchedShortcutID: nil)
        }

        // If the trigger is the complete utterance, remove ASR-added terminal
        // punctuation and whitespace along with it. This keeps a spoken
        // "Haha, GitHub." from becoming a URL followed by a stray period.
        if replacements.count == 1,
           transcriptTokens.count == replacements[0].tokenCount {
            return TranscriptExpansionResult(
                text: replacements[0].text,
                matchedShortcutID: firstMatchedID
            )
        }

        var output = transcript
        for replacement in replacements.reversed() {
            output.replaceSubrange(replacement.range, with: replacement.text)
        }
        return TranscriptExpansionResult(text: output, matchedShortcutID: firstMatchedID)
    }
}
