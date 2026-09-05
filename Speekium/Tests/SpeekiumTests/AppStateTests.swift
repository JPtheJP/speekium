import XCTest
@testable import Speekium

@MainActor
final class AppStateTests: XCTestCase {
    func testLimitWarningShowsCountdown() {
        let state = AppState()
        state.phase = .listening
        let limit = AppState.dictationLimitSeconds
        let warningStart = limit - AppState.dictationWarningLeadTimeSeconds

        state.dictationElapsedSeconds = warningStart - 0.1
        XCTAssertFalse(state.isApproachingDictationLimit)

        state.dictationElapsedSeconds = warningStart
        XCTAssertTrue(state.isApproachingDictationLimit)
        XCTAssertEqual(
            state.dictationCountdownLabel,
            "\(Int(AppState.dictationWarningLeadTimeSeconds))s"
        )

        state.dictationElapsedSeconds = limit
        XCTAssertEqual(state.dictationCountdownLabel, "0s")

        state.phase = .thinking
        XCTAssertFalse(state.isApproachingDictationLimit)
    }
}
