import XCTest
@testable import Speekium

final class ShortUtteranceLanguageResolverTests: XCTestCase {

    // MARK: - Smart (automatic): follows the language of nearby text

    func testSmartAutomaticDetectsSpanishNearCursor() {
        let hint = ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartAutomatic,
            precedingText: "Hola, ¿cómo estás? Quiero reservar una mesa para mañana por la noche."
        )
        XCTAssertEqual(hint, "Spanish")
    }

    func testSmartAutomaticDetectsFrenchNearCursor() {
        let hint = ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartAutomatic,
            precedingText: "Bonjour, je voudrais réserver une table pour ce soir, s'il vous plaît."
        )
        XCTAssertEqual(hint, "French")
    }

    func testSmartAutomaticDetectsEnglishNearCursor() {
        let hint = ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartAutomatic,
            precedingText: "The meeting is scheduled for tomorrow morning, please bring the report."
        )
        XCTAssertEqual(hint, "English")
    }

    /// The bug being fixed: a Spanish short clip must never be forced to French
    /// just because the accented letters look "Latin".
    func testSmartAutomaticNeverMapsAccentedLatinToEnglish() {
        let hint = ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartAutomatic,
            precedingText: "¿Dónde está la estación de tren más cercana?"
        )
        XCTAssertNotEqual(hint, "English")
        XCTAssertNotEqual(hint, "French")
    }

    func testSmartAutomaticFallsBackToAutomaticWithoutContext() {
        // Nothing near the cursor → nil → the model detects the language itself.
        XCTAssertNil(ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartAutomatic, precedingText: nil
        ))
        XCTAssertNil(ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartAutomatic, precedingText: "   \n"
        ))
    }

    func testSmartAutomaticIgnoresKeyboardLayout() {
        // A French keyboard must not force French: layout says nothing about
        // which language a multilingual speaker is about to use.
        let hint = ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartAutomatic,
            precedingText: nil,
            inputSourceLanguages: ["fr"]
        )
        XCTAssertNil(hint)
    }

    func testAmbiguousTextFallsBackToAutomatic() {
        // Too little signal to be confident → leave the model in automatic mode.
        XCTAssertNil(ShortUtteranceLanguageResolver.dominantSupportedLanguage(
            in: "ok", minimumConfidence: 0.95
        ))
    }

    // MARK: - Fixed choices stay deterministic

    func testFixedLanguageIsAlwaysReturned() {
        XCTAssertEqual(ShortUtteranceLanguageResolver.modelLanguage(
            for: .french,
            precedingText: "Quiero reservar una mesa para mañana."   // Spanish context ignored
        ), "French")
    }

    // MARK: - Smart English + Chinese keeps its original behavior

    func testSmartEnglishChineseStillMapsHanAndLatin() {
        XCTAssertEqual(ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartEnglishChinese, precedingText: "你好世界"
        ), "Chinese")
        XCTAssertEqual(ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartEnglishChinese, precedingText: "hello world"
        ), "English")
    }

    func testSmartEnglishChineseFallsBackToKeyboardThenNil() {
        XCTAssertEqual(ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartEnglishChinese, precedingText: nil, inputSourceLanguages: ["zh-Hans"]
        ), "Chinese")
        XCTAssertNil(ShortUtteranceLanguageResolver.modelLanguage(
            for: .smartEnglishChinese, precedingText: nil, inputSourceLanguages: ["fr"]
        ))
    }

    // MARK: - Language-code mapping

    func testLanguageCodeMappingHandlesRegionsAndScripts() {
        XCTAssertEqual(SupportedLanguage.modelName(forLanguageCode: "fr-CA"), "French")
        XCTAssertEqual(SupportedLanguage.modelName(forLanguageCode: "es-419"), "Spanish")
        XCTAssertEqual(SupportedLanguage.modelName(forLanguageCode: "zh-Hans"), "Chinese")
        XCTAssertEqual(SupportedLanguage.modelName(forLanguageCode: "pt_BR"), "Portuguese")
        XCTAssertEqual(SupportedLanguage.modelName(forLanguageCode: "EN"), "English")
        XCTAssertNil(SupportedLanguage.modelName(forLanguageCode: "xx"))
    }

    func testEveryMappedNameIsOneTheModelAccepts() {
        // Mirrors SUPPORTED_SHORT_UTTERANCE_LANGUAGES in asr_server.py.
        let accepted: Set<String> = [
            "Chinese", "English", "Cantonese", "Arabic", "German", "French", "Spanish",
            "Portuguese", "Indonesian", "Italian", "Korean", "Russian", "Thai",
            "Vietnamese", "Japanese", "Turkish", "Hindi", "Malay", "Dutch", "Swedish",
            "Danish", "Finnish", "Polish", "Czech", "Filipino", "Persian", "Greek",
            "Hungarian", "Macedonian", "Romanian",
        ]
        for name in SupportedLanguage.modelNamesByPrimaryCode.values {
            XCTAssertTrue(accepted.contains(name), "\(name) is not a name the sidecar accepts")
        }
    }

    // MARK: - Preference plumbing

    func testSmartModesUseCursorContextAndFixedOnesDoNot() {
        XCTAssertTrue(ShortUtteranceLanguage.smartAutomatic.usesCursorContext)
        XCTAssertTrue(ShortUtteranceLanguage.smartEnglishChinese.usesCursorContext)
        XCTAssertFalse(ShortUtteranceLanguage.spanish.usesCursorContext)
        XCTAssertNil(ShortUtteranceLanguage.smartAutomatic.fixedModelLanguage)
        XCTAssertEqual(ShortUtteranceLanguage.spanish.fixedModelLanguage, "Spanish")
    }
}
