import AppKit

/// Watches a modifier key globally to drive dictation.
///
/// Modifier keys arrive as `.flagsChanged` rather than key events, so press and
/// release are inferred from whether the key's own flag is still set. Requires
/// Accessibility permission; without it the global monitor silently sees nothing,
/// which is why `AppDelegate` logs the trust state at launch.
final class HotKeyMonitor {
    private var key: TriggerKey
    private var mode: ActivationMode

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isKeyDown = false
    private var isActive = false

    /// Begin capturing. In tap mode this fires on alternate presses.
    var onStart: (() -> Void)?
    /// Stop capturing and transcribe.
    var onStop: (() -> Void)?

    init(key: TriggerKey, mode: ActivationMode) {
        self.key = key
        self.mode = mode
    }

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged], handler: handler
        )
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handler(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isKeyDown = false
    }

    /// Apply new settings. Cancels anything in flight so a mode change can't
    /// strand the engine in a recording state.
    func rebind(key: TriggerKey, mode: ActivationMode) {
        if isActive { onStop?(); isActive = false }
        self.key = key
        self.mode = mode
        start()
    }

    /// Synchronize the monitor after dictation is stopped by something other
    /// than the trigger key, such as the recording time limit. In tap mode this
    /// makes the very next press start again instead of acting like a stale stop.
    func cancelActiveDictation() {
        isActive = false
    }

    /// Internal so the modifier-edge state machine can be exercised without
    /// installing global event monitors in the test process.
    func handle(_ event: NSEvent) {
        guard event.keyCode == key.keyCode else { return }
        let down = event.modifierFlags.contains(key.flag)
        guard down != isKeyDown else { return }   // ignore repeats
        isKeyDown = down

        switch mode {
        case .hold:
            if down {
                isActive = true
                onStart?()
            } else if isActive {
                isActive = false
                onStop?()
            }

        case .tap:
            // Only the press edge matters; the release is what ends a hold.
            guard down else { return }
            isActive.toggle()
            if isActive { onStart?() } else { onStop?() }
        }
    }

    /// Prompts for Accessibility on first launch; returns current trust state.
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
