import XCTest
@testable import Speekium

final class VocabularyTransferTests: XCTestCase {
    func testAppendingPreservesExistingEntriesAndAddsOnlyNewOnes() {
        XCTAssertEqual(
            VocabularyTransfer.appending(
                ["GitHub", "new phrase", "Codex"],
                to: ["Codex", "GitHub"]
            ),
            ["Codex", "GitHub", "new phrase"]
        )
    }
}
