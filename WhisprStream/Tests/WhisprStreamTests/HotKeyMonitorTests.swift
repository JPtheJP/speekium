import AppKit
import XCTest
@testable import WhisprStream

final class HotKeyMonitorTests: XCTestCase {
    func testRejectedTapStartRetriesOnNextPressWithoutStopping() throws {
        let monitor = HotKeyMonitor(key: .rightOption, mode: .tap)
        var attempts = 0
        var stops = 0
        monitor.onStart = {
            attempts += 1
            return attempts > 1
        }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.handle(try optionEvent(isDown: false))
        monitor.handle(try optionEvent(isDown: true))

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(stops, 0)
    }

    func testRejectedHoldStartDoesNotStopOnRelease() throws {
        let monitor = HotKeyMonitor(key: .rightOption, mode: .hold)
        var stops = 0
        monitor.onStart = { false }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.handle(try optionEvent(isDown: false))

        XCTAssertEqual(stops, 0)
    }

    func testExternalTimeoutMakesNextTapStartImmediately() throws {
        let monitor = HotKeyMonitor(key: .rightOption, mode: .tap)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.handle(try optionEvent(isDown: false))
        XCTAssertEqual(starts, 1)

        monitor.cancelActiveDictation()

        monitor.handle(try optionEvent(isDown: true))
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 0)
    }

    func testExternalTimeoutSuppressesLaterHoldRelease() throws {
        let monitor = HotKeyMonitor(key: .rightOption, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.cancelActiveDictation()
        monitor.handle(try optionEvent(isDown: false))

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
    }

    func testLegacyRightOptionHoldStartsAndStopsOnEdges() throws {
        let monitor = HotKeyMonitor(shortcut: .modifierOnly(.rightOption), mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.handle(try optionEvent(isDown: false))

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testLegacyModifierTapAlternatesOnlyOnPressEdges() throws {
        let monitor = HotKeyMonitor(shortcut: .modifierOnly(.rightOption), mode: .tap)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try optionEvent(isDown: true))
        monitor.handle(try optionEvent(isDown: false))
        monitor.handle(try optionEvent(isDown: true))
        monitor.handle(try optionEvent(isDown: false))

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testCustomChordHoldMatchesExactModifiers() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option, .shift]))
        monitor.handle(try primaryEvent(type: .keyUp, modifiers: []))

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testCustomChordTapOnlyTogglesOnKeyDown() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .tap)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option, .shift]))
        monitor.handle(try primaryEvent(type: .keyUp, modifiers: []))
        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option, .shift]))

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testCustomChordRejectsMissingExtraAndCapsLockModifiers() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        monitor.onStart = { starts += 1; return true }

        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option]))
        monitor.handle(try primaryEvent(type: .keyUp, modifiers: []))
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift, .command]
        ))
        monitor.handle(try primaryEvent(type: .keyUp, modifiers: []))
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift, .capsLock]
        ))

        XCTAssertEqual(starts, 1)
    }

    func testRepeatedChordKeyDownDoesNotDuplicateStart() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        monitor.onStart = { starts += 1; return true }

        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift],
            isARepeat: false
        ))
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift],
            isARepeat: true
        ))

        XCTAssertEqual(starts, 1)
    }

    func testReleasingRequiredModifierStopsHoldOnlyOnce() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option, .shift]))
        monitor.handle(try modifierFlagsEvent(
            modifiers: [.control, .shift],
            keyCode: TriggerKey.leftOption.keyCode
        ))
        monitor.handle(try primaryEvent(type: .keyUp, modifiers: [.control, .shift]))

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testExtraModifierPressedAfterActivationDoesNotStopHold() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var stops = 0
        monitor.onStart = { true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift]
        ))
        monitor.handle(try modifierFlagsEvent(
            modifiers: [.control, .option, .shift, .command],
            keyCode: TriggerKey.rightCommand.keyCode
        ))
        XCTAssertEqual(stops, 0)

        monitor.handle(try primaryEvent(type: .keyUp, modifiers: []))
        XCTAssertEqual(stops, 1)
    }

    func testUnmodifiedF13WorksAsHoldAndTapShortcut() throws {
        let shortcut = TriggerShortcut(
            keyCode: 105,
            modifiers: [],
            key: .function(number: 13)
        )
        let hold = HotKeyMonitor(shortcut: shortcut, mode: .hold)
        var holdStarts = 0
        var holdStops = 0
        hold.onStart = { holdStarts += 1; return true }
        hold.onStop = { holdStops += 1 }
        hold.handle(try primaryEvent(type: .keyDown, modifiers: [], keyCode: 105))
        hold.handle(try primaryEvent(type: .keyUp, modifiers: [], keyCode: 105))
        XCTAssertEqual(holdStarts, 1)
        XCTAssertEqual(holdStops, 1)

        let tap = HotKeyMonitor(shortcut: shortcut, mode: .tap)
        var tapStarts = 0
        var tapStops = 0
        tap.onStart = { tapStarts += 1; return true }
        tap.onStop = { tapStops += 1 }
        tap.handle(try primaryEvent(type: .keyDown, modifiers: [], keyCode: 105))
        tap.handle(try primaryEvent(type: .keyUp, modifiers: [], keyCode: 105))
        tap.handle(try primaryEvent(type: .keyDown, modifiers: [], keyCode: 105))
        XCTAssertEqual(tapStarts, 1)
        XCTAssertEqual(tapStops, 1)
    }

    func testChordTimeoutSuppressesLaterHoldRelease() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var stops = 0
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option, .shift]))
        monitor.cancelActiveDictation()
        monitor.handle(try primaryEvent(type: .keyUp, modifiers: []))

        XCTAssertEqual(stops, 0)
    }

    func testChordTimeoutAllowsNextTapAfterPhysicalRelease() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .tap)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift]
        ))
        monitor.handle(try primaryEvent(type: .keyUp, modifiers: []))
        monitor.cancelActiveDictation()
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift]
        ))

        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 0)
    }

    func testUnrelatedEventsDoNotChangeMonitorState() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.command],
            keyCode: 40,
            characters: "k"
        ))
        monitor.handle(try primaryEvent(
            type: .keyUp,
            modifiers: [],
            keyCode: 40,
            characters: "k"
        ))
        monitor.handle(try modifierFlagsEvent(
            modifiers: [.option],
            keyCode: TriggerKey.rightOption.keyCode
        ))

        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
    }

    func testWhisprGeneratedEventsCannotTriggerMatchingShortcut() throws {
        let shortcut = TriggerShortcut(
            keyCode: 9,
            modifiers: [.command],
            key: .printable(fallbackLabel: "V")
        )
        let monitor = HotKeyMonitor(shortcut: shortcut, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try markedEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        monitor.handle(try markedEvent(type: .keyUp, keyCode: 9, flags: .maskCommand))

        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
    }

    func testInitialRecorderStateKeepsMonitorSuspendedUntilCaptureEnds() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        monitor.onStart = { starts += 1; return true }

        monitor.setSuspendedForShortcutCapture(true)
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift]
        ))
        XCTAssertEqual(starts, 0)

        monitor.setSuspendedForShortcutCapture(false)
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift]
        ))
        XCTAssertEqual(starts, 1)
        monitor.stop()
    }

    func testRebindEndsActiveDictationExactlyOnce() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.control, .option, .shift]
        ))
        monitor.rebind(
            shortcut: TriggerShortcut(
                keyCode: 40,
                modifiers: [.command],
                key: .printable(fallbackLabel: "K")
            ),
            mode: .hold
        )
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)

        monitor.handle(try primaryEvent(
            type: .keyUp,
            modifiers: [],
            keyCode: semicolonShortcut.keyCode
        ))
        XCTAssertEqual(stops, 1)
    }

    func testSuspendStopsOnceIgnoresEventsAndResumeUsesReboundShortcut() throws {
        let monitor = HotKeyMonitor(shortcut: semicolonShortcut, mode: .hold)
        var starts = 0
        var stops = 0
        monitor.onStart = { starts += 1; return true }
        monitor.onStop = { stops += 1 }

        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option, .shift]))
        monitor.suspend()
        monitor.suspend()
        monitor.handle(try primaryEvent(type: .keyDown, modifiers: [.control, .option, .shift]))

        let rebound = TriggerShortcut(
            keyCode: 40,
            modifiers: [.command],
            key: .printable(fallbackLabel: "K")
        )
        monitor.rebind(shortcut: rebound, mode: .hold)
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.command],
            keyCode: rebound.keyCode,
            characters: "k"
        ))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)

        monitor.resume()
        monitor.handle(try primaryEvent(
            type: .keyDown,
            modifiers: [.command],
            keyCode: rebound.keyCode,
            characters: "k"
        ))
        monitor.handle(try primaryEvent(
            type: .keyUp,
            modifiers: [],
            keyCode: rebound.keyCode,
            characters: "k"
        ))
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
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

    private var semicolonShortcut: TriggerShortcut {
        TriggerShortcut(
            keyCode: 41,
            modifiers: [.control, .option, .shift],
            key: .printable(fallbackLabel: ";")
        )
    }

    private func primaryEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16? = nil,
        characters: String = ";",
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode ?? semicolonShortcut.keyCode
        ))
    }

    private func modifierFlagsEvent(
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func markedEvent(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) throws -> NSEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: type == .keyDown
        ))
        event.flags = flags
        SyntheticInputEvent.mark(event)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}
