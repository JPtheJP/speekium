import Darwin
import Foundation

private let expectedBundleIdentifier = "com.jpthejp.speekium"
private let healthFileArgument = "--speekium-update-health-file"
private let healthTokenArgument = "--speekium-update-health-token"
private let launchStabilityInterval: TimeInterval = 2

private var launchHealthTimeout: TimeInterval {
#if DEBUG
    if let rawValue = ProcessInfo.processInfo.environment["SPEEKIUM_UPDATE_HEALTH_TIMEOUT"],
       let value = TimeInterval(rawValue), (1...60).contains(value) {
        return value
    }
#endif
    return 20
}

private enum InstallerError: LocalizedError {
    case invalidArguments
    case unsafePath
    case invalidBundle
    case readySignalFailed
    case healthSignalFailed
    case appDidNotTerminate
    case replacementFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The update installer received invalid arguments."
        case .unsafePath:
            return "The update installer rejected an unsafe path."
        case .invalidBundle:
            return "The staged update is not a valid Speekium app."
        case .readySignalFailed:
            return "The update installer could not signal that it is ready."
        case .healthSignalFailed:
            return "The update installer could not prepare its launch health check."
        case .appDidNotTerminate:
            return "Speekium did not terminate before the update deadline."
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
    let healthFile: URL
    let healthToken: String

    init(_ values: [String]) throws {
        guard values.count == 15 else { throw InstallerError.invalidArguments }
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
              let ready = parsed["--ready-file"],
              let health = parsed["--health-file"],
              let token = parsed["--health-token"],
              UUID(uuidString: token) != nil else {
            throw InstallerError.invalidArguments
        }
        parentPID = pid
        stagedApp = URL(fileURLWithPath: staged, isDirectory: true).standardizedFileURL
        targetApp = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        cleanupRoot = URL(fileURLWithPath: cleanup, isDirectory: true).standardizedFileURL
        readyFile = URL(fileURLWithPath: ready, isDirectory: false).standardizedFileURL
        healthFile = URL(fileURLWithPath: health, isDirectory: false).standardizedFileURL
        healthToken = token
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
          arguments.stagedApp.lastPathComponent.hasPrefix(".Speekium.update-"),
          arguments.cleanupRoot.deletingLastPathComponent().standardizedFileURL == temporary,
          arguments.cleanupRoot.lastPathComponent.hasPrefix("Speekium-installer-"),
          arguments.readyFile.deletingLastPathComponent().standardizedFileURL
            == arguments.cleanupRoot,
          arguments.readyFile.lastPathComponent == "ready",
          arguments.healthFile.deletingLastPathComponent().standardizedFileURL
            == arguments.cleanupRoot,
          arguments.healthFile.lastPathComponent == "health",
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
    let url = directory.appendingPathComponent("Speekium.log")
    if !manager.fileExists(atPath: url.path) {
        _ = manager.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(Data("[speekium updater] \(message)\n".utf8))
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

private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}

private func launchAndConfirmHealth(
    _ app: URL,
    healthFile: URL,
    token: String
) -> Bool {
    guard let bundle = Bundle(url: app),
          let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
          !executableName.isEmpty,
          !executableName.contains("/") else {
        return false
    }
    let executable = app
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(executableName, isDirectory: false)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }

    let process = Process()
    process.executableURL = executable
    process.arguments = [
        healthFileArgument, healthFile.path,
        healthTokenArgument, token,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }

    let deadline = Date().addingTimeInterval(launchHealthTimeout)
    var signalReceivedAt: Date?
    while Date() < deadline {
        guard process.isRunning else {
            process.waitUntilExit()
            return false
        }
        if let contents = try? String(contentsOf: healthFile, encoding: .utf8),
           contents == token {
            if signalReceivedAt == nil {
                signalReceivedAt = Date()
            }
            if Date().timeIntervalSince(signalReceivedAt!) >= launchStabilityInterval {
                return process.isRunning
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    stop(process)
    return false
}

private func install(_ arguments: Arguments) throws {
    try waitForParentToExit(arguments.parentPID)

    let manager = FileManager.default
    let parent = arguments.targetApp.deletingLastPathComponent()
    let backup = parent.appendingPathComponent(
        ".Speekium.update-backup-\(UUID().uuidString).app",
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

    guard launchAndConfirmHealth(
        arguments.targetApp,
        healthFile: arguments.healthFile,
        token: arguments.healthToken
    ) else {
        let failedReplacement = parent.appendingPathComponent(
            ".Speekium.update-failed-\(UUID().uuidString).app",
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
                "the new version did not report a healthy launch; the previous version was restored"
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
private enum SpeekiumUpdateInstaller {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            try validate(arguments)
            defer {
                try? FileManager.default.removeItem(at: arguments.stagedApp)
                try? FileManager.default.removeItem(at: arguments.cleanupRoot)
            }
            guard FileManager.default.createFile(
                atPath: arguments.healthFile.path,
                contents: Data()
            ) else {
                throw InstallerError.healthSignalFailed
            }
            // Publish readiness only after every file needed for the handoff
            // exists. The running app may terminate as soon as it sees this.
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
            FileHandle.standardError.write(Data("Speekium update failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
