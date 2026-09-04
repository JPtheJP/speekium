import Carbon.HIToolbox
import Foundation
import NaturalLanguage

/// Chooses a low-latency language hint for a completed clip too short (≤2 s)
/// for the speech model to detect its language reliably.
///
/// Fixed preferences remain deterministic. Smart (automatic) detects the
/// language of the text near the cursor and otherwise leaves the model in
/// automatic multilingual mode, so a short clip is never forced into the wrong
/// language. Smart English + Chinese keeps its original bilingual heuristic.
enum ShortUtteranceLanguageResolver {
    static func modelLanguage(
        for preference: ShortUtteranceLanguage,
        precedingText: String?,
        inputSourceLanguages: [String]? = nil
    ) -> String? {
        if let fixed = preference.fixedModelLanguage { return fixed }

        switch preference {
        case .smartAutomatic:
            // The text being written is the only trustworthy signal. A keyboard
            // layout says nothing about which language a multilingual speaker is
            // about to use, so it is deliberately not used to force a choice.
            return dominantSupportedLanguage(in: precedingText)
        default:
            return englishOrChinese(
                precedingText: precedingText,
                inputSourceLanguages: inputSourceLanguages
            )
        }
    }

    /// Detects the dominant language of nearby text, restricted to the languages
    /// the model can be steered to. Returns nil when the text is empty, too
    /// short, or ambiguous, which leaves the model in automatic mode.
    static func dominantSupportedLanguage(
        in text: String?,
        minimumConfidence: Double = 0.5
    ) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = SupportedLanguage.recognizerLanguages
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 5)[dominant] ?? 0
        guard confidence >= minimumConfidence else { return nil }
        return SupportedLanguage.modelName(forLanguageCode: dominant.rawValue)
    }

    // MARK: - Smart English + Chinese (original bilingual heuristic)

    private static func englishOrChinese(
        precedingText: String?,
        inputSourceLanguages: [String]?
    ) -> String? {
        if let textLanguage = languageNearCursor(in: precedingText) {
            return textLanguage
        }

        let languages = inputSourceLanguages ?? currentInputSourceLanguages()
        for identifier in languages.map({ $0.lowercased() }) {
            if identifier == "zh" || identifier.hasPrefix("zh-") || identifier == "yue" {
                return "Chinese"
            }
            if identifier == "en" || identifier.hasPrefix("en-") {
                return "English"
            }
        }

        // With no trustworthy context, leave Qwen in automatic multilingual
        // mode instead of silently imposing either half of the bilingual pair.
        return nil
    }

    private static func languageNearCursor(in text: String?) -> String? {
        guard let text else { return nil }
        for scalar in text.unicodeScalars.reversed() {
            if isHan(scalar.value) { return "Chinese" }
            if isLatin(scalar.value) { return "English" }
        }
        return nil
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x3134F).contains(value)
    }

    private static func isLatin(_ value: UInt32) -> Bool {
        (0x0041...0x005A).contains(value)
            || (0x0061...0x007A).contains(value)
            || (0x00C0...0x024F).contains(value)
            || (0x1E00...0x1EFF).contains(value)
    }

    private static func currentInputSourceLanguages() -> [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(
                source,
                kTISPropertyInputSourceLanguages
              ) else { return [] }
        let values = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return values as? [String] ?? []
    }
}

/// Maps BCP-47-style language codes (from NaturalLanguage or a keyboard input
/// source) to the language names Qwen3-ASR accepts as a forced hint. Mirrors
/// `SUPPORTED_SHORT_UTTERANCE_LANGUAGES` in `asr_server.py`.
enum SupportedLanguage {
    static let modelNamesByPrimaryCode: [String: String] = [
        "zh": "Chinese", "yue": "Cantonese", "en": "English", "ar": "Arabic",
        "de": "German", "fr": "French", "es": "Spanish", "pt": "Portuguese",
        "id": "Indonesian", "it": "Italian", "ko": "Korean", "ru": "Russian",
        "th": "Thai", "vi": "Vietnamese", "ja": "Japanese", "tr": "Turkish",
        "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech",
        "tl": "Filipino", "fa": "Persian", "el": "Greek", "hu": "Hungarian",
        "mk": "Macedonian", "ro": "Romanian",
    ]

    /// `"fr-CA"` → `"French"`, `"zh-Hans"` → `"Chinese"`, `"pt_BR"` → `"Portuguese"`.
    static func modelName(forLanguageCode code: String) -> String? {
        let primary = code.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init) ?? ""
        return modelNamesByPrimaryCode[primary]
    }

    /// Candidate set for the recognizer: only languages we can actually force,
    /// which keeps detection from wandering to unsupported look-alikes.
    static let recognizerLanguages: [NLLanguage] = [
        "en", "fr", "es", "de", "it", "pt", "nl", "sv", "da", "fi", "pl", "cs",
        "ru", "tr", "ar", "hi", "ja", "ko", "th", "vi", "id", "ms", "el", "hu",
        "ro", "fa", "mk", "tl", "zh-Hans", "zh-Hant",
    ].map(NLLanguage.init(rawValue:))
}
