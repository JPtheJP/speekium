import AppKit
import XCTest
@testable import Speekium

final class HotKeyMonitorTests: XCTestCase {
    func testExternalTimeoutMakesNextTapStartImmediately() throws {
        let monitor = HotKeyMonitor(key: .rightOption, mode: .tap)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1 }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.handle(try optionEvent(isDown: false))
        XCTAssertEqual(starts, 1)

        // AppState's limit callback ends capture without another key edge.
        monitor.cancelActiveDictation()

        monitor.handle(try optionEvent(isDown: true))
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 0)
    }

    func testExternalTimeoutSuppressesLaterHoldRelease() throws {
        let monitor = HotKeyMonitor(key: .rightOption, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1 }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.cancelActiveDictation()
        monitor.handle(try optionEvent(isDown: false))

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
    }

    private func optionEvent(isDown: Bool) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: isDown ? .option : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: TriggerKey.rightOption.keyCode
        ))
    }
}
