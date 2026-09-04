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
    private static let speechEngineStartupTimeout: TimeInterval = 20

    private let state = AppState()
    private let settings = Settings.shared
    private let windows = AppWindows()
    private let runtime = RuntimeManager.shared

    private var panel: HUDPanel!
    private var statusItem: NSStatusItem!
    private let capture = AudioCapture()
    private let media = MediaController(isEnabled: { Settings.shared.pauseMediaWhileDictating })
    private var hotkey: HotKeyMonitor!
    private var asr: ASRService!
    private var dismissWork: DispatchWorkItem?
    private var isASRReady = false
    private var speechEngineGeneration = 0
    private var speechEngineStartedAt: TimeInterval?
    private var speechEngineStartupWork: DispatchWorkItem?
    private var shouldShowFirstDictationCoach = false
    private var precedingTextAtDictationStart: String?

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
                  + "onboarded=\(settings.hasCompletedOnboarding) "
                  + "developerTestMode=\(DeveloperTestMode.isEnabled)")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openDeveloperTestSetup),
            name: .speekiumDeveloperTestModeActivated,
            object: nil
        )

        if runtime.isReady, ModelCatalog.state(for: settings.model).isInstalled {
            startSpeechEngine()
            if settings.hasCompletedOnboarding {
                // Onboarding requests these itself; only prompt directly when skipped.
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                if !trusted { HotKeyMonitor.ensureAccessibility() }
            } else {
                showOnboarding()
            }
        } else {
            presentSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .speekiumDeveloperTestModeActivated, object: nil)
        hotkey?.stop()
        speechEngineStartupWork?.cancel()
        asr?.shutdown()
    }

    // MARK: - Wiring

    private func presentSetup() {
        showOnboarding()
    }

    private func showOnboarding() {
        let shouldOfferFirstDictationCoach = FirstDictationCoachPolicy.shouldOffer(
            hasCompletedOnboarding: settings.hasCompletedOnboarding,
            isDeveloperFirstRunSimulation: DeveloperTestMode.isEnabled
        )
        windows.showOnboarding(
            settings: settings,
            runtime: runtime,
            onPrerequisitesReady: { [weak self] in self?.startSpeechEngine() }
        ) { [weak self] in
            guard let self else { return }
            self.settings.hasCompletedOnboarding = true
            self.startSpeechEngine()
            if shouldOfferFirstDictationCoach,
               AXIsProcessTrusted(),
               AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                self.shouldShowFirstDictationCoach = true
                self.presentFirstDictationCoachIfReady()
            }
        }
    }

    private func presentFirstDictationCoachIfReady() {
        guard shouldShowFirstDictationCoach, isASRReady else { return }
        shouldShowFirstDictationCoach = false
        windows.showFirstDictationCoach(
            key: settings.triggerKey,
            mode: settings.activationMode
        )
    }

    private func startSpeechEngine() {
        guard asr == nil else { return }
        isASRReady = false
        state.phase = .loading
        do {
            try launchSpeechEngine()
        } catch {
            state.phase = .failed("Could not start the ASR engine")
            panel.present()
            return
        }

        hotkey = HotKeyMonitor(key: settings.triggerKey, mode: settings.activationMode)
        hotkey.onStart = { [weak self] in
            guard let self else { return }
            self.shouldShowFirstDictationCoach = false
            self.windows.dismissFirstDictationCoach()
            self.beginDictation()
        }
        hotkey.onStop = { [weak self] in self?.endDictation() }
        hotkey.start()

        settings.onChange = { [weak self] in
            guard let self else { return }
            self.hotkey.rebind(key: self.settings.triggerKey, mode: self.settings.activationMode)
            self.refreshStatusMenu()
        }
        settings.onContextChange = { [weak self] terms in self?.asr?.setContext(terms) }
        settings.onModelChange = { [weak self] _ in self?.reloadASR() }
        settings.onShortUtteranceLanguageChange = { [weak self] _ in self?.reloadASR() }
        capture.onBuffer = { [weak self] pcm, level in
            self?.asr?.sendAudio(pcm)
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.level = self.state.level * 0.55 + CGFloat(level) * 0.45
            }
        }
        refreshStatusMenu()
    }

    private func launchSpeechEngine() throws {
        speechEngineGeneration &+= 1
        let generation = speechEngineGeneration
        let service = try makeService()
        service.onEvent = { [weak self] event in
            guard let self, self.speechEngineGeneration == generation else { return }
            self.handle(event)
        }
        speechEngineStartedAt = ProcessInfo.processInfo.systemUptime
        try service.start()
        asr = service
        armSpeechEngineStartupTimeout(generation: generation)
    }

    private func armSpeechEngineStartupTimeout(generation: Int) {
        speechEngineStartupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.speechEngineGeneration == generation,
                  !self.isASRReady else { return }
            Log.write("speech engine startup timed out after \(Int(Self.speechEngineStartupTimeout))s")
            self.settings.isReloadingModel = false
            self.speechEngineGeneration &+= 1
            self.asr?.shutdown()
            self.asr = nil
            self.state.phase = .failed("Speech engine took too long to start")
            self.panel.present()
            self.refreshStatusMenu()
        }
        speechEngineStartupWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.speechEngineStartupTimeout,
            execute: work
        )
    }

    private func makeService() throws -> ASRService {
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        let script = root.appendingPathComponent("asr_server.py")

        // Model/bits overrides feed the same privileged sidecar, so they honor
        // the same development-only gate as the runtime overrides.
        let overrides = RuntimeEnvironment(
            bundleIdentifier: Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String
        )
        guard let python = runtime.executableURL else {
            Log.write("no managed Python runtime")
            throw CocoaError(.fileNoSuchFile)
        }

        return ASRService(
            python: python,
            script: script,
            model: overrides.value("SPEEKIUM_MODEL") ?? settings.model.rawValue,
            bits: overrides.value("SPEEKIUM_BITS").flatMap { Int($0) } ?? 8,
            context: settings.asrContext,
            shortUtteranceLanguage: settings.shortUtteranceLanguage
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
            media.resumeAfterDictation()
            state.stopDictationTimer()
            state.level = 0
            dismissNow()
        }

        speechEngineStartupWork?.cancel()
        speechEngineGeneration &+= 1
        isASRReady = false
        speechEngineStartedAt = nil
        asr?.shutdown()
        asr = nil
        settings.isReloadingModel = true

        do {
            try launchSpeechEngine()
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
            accessibilityDescription: "Speekium"
        )
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()

        let verb = settings.activationMode == .hold ? "Hold" : "Tap"
        let hintTitle: String
        if isASRReady {
            hintTitle = "\(verb) \(settings.triggerKey.symbol) \(settings.triggerKey.label) to dictate"
        } else if asr != nil {
            hintTitle = "Speech engine warming up…"
        } else {
            hintTitle = "Speech engine unavailable"
        }
        let hint = NSMenuItem(
            title: hintTitle,
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Setup Guide…", action: #selector(openOnboarding), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "About Speekium", action: #selector(openAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Speekium",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
    }

    @objc private func openSettings() { windows.showSettings(settings, runtime: runtime) }
    @objc private func openAbout() { windows.showAbout() }

    @objc private func openDeveloperTestSetup() { presentSetup() }

    @objc private func openOnboarding() { showOnboarding() }

    // MARK: - Dictation lifecycle

    private func beginDictation() {
        guard isASRReady else {
            guard asr != nil else {
                state.phase = .failed("Speech engine is not running")
                panel.present()
                scheduleDismiss(after: 1.8)
                return
            }
            state.phase = .loading
            panel.present()
            return
        }
        guard state.phase != .listening else { return }
        dismissWork?.cancel()
        precedingTextAtDictationStart = settings.autoInsert
            && (settings.contextAwareCapitalization
                || settings.shortUtteranceLanguage.usesCursorContext)
            ? TextInserter.textBeforeCursor()
            : nil
        state.reset()
        state.phase = .listening
        state.startDictationTimer()
        panel.present()

        // Pause playing music before the mic opens so Bluetooth stays in stereo
        // and nothing plays through the call-quality window.
        media.pauseForDictation()
        settings.playStart()
        let shortLanguage = ShortUtteranceLanguageResolver.modelLanguage(
            for: settings.shortUtteranceLanguage,
            precedingText: precedingTextAtDictationStart
        )
        asr.beginUtterance(shortUtteranceLanguage: shortLanguage)
        do { try capture.start() } catch {
            state.stopDictationTimer()
            state.phase = .failed("Microphone unavailable")
            scheduleDismiss(after: 1.6)
        }
    }

    private func endDictation() {
        guard state.phase == .listening else { return }
        capture.stop()
        // Mic is closed; resume whatever we paused (Bluetooth returns to stereo).
        media.resumeAfterDictation()
        state.stopDictationTimer()
        state.level = 0
        state.phase = .thinking
        asr.stopUtterance()
    }

    private func handle(_ event: ASRService.Event) {
        switch event {
        case let .ready(ms):
            let wallMS = speechEngineStartedAt.map {
                Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)
            } ?? ms
            Log.write("speech engine ready: reported=\(ms)ms wall=\(wallMS)ms")
            speechEngineStartupWork?.cancel()
            speechEngineStartupWork = nil
            speechEngineStartedAt = nil
            isASRReady = true
            settings.isReloadingModel = false
            presentFirstDictationCoachIfReady()
            if state.phase == .loading {
                if panel.isVisible {
                    dismissNow()
                } else {
                    state.phase = .idle
                }
            }
            refreshStatusMenu()

        case let .partial(committed, tail):
            guard state.phase == .listening else { return }
            state.committed = committed
            state.tail = tail

        case let .final(text, secs, ms):
            let startingPrecedingText = precedingTextAtDictationStart
            precedingTextAtDictationStart = nil
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
            // Shortcut replacements are user-authored literal output; preserve
            // their casing even when they are inserted mid-sentence.
            if settings.autoInsert,
               settings.contextAwareCapitalization,
               expansion.matchedShortcutID == nil {
                TextInserter.resolveTextBeforeCursor(fallback: startingPrecedingText) {
                    [weak self] precedingText in
                    self?.deliverFinalTranscript(
                        expansion.text,
                        precedingText: precedingText,
                        adjustForCursor: true
                    )
                }
            } else {
                deliverFinalTranscript(
                    expansion.text,
                    precedingText: nil,
                    adjustForCursor: false
                )
            }

        case let .error(message):
            precedingTextAtDictationStart = nil
            media.resumeAfterDictation()
            if !isASRReady {
                speechEngineStartupWork?.cancel()
                speechEngineStartupWork = nil
                speechEngineStartedAt = nil
                Log.write("speech engine startup failed: \(message)")
                speechEngineGeneration &+= 1
                asr?.shutdown()
                asr = nil
                settings.isReloadingModel = false
                refreshStatusMenu()
            }
            state.stopDictationTimer()
            state.phase = .failed(message)
            scheduleDismiss(after: 1.8)

        case let .terminated(message):
            precedingTextAtDictationStart = nil
            media.resumeAfterDictation()
            speechEngineStartupWork?.cancel()
            speechEngineStartupWork = nil
            speechEngineStartedAt = nil
            speechEngineGeneration &+= 1
            isASRReady = false
            asr = nil
            settings.isReloadingModel = false
            state.stopDictationTimer()
            state.phase = .failed(message)
            refreshStatusMenu()
            scheduleDismiss(after: 1.8)
        }
    }

    private func deliverFinalTranscript(
        _ text: String,
        precedingText: String?,
        adjustForCursor: Bool
    ) {
        let deliveredText = adjustForCursor
            ? TranscriptFormatter.adjustedForCursor(text, precedingText: precedingText)
            : text
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
