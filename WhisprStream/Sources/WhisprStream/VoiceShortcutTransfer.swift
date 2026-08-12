import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct VoiceShortcutTransferEntry: Codable, Equatable {
    let trigger: String
    let replacement: String
    let enabled: Bool

    init(shortcut: VoiceShortcut) {
        trigger = shortcut.trigger
        replacement = shortcut.replacement
        enabled = shortcut.isEnabled
    }

    var shortcut: VoiceShortcut {
        VoiceShortcut(
            id: UUID(),
            trigger: trigger,
            replacement: replacement,
            isEnabled: enabled
        )
    }
}

private struct VoiceShortcutTransferArchive: Codable {
    let formatVersion: Int
    let shortcuts: [VoiceShortcutTransferEntry]
}

enum VoiceShortcutTransferError: LocalizedError, Equatable {
    case invalidFile
    case unsupportedVersion(Int)
    case invalidShortcut(index: Int, reason: VoiceShortcutValidationError)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "The selected file is not a valid WhisprStream Voice Shortcuts file."
        case let .unsupportedVersion(version):
            return "This Voice Shortcuts file uses unsupported format version \(version)."
        case let .invalidShortcut(index, reason):
            let detail: String
            switch reason {
            case .emptyTrigger:
                detail = "the trigger is empty"
            case .emptyReplacement:
                detail = "the replacement text is empty"
            case .duplicateTrigger:
                detail = "its trigger duplicates an earlier shortcut"
            }
            return "Shortcut \(index + 1) cannot be imported because \(detail)."
        }
    }
}

enum VoiceShortcutTransfer {
    static let contentType = UTType.json
    static let currentFormatVersion = 1

    /// Appends shortcuts whose normalized triggers are new. A matching trigger
    /// from an import never changes the user's existing replacement or enabled
    /// state.
    static func appending(
        _ imported: [VoiceShortcut],
        to existing: [VoiceShortcut]
    ) -> [VoiceShortcut] {
        var existingKeys = Set(existing.map {
            VoiceShortcutValidation.normalizedTrigger($0.trigger).key
        })
        let additions = imported.filter {
            existingKeys.insert(VoiceShortcutValidation.normalizedTrigger($0.trigger).key).inserted
        }
        return existing + additions
    }

    static func parse(_ data: Data) throws -> [VoiceShortcut] {
        let archive: VoiceShortcutTransferArchive
        do {
            archive = try JSONDecoder().decode(VoiceShortcutTransferArchive.self, from: data)
        } catch {
            throw VoiceShortcutTransferError.invalidFile
        }
        guard archive.formatVersion == currentFormatVersion else {
            throw VoiceShortcutTransferError.unsupportedVersion(archive.formatVersion)
        }

        var shortcuts: [VoiceShortcut] = []
        for (index, entry) in archive.shortcuts.enumerated() {
            let shortcut = entry.shortcut
            do {
                try VoiceShortcutValidation.validate(shortcut, against: shortcuts)
            } catch let reason as VoiceShortcutValidationError {
                throw VoiceShortcutTransferError.invalidShortcut(index: index, reason: reason)
            } catch {
                throw VoiceShortcutTransferError.invalidFile
            }
            shortcuts.append(shortcut)
        }
        return shortcuts
    }

    static func data(for shortcuts: [VoiceShortcut]) throws -> Data {
        let archive = VoiceShortcutTransferArchive(
            formatVersion: currentFormatVersion,
            shortcuts: shortcuts.map(VoiceShortcutTransferEntry.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }
}

/// Versioned JSON so multiline replacements, Unicode text, and enabled states
/// survive a round trip without relying on fragile delimiter escaping.
struct VoiceShortcutDocument: FileDocument {
    static var readableContentTypes: [UTType] { [VoiceShortcutTransfer.contentType] }
    static var writableContentTypes: [UTType] { [VoiceShortcutTransfer.contentType] }

    let shortcuts: [VoiceShortcut]

    init(shortcuts: [VoiceShortcut]) {
        self.shortcuts = shortcuts
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        shortcuts = try VoiceShortcutTransfer.parse(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try VoiceShortcutTransfer.data(for: shortcuts))
    }
}
