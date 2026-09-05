import Foundation

enum UpdateLaunchHealth {
    static let fileArgument = "--speekium-update-health-file"
    static let tokenArgument = "--speekium-update-health-token"

    struct Request: Equatable {
        let file: URL
        let token: String
    }

    static func request(
        arguments: [String] = CommandLine.arguments,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> Request? {
        guard let filePath = uniqueValue(after: fileArgument, in: arguments),
              let token = uniqueValue(after: tokenArgument, in: arguments),
              UUID(uuidString: token) != nil else {
            return nil
        }

        let file = URL(fileURLWithPath: filePath, isDirectory: false).standardizedFileURL
        let parent = file.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        guard parent.deletingLastPathComponent().standardizedFileURL == temporary,
              parent.lastPathComponent.hasPrefix("Speekium-installer-"),
              file.lastPathComponent == "health",
              let parentValues = try? parent.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true,
              let fileValues = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              fileValues.isRegularFile == true,
              fileValues.isSymbolicLink != true,
              fileManager.isWritableFile(atPath: file.path) else {
            return nil
        }
        return Request(file: file, token: token)
    }

    @discardableResult
    static func signalIfRequested(
        arguments: [String] = CommandLine.arguments,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let request = request(
            arguments: arguments,
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        ) else {
            return false
        }
        do {
            try Data(request.token.utf8).write(to: request.file, options: .atomic)
            return true
        } catch {
            Log.write("update launch health signal failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func uniqueValue(after name: String, in arguments: [String]) -> String? {
        let indexes = arguments.indices.filter { arguments[$0] == name }
        guard indexes.count == 1,
              let index = indexes.first,
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
