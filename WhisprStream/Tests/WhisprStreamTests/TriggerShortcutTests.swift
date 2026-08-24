import AppKit
import XCTest
@testable import WhisprStream

@MainActor
final class TriggerShortcutTests: XCTestCase {
    func testDefaultAndLegacyShortcutsAreValid() throws {
        XCTAssertEqual(TriggerShortcut.defaultValue, .modifierOnly(.rightOption))

        for key in TriggerKey.allCases {
            let shortcut = TriggerShortcut.modifierOnly(key)
            XCTAssertNoThrow(try TriggerShortcut.validate(shortcut))
        }
    }

    func testCodableRoundTripPreservesSemanticIdentity() throws {
        let shortcut = TriggerShortcut(
            keyCode: 41,
            modifiers: [.control, .option, .shift, .command],
            key: .printable(fallbackLabel: ";")
        )

        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(TriggerShortcut.self, from: data)

        XCTAssertEqual(decoded, shortcut)
    }

    func testModifierNormalizationIgnoresNonShortcutFlags() {
        let flags: NSEvent.ModifierFlags = [
            .control, .option, .shift, .command, .capsLock, .numericPad, .function
        ]

        XCTAssertEqual(
            TriggerModifiers(flags),
            [.control, .option, .shift, .command]
        )
    }

    func testDisplayUsesMacModifierOrderAndReadableNames() {
        let semicolon = TriggerShortcut(
            keyCode: 41,
            modifiers: [.control, .option, .shift],
            key: .printable(fallbackLabel: ";")
        )
        let hyperSpace = TriggerShortcut(
            keyCode: 49,
            modifiers: [.control, .option, .shift, .command],
            key: .named(.space)
        )

        XCTAssertEqual(semicolon.compactDisplay, "⌃⌥⇧;")
        XCTAssertEqual(semicolon.spokenDisplay, "Control Option Shift Semicolon")
        XCTAssertEqual(hyperSpace.compactDisplay, "⌃⌥⇧⌘Space")
        XCTAssertEqual(hyperSpace.spokenDisplay, "Control Option Shift Command Space")
        XCTAssertEqual(
            hyperSpace.accessibilityLabel,
            "Recording shortcut: Control Option Shift Command Space"
        )
    }

    func testFunctionKeysFormatAndValidate() throws {
        for number in [13, 14, 18, 20, 21, 24] {
            let shortcut = TriggerShortcut(
                keyCode: UInt16(100 + number),
                modifiers: [],
                key: .function(number: number)
            )
            XCTAssertNoThrow(try TriggerShortcut.validate(shortcut))
            XCTAssertEqual(shortcut.compactDisplay, "F\(number)")
        }

        let modified = TriggerShortcut(
            keyCode: 75,
            modifiers: [.option],
            key: .function(number: 5)
        )
        XCTAssertNoThrow(try TriggerShortcut.validate(modified))
        XCTAssertEqual(modified.compactDisplay, "⌥F5")
    }

    func testOrdinaryUnmodifiedKeysNeedAModifier() {
        let letter = TriggerShortcut(
            keyCode: 0,
            modifiers: [],
            key: .printable(fallbackLabel: "A")
        )
        let space = TriggerShortcut(
            keyCode: 49,
            modifiers: [],
            key: .named(.space)
        )
        let f12 = TriggerShortcut(
            keyCode: 111,
            modifiers: [],
            key: .function(number: 12)
        )

        XCTAssertThrowsError(try TriggerShortcut.validate(letter)) { error in
            XCTAssertEqual(error as? TriggerShortcutValidationError, .ordinaryKeyRequiresModifier)
        }
        XCTAssertThrowsError(try TriggerShortcut.validate(space)) { error in
            XCTAssertEqual(error as? TriggerShortcutValidationError, .ordinaryKeyRequiresModifier)
        }
        XCTAssertThrowsError(try TriggerShortcut.validate(f12)) { error in
            XCTAssertEqual(error as? TriggerShortcutValidationError, .ordinaryKeyRequiresModifier)
        }
    }

    func testSyntheticEventCapturesModifiedPrintableAndReservesEscape() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: ";",
            charactersIgnoringModifiers: ";",
            isARepeat: false,
            keyCode: 41
        ))
        let shortcut = try TriggerShortcut.candidate(from: event)

        XCTAssertEqual(shortcut.compactDisplay, "⌃⌥⇧;")

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        XCTAssertThrowsError(try TriggerShortcut.candidate(from: escape)) { error in
            XCTAssertEqual(error as? TriggerShortcutValidationError, .escapeIsReserved)
        }
    }

    func testFunctionEventUsesAppKitSpecialKeyWhenAvailable() throws {
        let characters = String(NSEvent.SpecialKey.f13.unicodeScalar)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 105
        ))

        let shortcut = try TriggerShortcut.candidate(from: event)
        XCTAssertEqual(shortcut.key, .function(number: 13))
        XCTAssertNoThrow(try TriggerShortcut.validate(shortcut))
    }

    func testHighFunctionKeysKeepTheirSemanticNumbers() throws {
        let cases: [(NSEvent.SpecialKey, Int, UInt16)] = [
            (.f13, 13, 105),
            (.f14, 14, 107),
            (.f18, 18, 79),
            (.f20, 20, 90),
            (.f21, 21, 200),
            (.f24, 24, 203)
        ]

        for (specialKey, number, keyCode) in cases {
            let characters = String(specialKey.unicodeScalar)
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
            let shortcut = try TriggerShortcut.candidate(from: event)
            XCTAssertEqual(shortcut.key, .function(number: number))
            XCTAssertEqual(shortcut.keyCode, keyCode)
            XCTAssertEqual(shortcut.compactDisplay, "F\(number)")
        }
    }

    func testModifierOnlyCandidatesPreserveLegacyIdentity() throws {
        for key in TriggerKey.allCases {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: key.flag,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: key.keyCode
            ))
            XCTAssertEqual(
                try TriggerShortcut.candidate(from: event),
                .modifierOnly(key)
            )
        }
    }

    func testNamedSpaceAndReturnCandidatesRequireModifiers() throws {
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        let spaceShortcut = try TriggerShortcut.candidate(from: space)
        XCTAssertEqual(spaceShortcut.key, .named(.space))
        XCTAssertEqual(spaceShortcut.compactDisplay, "⌘Space")

        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        XCTAssertThrowsError(try TriggerShortcut.candidate(from: returnEvent)) { error in
            XCTAssertEqual(
                error as? TriggerShortcutValidationError,
                .ordinaryKeyRequiresModifier
            )
        }
    }

    func testUnsupportedSpecialKeysDoNotBecomePrintableShortcuts() throws {
        let characters = String(NSEvent.SpecialKey.f25.unicodeScalar)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 204
        ))

        XCTAssertThrowsError(try TriggerShortcut.candidate(from: event)) { error in
            XCTAssertEqual(error as? TriggerShortcutValidationError, .unsupportedKey)
        }
    }

    func testCustomChordCoachCopyUsesCompactShortcut() {
        let shortcut = TriggerShortcut(
            keyCode: 41,
            modifiers: [.control, .option, .shift],
            key: .printable(fallbackLabel: ";")
        )

        XCTAssertEqual(
            FirstDictationCoachView.instruction(shortcut: shortcut, mode: .hold),
            "Click in any text field, then hold ⌃⌥⇧;, speak, and release."
        )
        XCTAssertEqual(
            FirstDictationCoachView.instruction(shortcut: shortcut, mode: .tap),
            "Click in any text field, tap ⌃⌥⇧;, speak, then tap it again."
        )
    }
}
