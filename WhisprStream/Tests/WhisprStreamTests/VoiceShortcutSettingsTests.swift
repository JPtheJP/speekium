import XCTest
@testable import WhisprStream

@MainActor
final class VoiceShortcutSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "WhisprStreamTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testPersistenceAndCombinedContext() throws {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        settings.usePunctuation = false
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
        XCTAssertEqual(reloaded.voiceShortcuts, [enabled, disabled])
        XCTAssertEqual(reloaded.asrContext, "Claude\nGitHub\nhaha github")
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
