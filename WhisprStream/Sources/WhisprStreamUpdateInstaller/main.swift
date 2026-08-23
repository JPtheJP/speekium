import Darwin
import Foundation

private let expectedBundleIdentifier = "com.leoleo.whisprstream"

private enum InstallerError: LocalizedError {
    case invalidArguments
    case unsafePath
    case invalidBundle
    case readySignalFailed
    case appDidNotTerminate
    case replacementFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The update installer received invalid arguments."
        case .unsafePath:
            return "The update installer rejected an unsafe path."
        case .invalidBundle:
            return "The staged update is not a valid WhisprStream app."
        case .readySignalFailed:
            return "The update installer could not signal that it is ready."
        case .appDidNotTerminate:
            return "WhisprStream did not terminate before the update deadline."
        case let .replacementFailed(message):
            return "The app could not be replaced: \(message)"
        }
    }
}

private struct Arguments {
    let parentPID: pid_t
    let stagedApp: URL
    let targetApp: URL
    let cleanupRoot: URL
    let readyFile: URL

    init(_ values: [String]) throws {
        guard values.count == 11 else { throw InstallerError.invalidArguments }
        var parsed: [String: String] = [:]
        var index = 1
        while index < values.count {
            parsed[values[index]] = values[index + 1]
            index += 2
        }
        guard let rawPID = parsed["--wait-pid"],
              let pid = Int32(rawPID), pid > 1,
              let staged = parsed["--staged-app"],
              let target = parsed["--target-app"],
              let cleanup = parsed["--cleanup-root"],
              let ready = parsed["--ready-file"] else {
            throw InstallerError.invalidArguments
        }
        parentPID = pid
        stagedApp = URL(fileURLWithPath: staged, isDirectory: true).standardizedFileURL
        targetApp = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        cleanupRoot = URL(fileURLWithPath: cleanup, isDirectory: true).standardizedFileURL
        readyFile = URL(fileURLWithPath: ready, isDirectory: false).standardizedFileURL
    }
}

private func isDirectoryWithoutSymlink(at url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
        return false
    }
    return values.isDirectory == true && values.isSymbolicLink != true
}

private func validate(_ arguments: Arguments) throws {
    let parent = arguments.targetApp.deletingLastPathComponent().standardizedFileURL
    let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
    guard parent.path != "/",
          arguments.targetApp.pathExtension == "app",
          arguments.stagedApp.pathExtension == "app",
          arguments.stagedApp.deletingLastPathComponent().standardizedFileURL == parent,
          arguments.stagedApp.lastPathComponent.hasPrefix(".WhisprStream.update-"),
          arguments.cleanupRoot.deletingLastPathComponent().standardizedFileURL == temporary,
          arguments.cleanupRoot.lastPathComponent.hasPrefix("WhisprStream-installer-"),
          arguments.readyFile.deletingLastPathComponent().standardizedFileURL
            == arguments.cleanupRoot,
          arguments.readyFile.lastPathComponent == "ready",
          isDirectoryWithoutSymlink(at: arguments.cleanupRoot),
          isDirectoryWithoutSymlink(at: arguments.targetApp),
          isDirectoryWithoutSymlink(at: arguments.stagedApp) else {
        throw InstallerError.unsafePath
    }
    guard Bundle(url: arguments.targetApp)?.bundleIdentifier == expectedBundleIdentifier,
          Bundle(url: arguments.stagedApp)?.bundleIdentifier == expectedBundleIdentifier else {
        throw InstallerError.invalidBundle
    }
}

private func writeLog(_ message: String) {
    let manager = FileManager.default
    guard let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
    let directory = library.appendingPathComponent("Logs", isDirectory: true)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("WhisprStream.log")
    if !manager.fileExists(atPath: url.path) {
        _ = manager.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(Data("[whispr updater] \(message)\n".utf8))
}

private func waitForParentToExit(_ pid: pid_t, timeout: TimeInterval = 60) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        errno = 0
        if kill(pid, 0) != 0, errno == ESRCH { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw InstallerError.appDidNotTerminate
}

@discardableResult
private func relaunch(_ app: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", app.path]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func install(_ arguments: Arguments) throws {
    try waitForParentToExit(arguments.parentPID)

    let manager = FileManager.default
    let parent = arguments.targetApp.deletingLastPathComponent()
    let backup = parent.appendingPathComponent(
        ".WhisprStream.update-backup-\(UUID().uuidString).app",
        isDirectory: true
    )
    var movedOriginal = false

    do {
        try manager.moveItem(at: arguments.targetApp, to: backup)
        movedOriginal = true
        try manager.moveItem(at: arguments.stagedApp, to: arguments.targetApp)
    } catch {
        if movedOriginal, !manager.fileExists(atPath: arguments.targetApp.path) {
            try? manager.moveItem(at: backup, to: arguments.targetApp)
        }
        relaunch(arguments.targetApp)
        throw InstallerError.replacementFailed(error.localizedDescription)
    }

    guard relaunch(arguments.targetApp) else {
        let failedReplacement = parent.appendingPathComponent(
            ".WhisprStream.update-failed-\(UUID().uuidString).app",
            isDirectory: true
        )
        do {
            try manager.moveItem(at: arguments.targetApp, to: failedReplacement)
            do {
                try manager.moveItem(at: backup, to: arguments.targetApp)
            } catch {
                // Keep a usable app at the original path even if restoring the
                // backup itself fails. The untouched backup remains beside it
                // for manual recovery.
                try? manager.moveItem(at: failedReplacement, to: arguments.targetApp)
                throw error
            }
            relaunch(arguments.targetApp)
            try? manager.removeItem(at: failedReplacement)
            throw InstallerError.replacementFailed(
                "the new version did not relaunch; the previous version was restored"
            )
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.replacementFailed(
                "the new version did not relaunch and rollback failed: \(error.localizedDescription)"
            )
        }
    }
    try? manager.removeItem(at: backup)
}

@main
private enum WhisprStreamUpdateInstaller {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            try validate(arguments)
            defer {
                try? FileManager.default.removeItem(at: arguments.stagedApp)
                try? FileManager.default.removeItem(at: arguments.cleanupRoot)
            }
            guard FileManager.default.createFile(
                atPath: arguments.readyFile.path,
                contents: Data()
            ) else {
                throw InstallerError.readySignalFailed
            }
            try install(arguments)
            writeLog("installed update at \(arguments.targetApp.path)")
        } catch {
            writeLog("update failed: \(error.localizedDescription)")
            FileHandle.standardError.write(Data("WhisprStream update failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
