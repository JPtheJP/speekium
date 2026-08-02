import AppKit

/// Inserts text into whichever app has focus.
///
/// Pasteboard + Cmd-V rather than synthesised per-character key events: unicode
/// keystroke injection is unreliable for CJK, and this path handles mixed
/// scripts correctly. The previous pasteboard contents are restored afterwards.
enum TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let front = NSWorkspace.shared.frontmostApplication
        Log.write("insert: \(text.count) chars -> front=\(front?.bundleIdentifier ?? "nil") "
                  + "(\(front?.localizedName ?? "?")) trusted=\(AXIsProcessTrusted())")

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        Log.write("  pasteboard write=\(ok) readback=\((pb.string(forType: .string) ?? "").prefix(20))")

        // The pasteboard write is asynchronous from the front app's point of
        // view; posting Cmd-V in the same runloop tick often pastes stale
        // contents or nothing at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pressCommandV()

            if let saved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    pb.clearContents()
                    pb.setString(saved, forType: .string)
                }
            }
        }
    }

    /// Put the transcript on the clipboard without pasting it.
    static func copyOnly(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.write("copied \(text.count) chars (auto-insert off)")
    }

    private static func pressCommandV() {
        // .hidSystemState + .cghidEventTap is the combination that actually
        // reaches other applications; session taps get dropped for synthetic
        // modifier-key combinations.
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9        // kVK_ANSI_V
        let cmdKey: CGKeyCode = 55     // kVK_Command

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else {
            Log.write("  CGEvent creation FAILED (no event source)")
            return
        }

        // Stray modifiers still latched from the push-to-talk key would turn
        // Cmd-V into Cmd-Opt-V, which is not paste.
        let live = CGEventSource.flagsState(.combinedSessionState)
        if live.contains(.maskAlternate) || live.contains(.maskControl) || live.contains(.maskShift) {
            Log.write("  WARNING stray modifiers latched: \(live.rawValue)")
        }

        // Send a real modifier press/release around the V rather than only
        // stamping .maskCommand, so apps that track modifier state agree.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        let tap: CGEventTapLocation = .cghidEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
        Log.write("  posted Cmd-V to cghidEventTap")
    }

    /// The app running the HUD, so we can avoid pasting into ourselves.
    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
