import Foundation

/// Appends to ~/Library/Logs/Speekium.log, shared with the sidecar's stderr.
enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var url: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Speekium.log")
    }

    /// Ensures the shared log file exists and is owner-only (0600). The log
    /// records app/usage metadata and raw sidecar stderr, so on a multi-user
    /// Mac it must not be world-readable. Also tightens a file left 0644 by an
    /// earlier version. Shared by `write` and the sidecar-stderr handle so both
    /// creators agree on permissions.
    @discardableResult
    static func ensureSecureLogFile(
        at url: URL = Log.url,
        fileManager: FileManager = .default
    ) -> URL {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        } else if let permissions = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
                  permissions.int16Value & 0o077 != 0 {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    static func write(_ message: String) {
        let line = "[speekium \(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = ensureSecureLogFile()
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
