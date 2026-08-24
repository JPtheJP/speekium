import XCTest
@testable import WhisprStream

@MainActor
final class TriggerShortcutSettingsTests: XCTestCase {
    func testNewDefaultsUseAndPersistRightOption() throws {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.triggerShortcut, .modifierOnly(.rightOption))
        let data = try XCTUnwrap(defaults.data(forKey: "triggerShortcut.v1"))
        XCTAssertEqual(
            try JSONDecoder().decode(TriggerShortcut.self, from: data),
            .modifierOnly(.rightOption)
        )
    }

    func testLegacyModifierMigratesToVersionedShortcut() {
        let defaults = makeDefaults()
        defaults.set(TriggerKey.leftOption.rawValue, forKey: "triggerKey")

        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.triggerShortcut, .modifierOnly(.leftOption))
        XCTAssertNotNil(defaults.data(forKey: "triggerShortcut.v1"))
    }

    func testValidVersionedShortcutTakesPrecedenceOverLegacyValue() {
        let defaults = makeDefaults()
        let custom = TriggerShortcut(
            keyCode: 41,
            modifiers: [.option],
            key: .printable(fallbackLabel: ";")
        )
        defaults.set(TriggerKey.leftOption.rawValue, forKey: "triggerKey")
        defaults.set(try! JSONEncoder().encode(custom), forKey: "triggerShortcut.v1")

        XCTAssertEqual(Settings(defaults: defaults).triggerShortcut, custom)
    }

    func testCustomChordAndFunctionKeySurviveReload() {
        let defaults = makeDefaults()
        let chord = TriggerShortcut(
            keyCode: 41,
            modifiers: [.control, .option, .shift],
            key: .printable(fallbackLabel: ";")
        )
        Settings(defaults: defaults).triggerShortcut = chord
        XCTAssertEqual(Settings(defaults: defaults).triggerShortcut, chord)

        let f13 = TriggerShortcut(
            keyCode: 105,
            modifiers: [],
            key: .function(number: 13)
        )
        Settings(defaults: defaults).triggerShortcut = f13
        XCTAssertEqual(Settings(defaults: defaults).triggerShortcut, f13)
    }

    func testCorruptVersionedShortcutFallsBackToValidLegacyShortcut() {
        let defaults = makeDefaults()
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "triggerShortcut.v1")
        defaults.set(TriggerKey.rightControl.rawValue, forKey: "triggerKey")

        XCTAssertEqual(
            Settings(defaults: defaults).triggerShortcut,
            .modifierOnly(.rightControl)
        )
    }

    func testCorruptVersionedAndLegacyShortcutsUseDefault() {
        let defaults = makeDefaults()
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "triggerShortcut.v1")
        defaults.set("not-a-trigger", forKey: "triggerKey")

        XCTAssertEqual(
            Settings(defaults: defaults).triggerShortcut,
            .modifierOnly(.rightOption)
        )
    }

    func testResetPersistsDefaultAndNoOpDoesNotNotify() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        var notifications = 0
        settings.onHotKeyConfigurationChange = { notifications += 1 }

        settings.triggerShortcut = settings.triggerShortcut
        XCTAssertEqual(notifications, 0)

        settings.triggerShortcut = TriggerShortcut(
            keyCode: 41,
            modifiers: [.option],
            key: .printable(fallbackLabel: ";")
        )
        XCTAssertEqual(notifications, 1)

        settings.resetTriggerShortcut()
        XCTAssertEqual(settings.triggerShortcut, .defaultValue)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(
            Settings(defaults: defaults).triggerShortcut,
            .defaultValue
        )
    }

    func testActivationModePersistsAlongsideShortcut() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        settings.activationMode = .tap
        settings.triggerShortcut = TriggerShortcut(
            keyCode: 105,
            modifiers: [],
            key: .function(number: 13)
        )

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.activationMode, .tap)
        XCTAssertEqual(
            reloaded.triggerShortcut,
            TriggerShortcut(
                keyCode: 105,
                modifiers: [],
                key: .function(number: 13)
            )
        )
    }

    func testNoOpActivationModeDoesNotNotify() {
        let settings = Settings(defaults: makeDefaults())
        var notifications = 0
        settings.onHotKeyConfigurationChange = { notifications += 1 }

        settings.activationMode = settings.activationMode

        XCTAssertEqual(notifications, 0)
    }

    func testCaptureStateIsTransientAndReferenceCounted() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        var transitions: [Bool] = []
        settings.onTriggerShortcutCaptureChange = { (_: Bool) in
            transitions.append(settings.isCapturingTriggerShortcut)
        }

        settings.beginTriggerShortcutCapture()
        settings.beginTriggerShortcutCapture()
        XCTAssertTrue(settings.isCapturingTriggerShortcut)

        settings.endTriggerShortcutCapture()
        XCTAssertTrue(settings.isCapturingTriggerShortcut)
        settings.endTriggerShortcutCapture()
        XCTAssertFalse(settings.isCapturingTriggerShortcut)
        settings.endTriggerShortcutCapture()
        XCTAssertEqual(transitions, [true, false])
        XCTAssertFalse(Settings(defaults: defaults).isCapturingTriggerShortcut)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WhisprStreamTriggerShortcutTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}
