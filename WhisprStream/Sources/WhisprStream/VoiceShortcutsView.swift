import AppKit
import SwiftUI

struct VoiceShortcutsView: View {
    @ObservedObject var settings: Settings

    @State private var editorDraft: ShortcutEditorDraft?
    @State private var deleteID: UUID?
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument = VoiceShortcutDocument(shortcuts: [])
    @State private var importPreview: ShortcutImportPreview?
    @State private var transferError: String?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                shortcutSection
                suggestionsSection
                privacyNote
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editorDraft) { draft in
            VoiceShortcutEditorSheet(
                settings: settings,
                initial: draft,
                onSave: save
            )
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [VoiceShortcutTransfer.contentType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                prepareImport(from: url)
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError {
                    transferError = error.localizedDescription
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: VoiceShortcutTransfer.contentType,
            defaultFilename: "WhisprStream Voice Shortcuts"
        ) { result in
            if case let .failure(error) = result,
               (error as NSError).code != NSUserCancelledError {
                transferError = error.localizedDescription
            }
        }
        .alert(item: $importPreview) { preview in
            let newCount = preview.shortcuts.count - preview.existingMatches
            let message = "This file contains \(newCount) new shortcuts. "
                + "They will be added to your current shortcuts; existing shortcuts will stay unchanged. "
                + "\(preview.existingMatches) matching triggers will be ignored."
            if newCount == 0 {
                return Alert(
                    title: Text("No New Voice Shortcuts"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
            return Alert(
                title: Text("Import Voice Shortcuts"),
                message: Text(message),
                primaryButton: .default(Text("Import \(newCount) New")) {
                    applyImport(preview)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Delete Voice Shortcut?",
            isPresented: Binding(
                get: { deleteID != nil },
                set: { if !$0 { deleteID = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let deleteID {
                    settings.removeVoiceShortcut(id: deleteID)
                }
                deleteID = nil
            }
            Button("Cancel", role: .cancel) { deleteID = nil }
        } message: {
            Text("This shortcut's replacement text will be removed.")
        }
        .alert(
            "Voice Shortcut Transfer Failed",
            isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            )
        ) {
            Button("OK") { transferError = nil }
        } message: {
            Text(transferError ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice Shortcuts")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Say a saved trigger anywhere in a dictation to expand it into saved text.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Menu {
                Button {
                    isImporting = true
                } label: {
                    Label("Import Shortcuts…", systemImage: "square.and.arrow.down")
                }

                Button {
                    exportDocument = VoiceShortcutDocument(shortcuts: settings.voiceShortcuts)
                    isExporting = true
                } label: {
                    Label("Export Shortcuts…", systemImage: "square.and.arrow.up")
                }
                .disabled(settings.voiceShortcuts.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .help("Import or export Voice Shortcuts")

            Button {
                editorDraft = ShortcutEditorDraft(shortcut: nil)
            } label: {
                Label("New Shortcut", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Your shortcuts", count: settings.voiceShortcuts.count)

            if settings.voiceShortcuts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    Text("Create your first shortcut")
                        .font(.headline)
                    Text("Save a link, signature, address, or reusable developer template.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .cardBackground()
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(settings.voiceShortcuts) { shortcut in
                        shortcutRow(shortcut)
                    }
                }
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Start with an idea")
            Text("Use the rare prefix \"shortcut\" to keep triggers separate from normal dictation. These examples are prefilled for you; they do not create a shortcut until you save it.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(availableSuggestions) { suggestion in
                    Button {
                        editorDraft = ShortcutEditorDraft(
                            shortcut: nil,
                            suggestedTrigger: suggestion.trigger
                        )
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.trigger)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(suggestion.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                    }
                    .buttonStyle(.plain)
                    .help("Use \(suggestion.trigger) as a trigger")
                }
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Shortcuts stay on this Mac and are inserted through the clipboard. Exported files contain the full replacement text. Do not use shortcuts for passwords or API keys.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private var availableSuggestions: [VoiceShortcutSuggestion] {
        let used = Set(settings.voiceShortcuts.map {
            VoiceShortcutValidation.normalizedTrigger($0.trigger).key
        })
        return VoiceShortcutSuggestions.all.filter {
            !used.contains(VoiceShortcutValidation.normalizedTrigger($0.trigger).key)
        }
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: VoiceShortcut) -> some View {
        HStack(spacing: 13) {
            Image(systemName: shortcut.isEnabled ? "waveform.badge.mic" : "pause.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(shortcut.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(shortcut.trigger)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(preview(shortcut.replacement))
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(shortcut.isEnabled ? 1 : 0.55)

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: {
                        settings.voiceShortcuts.first(where: { $0.id == shortcut.id })?.isEnabled ?? false
                    },
                    set: { settings.setVoiceShortcutEnabled(id: shortcut.id, enabled: $0) }
                )
            )
            .labelsHidden()
            .help(shortcut.isEnabled ? "Disable shortcut" : "Enable shortcut")
            .accessibilityLabel("Enable \(shortcut.trigger)")

            Button {
                editorDraft = ShortcutEditorDraft(shortcut: shortcut)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit \(shortcut.trigger)")
            .accessibilityLabel("Edit \(shortcut.trigger)")

            Button {
                deleteID = shortcut.id
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete \(shortcut.trigger)")
            .accessibilityLabel("Delete \(shortcut.trigger)")
        }
        .padding(14)
        .cardBackground()
    }

    private func preview(_ replacement: String) -> String {
        let oneLine = replacement.replacingOccurrences(of: "\n", with: " ")
        return oneLine.isEmpty ? "No replacement text" : oneLine
    }

    private func save(_ shortcut: VoiceShortcut) {
        do {
            if editorDraft?.shortcutID == nil {
                try settings.addVoiceShortcut(shortcut)
            } else {
                try settings.updateVoiceShortcut(shortcut)
            }
            editorDraft = nil
        } catch {
            Log.write("voice shortcut save rejected: \(error)")
        }
    }

    private func prepareImport(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let shortcuts = try VoiceShortcutTransfer.parse(Data(contentsOf: url))
            let existingKeys = Set(settings.voiceShortcuts.map {
                VoiceShortcutValidation.normalizedTrigger($0.trigger).key
            })
            let existingMatches = shortcuts.filter {
                existingKeys.contains(VoiceShortcutValidation.normalizedTrigger($0.trigger).key)
            }.count
            importPreview = ShortcutImportPreview(
                shortcuts: shortcuts,
                existingMatches: existingMatches
            )
        } catch {
            transferError = error.localizedDescription
        }
    }

    private func applyImport(_ preview: ShortcutImportPreview) {
        let updated = VoiceShortcutTransfer.appending(
            preview.shortcuts,
            to: settings.voiceShortcuts
        )
        do {
            try settings.setVoiceShortcuts(updated)
        } catch {
            transferError = error.localizedDescription
        }
    }
}

private struct ShortcutImportPreview: Identifiable {
    let id = UUID()
    let shortcuts: [VoiceShortcut]
    let existingMatches: Int
}

private extension View {
    func cardBackground() -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }
}

private struct ShortcutEditorDraft: Identifiable {
    let id: UUID
    let shortcutID: UUID?
    let trigger: String
    let replacement: String
    let isEnabled: Bool

    init(shortcut: VoiceShortcut?, suggestedTrigger: String = "") {
        id = UUID()
        shortcutID = shortcut?.id
        trigger = shortcut?.trigger ?? suggestedTrigger
        replacement = shortcut?.replacement ?? ""
        isEnabled = shortcut?.isEnabled ?? true
    }
}

private struct VoiceShortcutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: Settings
    let initial: ShortcutEditorDraft
    let onSave: (VoiceShortcut) -> Void

    @State private var trigger: String
    @State private var replacement: String
    @State private var isEnabled: Bool
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case trigger
    }

    init(
        settings: Settings,
        initial: ShortcutEditorDraft,
        onSave: @escaping (VoiceShortcut) -> Void
    ) {
        self.settings = settings
        self.initial = initial
        self.onSave = onSave
        _trigger = State(initialValue: initial.trigger)
        _replacement = State(initialValue: initial.replacement)
        _isEnabled = State(initialValue: initial.isEnabled)
    }

    private var normalizedTrigger: NormalizedVoiceTrigger {
        VoiceShortcutValidation.normalizedTrigger(trigger)
    }

    private var validationError: VoiceShortcutValidationError? {
        let shortcut = VoiceShortcut(
            id: initial.shortcutID ?? UUID(),
            trigger: trigger,
            replacement: replacement,
            isEnabled: isEnabled
        )
        do {
            try VoiceShortcutValidation.validate(
                shortcut,
                against: settings.voiceShortcuts,
                excluding: initial.shortcutID
            )
            return nil
        } catch let error as VoiceShortcutValidationError {
            return error
        } catch {
            return .emptyTrigger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    triggerField
                    replacementField

                    HStack {
                        Toggle("Enabled", isOn: $isEnabled)
                        Spacer()
                        if normalizedTrigger.tokens.count == 1 && validationError != .emptyTrigger {
                            Label("Single-word trigger", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let validationError {
                        Text(message(for: validationError))
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let shortcut = VoiceShortcut(
                        id: initial.shortcutID ?? UUID(),
                        trigger: trigger,
                        replacement: replacement,
                        isEnabled: isEnabled
                    )
                    onSave(shortcut)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(validationError != nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 590, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = .trigger }
    }

    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: initial.shortcutID == nil ? "plus.circle.fill" : "pencil.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(initial.shortcutID == nil ? "New Shortcut" : "Edit Shortcut")
                    .font(.title3.weight(.bold))
                Text("Say the trigger in any dictation to insert the saved text.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
        }
        .padding(24)
        .background(.thinMaterial)
    }

    private var triggerField: some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel("When I say", detail: "Use a distinctive word or phrase")
            TextField("e.g. shortcut github", text: $trigger)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .focused($focusedField, equals: .trigger)
                .onSubmit { focusedField = nil }
                .padding(12)
                .cardBackground()
        }
    }

    private var replacementField: some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Insert this", detail: "Paste a URL, profile, signature, or multiline template")
            PasteableTextEditor(text: $replacement)
                .frame(height: 155)
            .cardBackground()
        }
    }

    private func fieldLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func message(for error: VoiceShortcutValidationError) -> String {
        switch error {
        case .emptyTrigger:
            return "The trigger must contain at least one letter or number."
        case .emptyReplacement:
            return "Add the text you want inserted."
        case .duplicateTrigger:
            return "That trigger is already saved, including in a disabled shortcut."
        }
    }
}

/// A native NSTextView gives the replacement field normal macOS editing
/// behavior, including Cmd-V, selection, undo, multiline input, and the
/// standard contextual menu. SwiftUI's TextEditor can lose paste focus inside
/// a Form-hosted sheet on macOS, which made saved URLs appear impossible to
/// enter.
private struct PasteableTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PasteableNativeTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class PasteableNativeTextView: NSTextView {
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isPaste = flags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "v"
            if isPaste {
                paste(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
        }
    }
}
