import CryptoKit
import Foundation

/// Installs and locates the optional Python speech-engine runtime.
///
/// Shipping the runtime separately keeps the app download small. A release
/// provides a versioned HTTPS zip and its SHA-256 in Info.plist; the archive
/// expands to `runtime/bin/python3.12` under Application Support. The checksum
/// is deliberately mandatory: this app executes the downloaded interpreter.
@MainActor
final class RuntimeManager: ObservableObject {
    static let shared = RuntimeManager()

    enum Phase: Equatable {
        case ready
        case missing
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .missing
    private var installTask: Task<Void, Never>?
    private var simulatedRuntimeInstalled = false

    private init() { refresh() }

    var executableURL: URL? {
        if developerTestMode {
            guard simulatedRuntimeInstalled else { return nil }
            return developmentPythonURL
        }

        let environment = ProcessInfo.processInfo.environment
        if let override = environment["WHISPR_PYTHON"], isExecutable(override) {
            return URL(fileURLWithPath: override)
        }

        let managed = runtimeDirectory.appendingPathComponent("bin/python3.12")
        if isExecutable(managed.path) { return managed }

        return developmentPythonURL
    }

    var isReady: Bool { executableURL != nil }
    var isDeveloperTestMode: Bool { developerTestMode }

    var installMessage: String? {
        guard !isReady else { return nil }
        if developerTestMode {
            return "Developer test mode simulates the engine download and reuses your local development runtime."
        }
        guard runtimeArchiveURL != nil, expectedChecksum != nil else {
            return "This build does not include a speech-engine installer."
        }
        return nil
    }

    func refresh() {
        if isReady {
            phase = .ready
        } else if case .downloading = phase {
            return
        } else if case .installing = phase {
            return
        } else {
            phase = .missing
        }
    }

    func install() {
        guard installTask == nil else { return }
        if developerTestMode {
            installSimulatedRuntime()
            return
        }
        guard let archiveURL = runtimeArchiveURL, let checksum = expectedChecksum else {
            phase = .failed("The speech-engine installer is not configured for this build.")
            return
        }
        guard archiveURL.scheme == "https" else {
            phase = .failed("The speech-engine installer must use HTTPS.")
            return
        }

        phase = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: archiveURL)
                guard let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode) else {
                    throw RuntimeError.downloadFailed
                }
                self.phase = .installing
                try Self.installArchive(
                    at: temporaryURL,
                    expectedChecksum: checksum,
                    destination: self.runtimeDirectory
                )
                self.refresh()
                guard self.isReady else { throw RuntimeError.invalidArchive }
                Log.write("runtime installed at \(self.runtimeDirectory.path)")
            } catch is CancellationError {
                self.phase = .missing
            } catch {
                Log.write("runtime install failed: \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        refresh()
    }

    /// Makes this process behave like a fresh install, without touching the
    /// actual runtime, models, preferences, or microphone permissions.
    func resetDeveloperTestInstall() {
        guard developerTestMode else { return }
        cancelInstall()
        simulatedRuntimeInstalled = false
        ModelCatalog.resetDeveloperTestModels()
        phase = .missing
    }

    private var developerTestMode: Bool {
        ProcessInfo.processInfo.environment["WHISPR_TEST_FIRST_RUN"] == "1"
    }

    private var developmentPythonURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["WHISPR_PYTHON"], isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        // Public builds leave this field empty, so a developer's absolute venv
        // path is never shipped. It is only used to drive local test mode.
        if let developmentPath = Bundle.main.object(forInfoDictionaryKey: "WhisprDevelopmentPythonPath") as? String,
           isExecutable(developmentPath) {
            return URL(fileURLWithPath: developmentPath)
        }
        return nil
    }

    private func installSimulatedRuntime() {
        guard developmentPythonURL != nil else {
            phase = .failed("Developer test mode needs WHISPR_PYTHON or a local development build.")
            return
        }
        phase = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            do {
                // Let the normal UI visibly pass through each installation
                // state, without network traffic or changing files on disk.
                try await Task.sleep(nanoseconds: 650_000_000)
                try Task.checkCancellation()
                self.phase = .installing
                try await Task.sleep(nanoseconds: 450_000_000)
                try Task.checkCancellation()
                self.simulatedRuntimeInstalled = true
                self.refresh()
            } catch is CancellationError {
                self.phase = .missing
            } catch {
                self.phase = .failed("Could not simulate the speech-engine install.")
            }
        }
    }

    private var runtimeArchiveURL: URL? {
        let value = ProcessInfo.processInfo.environment["WHISPR_RUNTIME_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "WhisprRuntimeURL") as? String
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private var expectedChecksum: String? {
        let value = ProcessInfo.processInfo.environment["WHISPR_RUNTIME_SHA256"]
            ?? Bundle.main.object(forInfoDictionaryKey: "WhisprRuntimeSHA256") as? String
        guard let value,
              value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return value.lowercased()
    }

    private var runtimeDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WhisprStream/Runtime", isDirectory: true)
    }

    private func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private enum RuntimeError: LocalizedError {
        case downloadFailed, checksumMismatch, invalidArchive, extractionFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "Could not download the speech engine."
            case .checksumMismatch: return "The downloaded speech engine did not pass verification."
            case .invalidArchive: return "The downloaded speech engine is incomplete."
            case .extractionFailed: return "Could not install the downloaded speech engine."
            }
        }
    }

    /// A staging directory makes interruption safe: the live runtime changes
    /// only once a complete, verified archive has been extracted.
    private static func installArchive(at archive: URL, expectedChecksum: String, destination: URL) throws {
        guard try sha256(of: archive) == expectedChecksum else { throw RuntimeError.checksumMismatch }

        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("Runtime.staging.\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RuntimeError.extractionFailed }

        // Release archives contain a single `runtime` directory. Reject a zip
        // with any other layout rather than searching for an arbitrary binary.
        let extracted = staging.appendingPathComponent("runtime", isDirectory: true)
        let python = extracted.appendingPathComponent("bin/python3.12")
        guard manager.isExecutableFile(atPath: python.path) else { throw RuntimeError.invalidArchive }

        let previous = parent.appendingPathComponent("Runtime.previous", isDirectory: true)
        try? manager.removeItem(at: previous)
        if manager.fileExists(atPath: destination.path) {
            try manager.moveItem(at: destination, to: previous)
        }
        do {
            try manager.moveItem(at: extracted, to: destination)
            try? manager.removeItem(at: previous)
        } catch {
            if manager.fileExists(atPath: previous.path), !manager.fileExists(atPath: destination.path) {
                try? manager.moveItem(at: previous, to: destination)
            }
            throw error
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
