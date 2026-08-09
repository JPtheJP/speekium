import AppKit
import Foundation

enum StorageCapacity {
    static let safetyMargin: Int64 = 512 * 1024 * 1024

    enum Check: Equatable {
        case enough(required: Int64, available: Int64)
        case insufficient(required: Int64, available: Int64)
        case unavailable

        var isEnough: Bool {
            if case .enough = self { return true }
            return false
        }
    }

    static func requiredBytes(_ values: Int64..., margin: Int64 = safetyMargin) -> Int64? {
        guard margin >= 0 else { return nil }
        var total: Int64 = 0
        for value in values {
            guard value >= 0, total <= Int64.max - value else { return nil }
            total += value
        }
        guard total <= Int64.max - margin else { return nil }
        return total + margin
    }

    static func check(available: Int64?, required: Int64?) -> Check {
        guard let available, let required, available >= 0, required >= 0 else {
            return .unavailable
        }
        return available >= required
            ? .enough(required: required, available: available)
            : .insufficient(required: required, available: available)
    }

    /// Finds the nearest existing parent because the destination itself may not
    /// exist before first launch.
    static func availableBytes(
        at destination: URL,
        fileManager: FileManager = .default
    ) -> Int64? {
        var parent = destination
        while !fileManager.fileExists(atPath: parent.path) {
            let next = parent.deletingLastPathComponent()
            guard next.path != parent.path else { return nil }
            parent = next
        }

        if let value = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           value >= 0 {
            return value
        }

        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: parent.path),
              let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value >= 0 else { return nil }
        return free.int64Value
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func openStorageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Storage-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
