import XCTest
@testable import Speekium

@MainActor
final class VoiceShortcutSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "SpeekiumTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testPersistenceAndCombinedContext() throws {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        settings.usePunctuation = false
        settings.contextAwareCapitalization = false
        settings.shortUtteranceLanguage = .english
        settings.setVocabulary(["Claude", "GitHub"])

        let enabled = VoiceShortcut(
            id: UUID(), trigger: "haha github", replacement: "https://example.com", isEnabled: true
        )
        let disabled = VoiceShortcut(
            id: UUID(), trigger: "secret phrase", replacement: "hidden", isEnabled: false
        )
        try settings.addVoiceShortcut(enabled)
        try settings.addVoiceShortcut(disabled)

        XCTAssertEqual(settings.asrContext, "Claude\nGitHub\nhaha github")

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.usePunctuation)
        XCTAssertFalse(reloaded.contextAwareCapitalization)
        XCTAssertEqual(reloaded.shortUtteranceLanguage, .english)
        XCTAssertEqual(reloaded.voiceShortcuts, [enabled, disabled])
        XCTAssertEqual(reloaded.asrContext, "Claude\nGitHub\nhaha github")
    }

    func testContextAwareCapitalizationDefaultsOn() {
        XCTAssertTrue(Settings(defaults: makeDefaults()).contextAwareCapitalization)
    }

    func testOneWordDictationOffersEveryQwenLanguageWithoutAutomatic() {
        let fixedLanguages = ShortUtteranceLanguage.allCases.compactMap(\.fixedModelLanguage)

        XCTAssertEqual(ShortUtteranceLanguage.allCases.count, 31)
        XCTAssertEqual(Set(fixedLanguages).count, 30)
        XCTAssertFalse(ShortUtteranceLanguage.allCases.map(\.modelName).contains("Automatic"))
    }

    func testOneWordDictationDefaultsToSmartEnglishAndChinese() {
        XCTAssertEqual(
            Settings(defaults: makeDefaults()).shortUtteranceLanguage,
            .smartEnglishChinese
        )
    }

    func testSmartOneWordLanguageUsesNearestCursorScript() {
        XCTAssertEqual(
            ShortUtteranceLanguageResolver.modelLanguage(
                for: .smartEnglishChinese,
                precedingText: "Please enter 你好：",
                inputSourceLanguages: ["en"]
            ),
            "Chinese"
        )
        XCTAssertEqual(
            ShortUtteranceLanguageResolver.modelLanguage(
                for: .smartEnglishChinese,
                precedingText: "这是 a test: ",
                inputSourceLanguages: ["zh-Hans"]
            ),
            "English"
        )
    }

    func testSmartOneWordLanguageFallsBackToKeyboardThenAutomatic() {
        XCTAssertEqual(
            ShortUtteranceLanguageResolver.modelLanguage(
                for: .smartEnglishChinese,
                precedingText: nil,
                inputSourceLanguages: ["zh-Hans"]
            ),
            "Chinese"
        )
        XCTAssertNil(
            ShortUtteranceLanguageResolver.modelLanguage(
                for: .smartEnglishChinese,
                precedingText: nil,
                inputSourceLanguages: ["ja"]
            )
        )
        XCTAssertEqual(
            ShortUtteranceLanguageResolver.modelLanguage(
                for: .french,
                precedingText: "中文",
                inputSourceLanguages: ["zh-Hans"]
            ),
            "French"
        )
    }

    func testOneWordLanguageOnboardingFollowsSpeakingPreferences() throws {
        let steps = OnboardingView.Step.allCases
        let preferencesIndex = try XCTUnwrap(steps.firstIndex(of: .preferences))

        XCTAssertEqual(steps[preferencesIndex + 1], .oneWordLanguage)
    }

    func testFirstDictationCoachUsesSelectedKeyAndActivationMode() {
        XCTAssertEqual(
            FirstDictationCoachView.instruction(key: .rightOption, mode: .hold),
            "Click in any text field, then hold ⌥ Right Option, speak, and release."
        )
        XCTAssertEqual(
            FirstDictationCoachView.instruction(key: .function, mode: .tap),
            "Click in any text field, tap Fn, speak, then tap it again."
        )
    }

    func testDeveloperFirstRunSimulationOffersFirstDictationCoach() {
        XCTAssertTrue(FirstDictationCoachPolicy.shouldOffer(
            hasCompletedOnboarding: true,
            isDeveloperFirstRunSimulation: true
        ))
        XCTAssertTrue(FirstDictationCoachPolicy.shouldOffer(
            hasCompletedOnboarding: false,
            isDeveloperFirstRunSimulation: false
        ))
        XCTAssertFalse(FirstDictationCoachPolicy.shouldOffer(
            hasCompletedOnboarding: true,
            isDeveloperFirstRunSimulation: false
        ))
    }

    func testLegacyAutomaticShortLanguageMigratesToSmartBilingual() {
        let defaults = makeDefaults()
        defaults.set("automatic", forKey: "shortUtteranceLanguage")

        XCTAssertEqual(Settings(defaults: defaults).shortUtteranceLanguage, .smartEnglishChinese)
    }

    func testContextDeduplicatesIdenticalLiteralLinesAndNeverIncludesReplacement() throws {
        let settings = Settings(defaults: makeDefaults())
        settings.setVocabulary(["hello", "world"])
        let shortcut = VoiceShortcut(
            id: UUID(), trigger: "hello", replacement: "world\nprivate replacement", isEnabled: true
        )
        try settings.addVoiceShortcut(shortcut)

        XCTAssertEqual(settings.asrContext, "hello\nworld")
        XCTAssertFalse(settings.asrContext.contains("private replacement"))
    }

    func testDisabledToggleAndAllShortcutMutationsPushContext() throws {
        let settings = Settings(defaults: makeDefaults())
        var updates: [String] = []
        settings.onContextChange = { updates.append($0) }

        let shortcut = VoiceShortcut(
            id: UUID(), trigger: "pineapple", replacement: "fruit", isEnabled: true
        )
        try settings.addVoiceShortcut(shortcut)
        settings.setVoiceShortcutEnabled(id: shortcut.id, enabled: false)
        settings.setVoiceShortcutEnabled(id: shortcut.id, enabled: true)
        try settings.updateVoiceShortcut(
            VoiceShortcut(id: shortcut.id, trigger: "mango", replacement: "fruit", isEnabled: true)
        )
        settings.removeVoiceShortcut(id: shortcut.id)

        XCTAssertEqual(updates, ["pineapple", "", "pineapple", "mango", ""])
    }

    func testDuplicateDisabledShortcutIsRejected() throws {
        let settings = Settings(defaults: makeDefaults())
        let existing = VoiceShortcut(
            id: UUID(), trigger: "haha github", replacement: "one", isEnabled: false
        )
        try settings.addVoiceShortcut(existing)

        XCTAssertThrowsError(
            try settings.addVoiceShortcut(
                VoiceShortcut(id: UUID(), trigger: "HAHA, GITHUB!", replacement: "two", isEnabled: true)
            )
        ) { error in
            XCTAssertEqual(error as? VoiceShortcutValidationError, .duplicateTrigger)
        }
    }

    func testDecodeFailureStartsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "voiceShortcuts.v1")
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.voiceShortcuts.isEmpty)
    }
}
