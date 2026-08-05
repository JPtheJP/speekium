import XCTest
@testable import WhisprStream

final class TranscriptExpanderTests: XCTestCase {
    func testPunctuationCanBeReplacedWithSpace() {
        XCTAssertEqual(
            TranscriptFormatter.format("Hello, world!", usePunctuation: false),
            "Hello, world "
        )
        XCTAssertEqual(
            TranscriptFormatter.format("你好。", usePunctuation: false),
            "你好 "
        )
    }

    func testPunctuationPreferencePreservesTextWhenEnabled() {
        XCTAssertEqual(
            TranscriptFormatter.format("Hello, world!", usePunctuation: true),
            "Hello, world!"
        )
    }

    func testPunctuationFormatterPreservesInternalPunctuation() {
        XCTAssertEqual(
            TranscriptFormatter.format("Use example.com now.", usePunctuation: false),
            "Use example.com now "
        )
    }

    func testSpokenNumbersBecomeDigits() {
        XCTAssertEqual(SpokenNumberNormalizer.normalize("I need twenty four apples"), "I need 24 apples")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one hundred and five"), "105")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("the code is one two three"), "the code is 123")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("the code is zero one"), "the code is 01")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("twenty-four"), "24")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("temperature is twenty point five degrees"), "temperature is 20.5 degrees")
    }

    func testSpokenNumbersPreserveUnrelatedTextAndPunctuation() {
        XCTAssertEqual(
            SpokenNumberNormalizer.normalize("Please call 416-555-0100. I won one."),
            "Please call 416-555-0100. I won 1."
        )
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one and two"), "one and two")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one hundred."), "100.")
    }

    func testSpokenSlashBecomesPathPunctuation() {
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash retest"), "/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash retest."), "/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash retest.com."), "/retest.com")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("forward slash retest"), "/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("docs slash retest"), "docs/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("run slash retest."), "run/retest.")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash slash retest"), "//retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash the budget"), "slash the budget")
    }

    func testNormalizationIgnoresCasePunctuationAndWhitespace() {
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("haha github"),
            VoiceShortcutValidation.normalizedTrigger("HAHA,   GITHUB!")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("pineapple"),
            VoiceShortcutValidation.normalizedTrigger("PINEAPPLE!")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("pineapple"),
            VoiceShortcutValidation.normalizedTrigger("ｐｉｎｅａｐｐｌｅ")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("hello world"),
            VoiceShortcutValidation.normalizedTrigger("hello\nworld")
        )
        XCTAssertNotEqual(
            VoiceShortcutValidation.normalizedTrigger("hello-world"),
            VoiceShortcutValidation.normalizedTrigger("helloworld")
        )
    }

    func testNormalizationKeepsTokenAndDiacriticDifferences() {
        XCTAssertNotEqual(
            VoiceShortcutValidation.normalizedTrigger("haha"),
            VoiceShortcutValidation.normalizedTrigger("ha ha")
        )
        XCTAssertNotEqual(
            VoiceShortcutValidation.normalizedTrigger("resume"),
            VoiceShortcutValidation.normalizedTrigger("résumé")
        )
    }

    func testChineseAndMixedLanguageNormalization() {
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("你好。"),
            VoiceShortcutValidation.normalizedTrigger("你好")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("你好 GitHub"),
            VoiceShortcutValidation.normalizedTrigger("你好, GITHUB!")
        )
    }

    func testPunctuationOnlyTriggerIsInvalid() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "!?", replacement: "text", isEnabled: true)
        XCTAssertThrowsError(try VoiceShortcutValidation.validate(shortcut, against: [])) { error in
            XCTAssertEqual(error as? VoiceShortcutValidationError, .emptyTrigger)
        }
    }

    func testEnabledSingleWordAndPhraseExpand() {
        let single = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "🍍", isEnabled: true)
        let phrase = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "https://github.com/Leo6Leo", isEnabled: true)

        XCTAssertEqual(TranscriptExpander.expand("Pineapple!", using: [single]).text, "🍍")
        XCTAssertEqual(
            TranscriptExpander.expand("Haha, GitHub.", using: [phrase]),
            TranscriptExpansionResult(text: "https://github.com/Leo6Leo", matchedShortcutID: phrase.id)
        )
    }

    func testDisabledTriggerDoesNotExpandAndInlineTriggerDoesExpand() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "expanded", isEnabled: false)
        XCTAssertEqual(TranscriptExpander.expand("pineapple", using: [shortcut]).text, "pineapple")

        let enabled = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(
            TranscriptExpander.expand("Open haha github", using: [enabled]).text,
            "Open expanded"
        )
        XCTAssertEqual(
            TranscriptExpander.expand("Please use Haha, GitHub.", using: [enabled]).text,
            "Please use expanded."
        )
    }

    func testNearMatchAndNoMatchReturnOriginalTextExactly() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(TranscriptExpander.expand("ha ha github", using: [shortcut]).text, "ha ha github")
        let original = "  Unmatched\ntext  "
        XCTAssertEqual(TranscriptExpander.expand(original, using: [shortcut]).text, original)
    }

    func testReplacementIsLiteralAndNotRecursive() {
        let first = VoiceShortcut(id: UUID(), trigger: "alpha", replacement: "beta\nγamma", isEnabled: true)
        let second = VoiceShortcut(id: UUID(), trigger: "beta", replacement: "recursive", isEnabled: true)
        let result = TranscriptExpander.expand("ALPHA!", using: [first, second])
        XCTAssertEqual(result.text, "beta\nγamma")
        XCTAssertEqual(result.matchedShortcutID, first.id)
    }

    func testLongerPhraseWinsOverSingleWordAndMultipleMatchesExpand() {
        let single = VoiceShortcut(id: UUID(), trigger: "blue", replacement: "BLUE", isEnabled: true)
        let phrase = VoiceShortcut(id: UUID(), trigger: "blue pineapple", replacement: "FRUIT", isEnabled: true)
        XCTAssertEqual(
            TranscriptExpander.expand("blue pineapple and blue", using: [single, phrase]).text,
            "FRUIT and BLUE"
        )
    }

    func testSingleWordDoesNotMatchInsideLongerToken() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(
            TranscriptExpander.expand("pineapples are ready", using: [shortcut]).text,
            "pineapples are ready"
        )
    }

    func testFullWidthTranscriptCanBeExpandedWithoutInvalidStringIndices() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(TranscriptExpander.expand("ｐｉｎｅａｐｐｌｅ！", using: [shortcut]).text, "expanded")
    }

    func testDuplicateNormalizedTriggersUseFirstShortcut() {
        let first = VoiceShortcut(id: UUID(), trigger: "hello", replacement: "first", isEnabled: true)
        let second = VoiceShortcut(id: UUID(), trigger: "HELLO!", replacement: "second", isEnabled: true)
        XCTAssertEqual(TranscriptExpander.expand("hello", using: [first, second]).text, "first")
    }

    func testDuplicateNormalizedTriggersAreRejected() {
        let existing = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "one", isEnabled: false)
        let candidate = VoiceShortcut(id: UUID(), trigger: "HAHA, GITHUB!", replacement: "two", isEnabled: true)
        XCTAssertThrowsError(try VoiceShortcutValidation.validate(candidate, against: [existing])) { error in
            XCTAssertEqual(error as? VoiceShortcutValidationError, .duplicateTrigger)
        }
    }
}
