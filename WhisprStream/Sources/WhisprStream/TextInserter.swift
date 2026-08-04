import AppKit

/// Delivers text to whichever app has focus and/or the clipboard.
///
/// Pasteboard + Cmd-V rather than synthesised per-character key events: unicode
/// keystroke injection is unreliable for CJK, and this path handles mixed
/// scripts correctly. When clipboard retention is disabled, the previous
/// pasteboard contents are restored after the paste.
enum TextInserter {
    private struct PasteboardSnapshot {
        let items: [[(NSPasteboard.PasteboardType, Data)]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type, data)
                }
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            guard !restored.isEmpty else { return }
            pasteboard.writeObjects(restored)
        }
    }

    /// Performs the requested output actions. Insertion always uses a
    /// temporary pasteboard write; `copyToClipboard` controls whether that
    /// write is retained or restored after the synthetic paste.
    static func deliver(_ text: String, insertAtCursor: Bool, copyToClipboard: Bool) {
        guard !text.isEmpty else { return }

        if insertAtCursor {
            insert(text, retainOnClipboard: copyToClipboard)
        } else if copyToClipboard {
            copyOnly(text)
        } else {
            Log.write("transcript delivered nowhere (both output options off)")
        }
    }

    private static func insert(_ text: String, retainOnClipboard: Bool) {
        guard !text.isEmpty else { return }

        let front = NSWorkspace.shared.frontmostApplication
        Log.write("insert: \(text.count) chars -> front=\(front?.bundleIdentifier ?? "nil") "
                  + "(\(front?.localizedName ?? "?")) trusted=\(AXIsProcessTrusted())")

        let pb = NSPasteboard.general
        let saved = retainOnClipboard ? nil : PasteboardSnapshot(pb)

        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        Log.write("  pasteboard write=\(ok) readback=\((pb.string(forType: .string) ?? "").prefix(20))")
        let insertedChangeCount = pb.changeCount

        // The pasteboard write is asynchronous from the front app's point of
        // view; posting Cmd-V in the same runloop tick often pastes stale
        // contents or nothing at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pressCommandV()

            if let saved {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    // Do not overwrite a clipboard update made by the user or
                    // the destination app while the paste was in flight.
                    guard pb.changeCount == insertedChangeCount else {
                        Log.write("  skipped clipboard restore: clipboard changed")
                        return
                    }
                    saved.restore(to: pb)
                    Log.write("  restored previous clipboard contents")
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
        Log.write("copied \(text.count) chars (insert at cursor off)")
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
