import AppKit

private final class EditorDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private let readyURL: URL
    private let resultURL: URL
    private var window: NSWindow?
    private weak var textView: NSTextView?
    private var eventMonitor: Any?

    init(readyPath: String, resultPath: String) {
        readyURL = URL(fileURLWithPath: readyPath)
        resultURL = URL(fileURLWithPath: resultPath)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
        textView.isRichText = false
        textView.isEditable = true
        textView.delegate = self
        textView.string = "Hello this "
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 560, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speekium Context E2E Editor"
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        self.window = window
        self.textView = textView

        // PID-targeted CGEvents are delivered to this process in headless CI,
        // but AppKit does not dispatch standard edit commands to an inactive
        // window. Handle the same commands explicitly and delay copy long
        // enough to reproduce the clipboard race fixed in TextInserter.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }

        write(textView.string, to: resultURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.write(
                String(ProcessInfo.processInfo.processIdentifier),
                to: self.readyURL
            )
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        write(textView.string, to: resultURL)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let textView else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 123,
           flags.contains(.command),
           flags.contains(.shift) {
            let caret = NSMaxRange(textView.selectedRange())
            textView.setSelectedRange(NSRange(location: 0, length: caret))
            return true
        }

        if event.keyCode == 8, flags.contains(.command) {
            let selection = textView.selectedRange()
            guard selection.length > 0 else { return true }
            let copiedText = (textView.string as NSString).substring(with: selection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(copiedText, forType: .string)
            }
            return true
        }

        if event.keyCode == 124, flags.isEmpty {
            let end = NSMaxRange(textView.selectedRange())
            textView.setSelectedRange(NSRange(location: end, length: 0))
            return true
        }

        if event.keyCode == 9, flags.contains(.command),
           let pastedText = NSPasteboard.general.string(forType: .string) {
            textView.insertText(pastedText, replacementRange: textView.selectedRange())
            write(textView.string, to: resultURL)
            return true
        }

        return false
    }

    private func write(_ value: String, to url: URL) {
        do {
            try Data(value.utf8).write(to: url, options: .atomic)
        } catch {
            fputs("E2E editor failed to write \(url.path): \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: ContextAwareEditor READY_PATH RESULT_PATH\n", stderr)
    exit(EXIT_FAILURE)
}

let app = NSApplication.shared
private let delegate = EditorDelegate(
    readyPath: CommandLine.arguments[1],
    resultPath: CommandLine.arguments[2]
)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
