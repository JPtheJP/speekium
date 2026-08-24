import AppKit
import Darwin

/// Packaged-app E2E entry point for the recording-shortcut feature.
///
/// This runs inside the signed development app rather than a test runner so
/// the test exercises the same compiled model, UserDefaults migration,
/// recorder candidate conversion, monitor state machine, and copy surfaces
/// that the app uses. Real keyboard delivery from a physical programmable
/// keyboard remains a manual QA concern because macOS does not synthesize
/// F21–F24 hardware events in a deterministic test process.
@MainActor
enum TriggerShortcutE2E {
    static let launchArgument = "--whispr-e2e-trigger-shortcut"
    private static let statusArgumentPrefix = "--whispr-e2e-status="

    static var isRequested: Bool {
        guard CommandLine.arguments.contains(launchArgument) else { return false }
        let identifier = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleIdentifier"
        ) as? String ?? ""
        return identifier.hasPrefix("dev.")
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        do {
            try runAssertions()
            writeStatus("completed")
            print("WhisprStream trigger-shortcut E2E passed")
            fflush(stdout)
            exit(EXIT_SUCCESS)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func runAssertions() throws {
        let defaultsName = "WhisprStreamTriggerShortcutE2E.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw E2EFailure("Could not create an isolated UserDefaults suite.")
        }
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let settings = Settings(defaults: defaults)
        try require(
            settings.triggerShortcut == .defaultValue,
            "new settings did not default to Right Option"
        )
        try require(
            defaults.data(forKey: "triggerShortcut.v1") != nil,
            "new settings did not persist triggerShortcut.v1"
        )

        let semicolonEvent = try keyEvent(
            type: .keyDown,
            flags: [.control, .option, .shift],
            characters: ";",
            keyCode: 41
        )
        let semicolon = try TriggerShortcut.candidate(from: semicolonEvent)
        try require(
            semicolon.compactDisplay == "⌃⌥⇧;",
            "semicolon candidate displayed as \(semicolon.compactDisplay)"
        )
        try require(
            semicolon.spokenDisplay == "Control Option Shift Semicolon",
            "semicolon candidate has incorrect spoken form"
        )

        settings.triggerShortcut = semicolon
        let reloaded = Settings(defaults: defaults)
        try require(
            reloaded.triggerShortcut == semicolon,
            "custom semicolon shortcut did not survive reload"
        )

        let f13 = try TriggerShortcut.candidate(from: keyEvent(
            type: .keyDown,
            flags: [],
            characters: String(NSEvent.SpecialKey.f13.unicodeScalar),
            keyCode: 105
        ))
        try require(f13.key == .function(number: 13), "F13 was not identified semantically")
        try require(f13.compactDisplay == "F13", "F13 display was incorrect")

        var holdStarts = 0
        var holdStops = 0
        let holdMonitor = HotKeyMonitor(shortcut: semicolon, mode: .hold)
        holdMonitor.onStart = { holdStarts += 1 }
        holdMonitor.onStop = { holdStops += 1 }

        holdMonitor.handle(semicolonEvent)
        holdMonitor.handle(try keyEvent(
            type: .keyUp,
            flags: [],
            characters: ";",
            keyCode: semicolon.keyCode
        ))
        try require(holdStarts == 1 && holdStops == 1, "hold chord did not start and stop once")

        holdMonitor.handle(semicolonEvent)
        holdMonitor.handle(try keyEvent(
            type: .flagsChanged,
            flags: [.control, .shift],
            characters: "",
            keyCode: TriggerKey.leftOption.keyCode
        ))
        holdMonitor.handle(try keyEvent(
            type: .keyUp,
            flags: [.control, .shift],
            characters: ";",
            keyCode: semicolon.keyCode
        ))
        try require(
            holdStarts == 2 && holdStops == 2,
            "releasing a required modifier did not stop hold mode exactly once"
        )

        var tapStarts = 0
        var tapStops = 0
        let tapMonitor = HotKeyMonitor(shortcut: semicolon, mode: .tap)
        tapMonitor.onStart = { tapStarts += 1 }
        tapMonitor.onStop = { tapStops += 1 }
        tapMonitor.handle(semicolonEvent)
        tapMonitor.handle(try keyEvent(
            type: .keyUp,
            flags: [],
            characters: ";",
            keyCode: semicolon.keyCode
        ))
        tapMonitor.handle(semicolonEvent)
        try require(
            tapStarts == 1 && tapStops == 1,
            "tap chord did not toggle only on key-down edges"
        )

        var functionStarts = 0
        var functionStops = 0
        let functionMonitor = HotKeyMonitor(shortcut: f13, mode: .hold)
        functionMonitor.onStart = { functionStarts += 1 }
        functionMonitor.onStop = { functionStops += 1 }
        functionMonitor.handle(try keyEvent(
            type: .keyDown,
            flags: [],
            characters: String(NSEvent.SpecialKey.f13.unicodeScalar),
            keyCode: f13.keyCode
        ))
        functionMonitor.handle(try keyEvent(
            type: .keyUp,
            flags: [],
            characters: String(NSEvent.SpecialKey.f13.unicodeScalar),
            keyCode: f13.keyCode
        ))
        try require(
            functionStarts == 1 && functionStops == 1,
            "unmodified F13 did not work in hold mode"
        )

        let rebound = TriggerShortcut(
            keyCode: 40,
            modifiers: [.command],
            key: .printable(fallbackLabel: "K")
        )
        var suspendedStarts = 0
        var suspendedStops = 0
        let suspendedMonitor = HotKeyMonitor(shortcut: semicolon, mode: .hold)
        suspendedMonitor.onStart = { suspendedStarts += 1 }
        suspendedMonitor.onStop = { suspendedStops += 1 }
        suspendedMonitor.handle(semicolonEvent)
        suspendedMonitor.suspend()
        suspendedMonitor.rebind(shortcut: rebound, mode: .hold)
        suspendedMonitor.handle(semicolonEvent)
        try require(
            suspendedStarts == 1 && suspendedStops == 1,
            "suspended monitor still responded to the old shortcut"
        )
        suspendedMonitor.resume()
        suspendedMonitor.handle(try keyEvent(
            type: .keyDown,
            flags: [.command],
            characters: "k",
            keyCode: rebound.keyCode
        ))
        suspendedMonitor.handle(try keyEvent(
            type: .keyUp,
            flags: [],
            characters: "k",
            keyCode: rebound.keyCode
        ))
        try require(
            suspendedStarts == 2 && suspendedStops == 2,
            "resumed monitor did not use the rebound shortcut"
        )

        var captureTransitions: [Bool] = []
        settings.onTriggerShortcutCaptureChange = { capturing in
            captureTransitions.append(capturing)
        }
        settings.beginTriggerShortcutCapture()
        settings.beginTriggerShortcutCapture()
        settings.endTriggerShortcutCapture()
        settings.endTriggerShortcutCapture()
        try require(
            captureTransitions == [true, false],
            "recorder capture lifecycle was not idempotent"
        )

        let instruction = FirstDictationCoachView.instruction(
            shortcut: semicolon,
            mode: .hold
        )
        try require(
            instruction.contains("⌃⌥⇧;"),
            "first-dictation coach did not use the saved shortcut"
        )

        let legacyDefaultsName = "\(defaultsName).legacy"
        guard let legacyDefaults = UserDefaults(suiteName: legacyDefaultsName) else {
            throw E2EFailure("Could not create the legacy migration suite.")
        }
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsName)
        defer { legacyDefaults.removePersistentDomain(forName: legacyDefaultsName) }
        legacyDefaults.set(TriggerKey.leftOption.rawValue, forKey: "triggerKey")
        legacyDefaults.set(Data([0x01, 0x02, 0x03]), forKey: "triggerShortcut.v1")
        let migrated = Settings(defaults: legacyDefaults)
        try require(
            migrated.triggerShortcut == .modifierOnly(.leftOption),
            "corrupt new data did not fall back to the legacy shortcut"
        )
    }

    private static func keyEvent(
        type: NSEvent.EventType,
        flags: NSEvent.ModifierFlags,
        characters: String,
        keyCode: UInt16
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw E2EFailure("AppKit refused to create a synthetic \(type) event.")
        }
        return event
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw E2EFailure(message) }
    }

    private static func fail(_ message: String) -> Never {
        writeStatus("failed: \(message)")
        fputs("WhisprStream trigger-shortcut E2E failed: \(message)\n", stderr)
        fflush(stderr)
        exit(EXIT_FAILURE)
    }

    private static func writeStatus(_ value: String) {
        guard let argument = CommandLine.arguments.first(where: {
            $0.hasPrefix(statusArgumentPrefix)
        }) else { return }
        let path = String(argument.dropFirst(statusArgumentPrefix.count))
        guard !path.isEmpty else { return }
        try? Data(value.utf8).write(
            to: URL(fileURLWithPath: path),
            options: .atomic
        )
    }

    private struct E2EFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }

        init(_ message: String) {
            self.message = message
        }
    }
}
