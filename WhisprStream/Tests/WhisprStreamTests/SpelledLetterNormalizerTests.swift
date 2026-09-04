import XCTest
@testable import WhisprStream

final class SpelledLetterNormalizerTests: XCTestCase {
    func testJoinsConsecutiveSpelledLetters() {
        XCTAssertEqual(SpelledLetterNormalizer.normalize("O I N P"), "OINP")
        XCTAssertEqual(SpelledLetterNormalizer.normalize("A B"), "AB")
        XCTAssertEqual(SpelledLetterNormalizer.normalize("x y z"), "xyz")
    }

    func testJoinsLetterRunsInsideOtherwiseNaturalText() {
        XCTAssertEqual(
            SpelledLetterNormalizer.normalize("the code is O I N P today"),
            "the code is OINP today"
        )
        XCTAssertEqual(
            SpelledLetterNormalizer.normalize("Use A P I."),
            "Use API."
        )
    }

    func testPreservesPunctuationBoundariesAndOrdinaryWords() {
        XCTAssertEqual(
            SpelledLetterNormalizer.normalize("I, a developer"),
            "I, a developer"
        )
        XCTAssertEqual(
            SpelledLetterNormalizer.normalize("O I, N P"),
            "OI, NP"
        )
        XCTAssertEqual(
            SpelledLetterNormalizer.normalize("Use API today"),
            "Use API today"
        )
    }

    func testPreservesWhitespaceOutsideTheJoinedRun() {
        XCTAssertEqual(
            SpelledLetterNormalizer.normalize("  O\tI\nN P  "),
            "  OINP  "
        )
    }
}
