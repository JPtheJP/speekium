import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Shared normalization for manually entered and imported vocabulary entries.
enum VocabularyEntry {
    static func normalize(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    static func normalizedUnique(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { raw in
            guard let entry = normalize(raw), seen.insert(entry).inserted else { return nil }
            return entry
        }
    }
}

struct ParsedVocabulary {
    let entries: [String]
    let duplicatesSkipped: Int
}

enum VocabularyTransferError: LocalizedError {
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The selected file is not a valid UTF-8 text file."
        }
    }
}

enum VocabularyTransfer {
    static let contentType = UTType.plainText

    /// Appends imported entries while preserving the current list and its
    /// ordering. Existing entries always win when the import contains a match.
    static func appending(_ imported: [String], to existing: [String]) -> [String] {
        VocabularyEntry.normalizedUnique(existing + imported)
    }

    static func parse(_ data: Data) throws -> ParsedVocabulary {
        guard var text = String(data: data, encoding: .utf8) else {
            throw VocabularyTransferError.invalidUTF8
        }

        // UTF-8 files exported by some editors begin with a byte-order mark.
        text.removePrefix("\u{feff}")

        let candidates = text
            .split(whereSeparator: \.isNewline)
            .compactMap { VocabularyEntry.normalize(String($0)) }
        let entries = VocabularyEntry.normalizedUnique(candidates)
        return ParsedVocabulary(
            entries: entries,
            duplicatesSkipped: candidates.count - entries.count
        )
    }

    static func data(for entries: [String]) -> Data {
        let text = entries.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
        return Data(text.utf8)
    }
}

/// Plain UTF-8, one word or phrase per line. This is intentionally human
/// readable so users can edit or share their vocabulary without app-specific
/// tooling.
struct VocabularyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [VocabularyTransfer.contentType] }
    static var writableContentTypes: [UTType] { [VocabularyTransfer.contentType] }

    let entries: [String]

    init(entries: [String]) {
        self.entries = entries
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        entries = try VocabularyTransfer.parse(data).entries
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: VocabularyTransfer.data(for: entries))
    }
}

private extension String {
    mutating func removePrefix(_ prefix: String) {
        guard hasPrefix(prefix) else { return }
        removeFirst(prefix.count)
    }
}
