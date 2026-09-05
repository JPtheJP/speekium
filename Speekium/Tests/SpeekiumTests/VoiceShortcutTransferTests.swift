import XCTest
@testable import Speekium

final class VoiceShortcutTransferTests: XCTestCase {
    func testRoundTripPreservesContentAndEnabledStateWithFreshIDs() throws {
        let source = [
            VoiceShortcut(
                id: UUID(),
                trigger: "shortcut résumé",
                replacement: "First line\n第二行: https://example.com/path",
                isEnabled: true
            ),
            VoiceShortcut(
                id: UUID(),
                trigger: "shortcut address",
                replacement: "123 Example Street",
                isEnabled: false
            ),
        ]

        let decoded = try VoiceShortcutTransfer.parse(VoiceShortcutTransfer.data(for: source))

        XCTAssertEqual(decoded.map(\.trigger), source.map(\.trigger))
        XCTAssertEqual(decoded.map(\.replacement), source.map(\.replacement))
        XCTAssertEqual(decoded.map(\.isEnabled), source.map(\.isEnabled))
        XCTAssertNotEqual(decoded.map(\.id), source.map(\.id))
    }

    func testRejectsUnsupportedFormatVersion() throws {
        let data = Data(#"{"formatVersion":2,"shortcuts":[]}"#.utf8)

        XCTAssertThrowsError(try VoiceShortcutTransfer.parse(data)) { error in
            XCTAssertEqual(error as? VoiceShortcutTransferError, .unsupportedVersion(2))
        }
    }

    func testRejectsInvalidAndDuplicateShortcuts() throws {
        let emptyReplacement = Data(
            #"{"formatVersion":1,"shortcuts":[{"enabled":true,"replacement":"","trigger":"hello"}]}"#.utf8
        )
        XCTAssertThrowsError(try VoiceShortcutTransfer.parse(emptyReplacement)) { error in
            XCTAssertEqual(
                error as? VoiceShortcutTransferError,
                .invalidShortcut(index: 0, reason: .emptyReplacement)
            )
        }

        let duplicate = Data(
            #"{"formatVersion":1,"shortcuts":[{"enabled":true,"replacement":"one","trigger":"hello world"},{"enabled":false,"replacement":"two","trigger":"HELLO, WORLD!"}]}"#.utf8
        )
        XCTAssertThrowsError(try VoiceShortcutTransfer.parse(duplicate)) { error in
            XCTAssertEqual(
                error as? VoiceShortcutTransferError,
                .invalidShortcut(index: 1, reason: .duplicateTrigger)
            )
        }
    }

    func testAppendingKeepsExistingShortcutAndAddsOnlyNewTriggers() {
        let existing = VoiceShortcut(
            id: UUID(),
            trigger: "hello world",
            replacement: "keep this",
            isEnabled: false
        )
        let conflict = VoiceShortcut(
            id: UUID(),
            trigger: "HELLO, WORLD!",
            replacement: "do not overwrite",
            isEnabled: true
        )
        let newShortcut = VoiceShortcut(
            id: UUID(),
            trigger: "shortcut website",
            replacement: "https://example.com",
            isEnabled: true
        )

        XCTAssertEqual(
            VoiceShortcutTransfer.appending([conflict, newShortcut], to: [existing]),
            [existing, newShortcut]
        )
    }
}
