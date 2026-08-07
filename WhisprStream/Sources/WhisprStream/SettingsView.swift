import SwiftUI

/// Native macOS settings with a permanently visible labeled sidebar.
///
/// A native TabView collapses its labels into an icon-only strip when macOS
/// decides space is tight. Settings contains six sections, so a fixed sidebar
/// is clearer and does not turn navigation into an overflow control.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var runtime: RuntimeManager
    @State private var selectedSection: SettingsSection? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 540)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection ?? .general {
        case .general: GeneralTab(settings: settings)
        case .model: ModelTab(settings: settings)
        case .sound: SoundTab(settings: settings)
        case .shortcuts: VoiceShortcutsView(settings: settings)
        case .permissions: PermissionsTab()
        case .engine: RuntimeTab(runtime: runtime)
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, model, sound, shortcuts, permissions, engine

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .model: "Model"
        case .sound: "Sound"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .engine: "Engine"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .model: "waveform.badge.mic"
        case .sound: "speaker.wave.2"
        case .shortcuts: "text.badge.plus"
        case .permissions: "lock.shield"
        case .engine: "cpu"
        }
    }
}

private struct RuntimeTab: View {
    @ObservedObject var runtime: RuntimeManager

    var body: some View {
        Form {
            Section("Speech engine") {
                LabeledContent("Status") {
                    switch runtime.phase {
                    case .ready:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .missing: Text("Not installed")
                    case .downloading: ProgressView()
                    case .installing: ProgressView()
                    case let .failed(message): Text(message).foregroundStyle(.red)
                    }
                }
                if runtime.isReady {
                    Text("The engine is stored in Application Support, separately from the app bundle. Models are downloaded only when you choose one.")
                        .foregroundStyle(.secondary)
                    if runtime.isDeveloperTestMode {
                        Button("Reset simulated first run") { runtime.resetDeveloperTestInstall() }
                        Text("This changes no real files. Quit and relaunch with the test flag to run onboarding again.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Install speech engine") { runtime.install() }
                    if let message = runtime.installMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("Activation", selection: $settings.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Trigger key", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text("\(key.symbol)  \(key.label)").tag(key)
                    }
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text(settings.activationMode.detail)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Output") {
                Toggle(isOn: $settings.autoInsert) {
                    Text("Insert at cursor")
                    Text("Paste the finished transcript into the active app.")
                }

                Toggle(isOn: $settings.copyToClipboard) {
                    Text("Copy to clipboard")
                    Text("Keep the finished transcript on the clipboard.")
                }

                Toggle(isOn: $settings.usePunctuation) {
                    Text("Use punctuation")
                    Text(settings.usePunctuation
                         ? "Keep sentence-ending punctuation from dictation."
                         : "Remove sentence-ending punctuation from dictation.")
                }
            }

            VocabularySection(settings: settings)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Model

private struct ModelTab: View {
    @ObservedObject var settings: Settings
    @StateObject private var downloader = ModelDownloader()

    /// Bumped to force a re-read of the cache. Not a cache of the result:
    /// `TabView` builds more than one `ModelTab`, and `@State` filled by
    /// `onAppear` on one instance is not the state the displayed instance
    /// renders with — which showed every model as "not installed".
    @State private var reloadToken = 0

    var body: some View {
        Form {
            Section {
                ForEach(ASRModel.allCases) { model in
                    ModelRow(
                        model: model,
                        state: installState(model),
                        isSelected: settings.model == model,
                        downloader: downloader,
                        select: { settings.model = model }
                    )
                }
            } header: {
                Text("Speech model")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.isReloadingModel {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading weights…")
                        }
                    } else if let failure = downloader.failure {
                        Text(failure).foregroundStyle(.red)
                    } else {
                        Text("Switching models restarts the speech engine and reloads the weights, which takes a couple of seconds. Everything stays on this Mac.")
                    }
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                .animation(.spring(response: 0.3, dampingFraction: 0.85),
                           value: settings.isReloadingModel)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in reloadToken &+= 1 }
        .task {
            downloader.onFinish = { _, _ in reloadToken &+= 1 }
        }
    }

    /// Reads the cache on every render. Cheap — a few `stat` calls — and it
    /// cannot show a stale answer after a download or an external change.
    private func installState(_ model: ASRModel) -> ModelInstallState {
        _ = reloadToken
        return ModelCatalog.state(for: model)
    }
}

private struct ModelRow: View {
    let model: ASRModel
    let state: ModelInstallState
    let isSelected: Bool
    @ObservedObject var downloader: ModelDownloader
    let select: () -> Void

    private var isDownloading: Bool { downloader.active == model }

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            Text(model.label)
            Text(model.detail)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isDownloading)
    }

    @ViewBuilder
    private var trailing: some View {
        if isDownloading {
            VStack(alignment: .trailing, spacing: 4) {
                if let fraction = downloader.fraction {
                    ProgressView(value: fraction).frame(width: 116)
                    Text(progressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { downloader.cancel() }
                    .controlSize(.small)
            }
        } else if state.isInstalled {
            if isSelected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            } else {
                Button("Use", action: select)
            }
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Button("Download") { downloader.start(model) }
                    .disabled(downloader.isRunning)
                Text(sizeLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var progressLabel: String {
        let got = ModelCatalog.formatted(bytes: downloader.received)
        guard downloader.total > 0 else { return got }
        return "\(got) of \(ModelCatalog.formatted(bytes: downloader.total))"
    }

    /// Never says "Resume", and never counts a partial as progress.
    ///
    /// Measured: huggingface_hub writes each attempt to a *process-unique*
    /// `<etag>.<uuid>.incomplete` (file_download.py:1920) and starts from zero, so
    /// an interrupted download is dead weight rather than a head start — even
    /// with Xet disabled. Showing "3.6 GB of 4 GB done" would promise a resume
    /// that will not happen.
    private var sizeLabel: String {
        if case let .partial(bytes) = state, bytes > 0 {
            return "\(model.approximateSize) · \(ModelCatalog.formatted(bytes: bytes)) unused on disk"
        }
        return model.approximateSize
    }
}

// MARK: - Sound

private struct SoundTab: View {
    @ObservedObject var settings: Settings

    private var isPair: Bool {
        if case .pair = settings.soundTheme { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.playSound) {
                    Text("Play a sound")
                    Text(isPair
                         ? "One sound when dictation starts, its answer when the text lands."
                         : "A single sound when the text lands.")
                }

                Picker("Sound", selection: $settings.soundTheme) {
                    ForEach(SoundPair.groups, id: \.0) { name, pairs in
                        Section(name) {
                            ForEach(pairs) { pair in
                                Text(pair.label).tag(SoundTheme.pair(pair))
                            }
                        }
                    }
                    Section("macOS alert sounds") {
                        ForEach(Settings.availableSounds, id: \.self) { name in
                            Text(name).tag(SoundTheme.system(name))
                        }
                    }
                }
                .disabled(!settings.playSound)

                LabeledContent("Preview") {
                    Button {
                        settings.previewSound()
                    } label: {
                        Label(isPair ? "Play both" : "Play", systemImage: "play.fill")
                    }
                    .disabled(!settings.playSound)
                }
            } header: {
                Text("Sound")
            } footer: {
                Group {
                    if case let .pair(pair) = settings.soundTheme {
                        Text(pair.detail)
                    } else {
                        Text("These are macOS's own alert sounds, from /System/Library/Sounds. Drop an .aiff or .wav into ~/Library/Sounds and it appears here too. They play on insert only — pick a pair above to also get a sound when dictation starts.")
                    }
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.soundTheme)
            }
        }
        .formStyle(.grouped)
        // Auditioning while picking is the whole point of a sound list.
        .onChange(of: settings.soundTheme) { _, _ in
            if settings.playSound { settings.previewSound() }
        }
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @StateObject private var permissions = Permissions()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Microphone",
                    detail: "Required to hear you. Audio is transcribed on-device.",
                    granted: permissions.microphone == .authorized,
                    open: { permissions.openSettings(.microphone) }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required to see your trigger key and paste at the cursor.",
                    granted: permissions.accessibility,
                    open: { permissions.openSettings(.accessibility) }
                )
            } header: {
                Text("Required access")
            } footer: {
                Text(permissions.allGranted
                     ? "Everything is granted. WhisprStream is ready."
                     : "This list updates by itself — leave it open while you change System Settings.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.beginPolling() }
        .onDisappear { permissions.endPolling() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            } else {
                Button("Open Settings", action: open)
            }
        } label: {
            Text(title)
            Text(detail)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: granted)
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 34)

            VStack(spacing: 5) {
                Text("WhisprStream")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("On-device dictation for macOS.\nHandles Chinese and English mixed in one sentence.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 30)

            VStack(spacing: 6) {
                // Reads the live setting: hardcoding this would quietly lie the
                // moment someone switched models in the Model tab.
                detail("Speech model", "\(Settings.shared.model.label) · 8-bit")
                detail("Runtime", "MLX on Apple Silicon")
                detail("Network", "None — audio never leaves this Mac")
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(width: 380, height: 350)
        .background(.regularMaterial)
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 210, alignment: .leading)
        }
    }
}
