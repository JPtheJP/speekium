import AppKit
import AVFoundation
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let settings = Settings.shared
    private let windows = AppWindows()
    private let runtime = RuntimeManager.shared

    private var panel: HUDPanel!
    private var statusItem: NSStatusItem!
    private let capture = AudioCapture()
    private var hotkey: HotKeyMonitor!
    private var asr: ASRService!
    private var dismissWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = HUDPanel(state: state)
        state.onDictationLimitReached = { [weak self] in
            guard let self else { return }
            self.hotkey.cancelActiveDictation()
            self.endDictation()
        }
        setUpStatusItem()

        let trusted = AXIsProcessTrusted()
        Log.write("launch: accessibility=\(trusted ? "granted" : "DENIED") "
                  + "onboarded=\(settings.hasCompletedOnboarding)")

        if runtime.isReady, ModelCatalog.state(for: settings.model).isInstalled {
            startSpeechEngine()
            if settings.hasCompletedOnboarding {
                // Onboarding requests these itself; only prompt directly when skipped.
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                if !trusted { HotKeyMonitor.ensureAccessibility() }
            } else {
                windows.showOnboarding(settings: settings, runtime: runtime) { [weak self] in
                    self?.settings.hasCompletedOnboarding = true
                    self?.startSpeechEngine()
                }
            }
        } else {
            presentSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        asr?.shutdown()
    }

    // MARK: - Wiring

    private func presentSetup() {
        windows.showOnboarding(settings: settings, runtime: runtime) { [weak self] in
            guard let self else { return }
            self.settings.hasCompletedOnboarding = true
            self.startSpeechEngine()
        }
    }

    private func startSpeechEngine() {
        guard asr == nil else { return }
        do {
            asr = try makeService()
            asr.onEvent = { [weak self] in self?.handle($0) }
            try asr.start()
        } catch {
            state.phase = .failed("Could not start the ASR engine")
            panel.present()
            return
        }

        hotkey = HotKeyMonitor(key: settings.triggerKey, mode: settings.activationMode)
        hotkey.onStart = { [weak self] in self?.beginDictation() }
        hotkey.onStop = { [weak self] in self?.endDictation() }
        hotkey.start()

        settings.onChange = { [weak self] in
            guard let self else { return }
            self.hotkey.rebind(key: self.settings.triggerKey, mode: self.settings.activationMode)
            self.refreshStatusMenu()
        }
        settings.onContextChange = { [weak self] terms in self?.asr?.setContext(terms) }
        settings.onModelChange = { [weak self] _ in self?.reloadASR() }
        capture.onBuffer = { [weak self] pcm, level in
            self?.asr?.sendAudio(pcm)
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.level = self.state.level * 0.55 + CGFloat(level) * 0.45
            }
        }
    }

    private func makeService() throws -> ASRService {
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        let script = root.appendingPathComponent("asr_server.py")

        let env = ProcessInfo.processInfo.environment
        guard let python = runtime.executableURL else {
            Log.write("no managed Python runtime")
            throw CocoaError(.fileNoSuchFile)
        }

        return ASRService(
            python: python,
            script: script,
            model: env["WHISPR_MODEL"] ?? settings.model.rawValue,
            bits: Int(env["WHISPR_BITS"] ?? "8") ?? 8,
            context: settings.asrContext
        )
    }

    /// Restarts the sidecar on the currently selected model.
    ///
    /// The weights load once at sidecar start, so a model switch cannot be
    /// applied to the running process the way the vocabulary can — the whole
    /// sidecar has to come down and pay the load again.
    private func reloadASR() {
        // Deliberately does not drive the HUD's `.loading` phase: the user is in
        // Settings, not dictating, and racing a phase change against the dismiss
        // animation is what makes the capsule flicker. Progress is reported in
        // the Settings window instead.
        if state.phase == .listening {
            capture.stop()
            state.stopDictationTimer()
            state.level = 0
            dismissNow()
        }

        asr?.shutdown()
        settings.isReloadingModel = true

        do {
            asr = try makeService()
            asr.onEvent = { [weak self] in self?.handle($0) }
            try asr.start()
        } catch {
            settings.isReloadingModel = false
            state.phase = .failed("Could not start the ASR engine")
            panel.present()
            scheduleDismiss(after: 2.0)
        }
        refreshStatusMenu()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "WhisprStream"
        )
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()

        let verb = settings.activationMode == .hold ? "Hold" : "Tap"
        let hint = NSMenuItem(
            title: "\(verb) \(settings.triggerKey.symbol) \(settings.triggerKey.label) to dictate",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Setup Guide…", action: #selector(openOnboarding), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "About WhisprStream", action: #selector(openAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit WhisprStream",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
    }

    @objc private func openSettings() { windows.showSettings(settings, runtime: runtime) }
    @objc private func openAbout() { windows.showAbout() }

    @objc private func openOnboarding() {
        windows.showOnboarding(settings: settings, runtime: runtime) { [weak self] in
            self?.settings.hasCompletedOnboarding = true
            self?.startSpeechEngine()
        }
    }

    // MARK: - Dictation lifecycle

    private func beginDictation() {
        guard state.phase != .listening else { return }
        dismissWork?.cancel()
        state.reset()
        state.phase = .listening
        state.startDictationTimer()
        panel.present()

        settings.playStart()
        asr.beginUtterance()
        do { try capture.start() } catch {
            state.stopDictationTimer()
            state.phase = .failed("Microphone unavailable")
            scheduleDismiss(after: 1.6)
        }
    }

    private func endDictation() {
        guard state.phase == .listening else { return }
        capture.stop()
        state.stopDictationTimer()
        state.level = 0
        state.phase = .thinking
        asr.stopUtterance()
    }

    private func handle(_ event: ASRService.Event) {
        switch event {
        case .ready:
            settings.isReloadingModel = false
            if state.phase == .loading { state.phase = .idle }
            refreshStatusMenu()

        case let .partial(committed, tail):
            guard state.phase == .listening else { return }
            state.committed = committed
            state.tail = tail

        case let .final(text, secs, ms):
            state.lastAudioSecs = secs
            state.lastDurationMS = ms
            guard !text.isEmpty else {
                dismissNow()
                return
            }
            let normalizedText = SpokenSymbolNormalizer.normalize(
                SpokenNumberNormalizer.normalize(text)
            )
            let formattedText = TranscriptFormatter.format(
                normalizedText,
                usePunctuation: settings.usePunctuation
            )
            let expansion = TranscriptExpander.expand(formattedText, using: settings.voiceShortcuts)
            if let matchedID = expansion.matchedShortcutID {
                Log.write("voice shortcut matched id=\(matchedID) inputChars=\(normalizedText.count) outputChars=\(expansion.text.count)")
            }
            let deliveredText = expansion.text
            guard !deliveredText.isEmpty else {
                dismissNow()
                return
            }
            let insertionText = TranscriptFormatter.textForInsertion(deliveredText)
            state.committed = deliveredText
            state.tail = ""
            state.phase = .inserted

            TextInserter.deliver(
                deliveredText,
                insertionText: insertionText,
                insertAtCursor: settings.autoInsert,
                copyToClipboard: settings.copyToClipboard
            )
            settings.playFeedback()
            scheduleDismiss(after: 0.42)

        case let .error(message):
            state.stopDictationTimer()
            state.phase = .failed(message)
            scheduleDismiss(after: 1.8)
        }
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissNow() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Clears state only once the fade has finished. Resetting any earlier makes
    /// the HUD flip back to the "Listening…" placeholder mid-fade, because
    /// `.idle` renders as the listening state.
    private func dismissNow() {
        dismissWork?.cancel()
        panel.dismiss { [weak self] in
            guard let self else { return }
            self.state.phase = .idle
            self.state.reset()
        }
    }
}
