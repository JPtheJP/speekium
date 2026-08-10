import Carbon.HIToolbox
import Foundation

/// Chooses a low-latency language hint for a completed one-word clip. Fixed
/// preferences remain deterministic; Smart English + Chinese follows the
/// language nearest the cursor, then the active macOS keyboard input source.
enum ShortUtteranceLanguageResolver {
    static func modelLanguage(
        for preference: ShortUtteranceLanguage,
        precedingText: String?,
        inputSourceLanguages: [String]? = nil
    ) -> String? {
        if let fixed = preference.fixedModelLanguage { return fixed }

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
