import CryptoKit
import Foundation

struct RuntimeHealthError: Error {
    let message: String
}

struct RuntimeHealthCheck {
    static let timeout: TimeInterval = 20

    static func run(python: URL, manifest: RuntimeManifest) async -> Result<Void, RuntimeHealthError> {
        await Task.detached(priority: .utility) {
            runSynchronously(python: python, manifest: manifest)
        }.value
    }

    static func runSynchronously(python: URL, manifest: RuntimeManifest) -> Result<Void, RuntimeHealthError> {
        let expectedJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: manifest.dependencyVersions),
           let value = String(data: data, encoding: .utf8) {
            expectedJSON = value
        } else {
            return .failure(RuntimeHealthError(message: "The speech engine dependency manifest is invalid."))
        }

        let code = """
        import importlib, importlib.metadata, json, sys
        required = {"mlx": "mlx", "numpy": "numpy", "huggingface_hub": "huggingface-hub", "mlx_qwen3_asr": "mlx-qwen3-asr"}
        expected = \(expectedJSON)
        if tuple(sys.version_info[:2]) != (3, 12):
            raise RuntimeError("Python 3.12 is required")
        for module, distribution in required.items():
            importlib.import_module(module)
            if distribution in expected:
                actual = importlib.metadata.version(distribution)
                if actual != expected[distribution]:
                    raise RuntimeError(f"{distribution} {actual} does not match {expected[distribution]}")
        print(json.dumps({"status": "ok"}))
        """

        let process = Process()
        process.executableURL = python
        process.arguments = PythonProcessEnvironment.codeArguments(code)
        process.environment = PythonProcessEnvironment.sanitized()
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(RuntimeHealthError(message: "The speech engine could not be started: \(error.localizedDescription)"))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .failure(RuntimeHealthError(message: "The speech engine health check timed out."))
        }

        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(RuntimeHealthError(message: detail.isEmpty ? "The speech engine health check failed." : detail))
        }
        return .success(())
    }
}

/// Locates, verifies, and atomically installs the private speech engine.
@MainActor
final class RuntimeManager: ObservableObject {
    static let shared = RuntimeManager()

    enum Phase: Equatable {
        case ready
        case missing
        case checking
        case incompatible(String)
        case checkingStorage
        case insufficientStorage(required: Int64, available: Int64)
        case downloading
        case verifying
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .missing
    @Published private(set) var requiresRepairConfirmation = false

    private var installTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var healthCacheKey: String?
    private var simulatedRuntimeInstalled = false

    private init() { refresh() }

    var executableURL: URL? {
        if developerTestMode {
            guard simulatedRuntimeInstalled else { return nil }
            return developmentPythonURL
        }
        if let override = ProcessInfo.processInfo.environment["SPEEKIUM_PYTHON"], isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        let managed = runtimeDirectory.appendingPathComponent("bin/python3.12")
        return phase == .ready && isExecutable(managed.path) ? managed : developmentPythonURL
    }

    var isReady: Bool { executableURL != nil }
    var isDeveloperTestMode: Bool { developerTestMode }
    var isDeveloperTestModeAvailable: Bool { DeveloperTestMode.isAvailable }
    var isUsingDevelopmentEngine: Bool {
        guard !developerTestMode else { return false }
        if let override = ProcessInfo.processInfo.environment["SPEEKIUM_PYTHON"] {
            return isExecutable(override)
        }
        return isDevelopmentBuild && developmentPythonURL != nil
    }
    var canManageEngineInstallation: Bool {
        if developerTestMode { return true }
        guard !isUsingDevelopmentEngine else { return false }
        return runtimeArchiveURL != nil
            && expectedChecksum != nil
            && runtimeConfigurationVersion != nil
            && runtimeArchiveBytes != nil
            && runtimeInstalledBytes != nil
    }

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

    var storageSummary: String? {
        guard let archiveBytes = runtimeArchiveBytes, let installedBytes = runtimeInstalledBytes else { return nil }
        let available = StorageCapacity.availableBytes(at: runtimeDirectory)
            .map(StorageCapacity.formatted) ?? "Unavailable"
        return "Download: \(StorageCapacity.formatted(archiveBytes)) · installed: \(StorageCapacity.formatted(installedBytes)) · available: \(available)"
    }

    func refresh() {
        guard installTask == nil else { return }
        if developerTestMode {
            phase = simulatedRuntimeInstalled && developmentPythonURL != nil ? .ready : .missing
            return
        }
        if ProcessInfo.processInfo.environment["SPEEKIUM_PYTHON"].map(isExecutable) == true {
            phase = .ready
            return
        }
        if developmentPythonURL != nil && isDevelopmentBuild {
            phase = .ready
            return
        }
        if case .checking = phase { return }

        let manifestURL = runtimeDirectory.appendingPathComponent("manifest.json")
        guard FileManager.default.isExecutableFile(atPath: runtimeDirectory.appendingPathComponent("bin/python3.12").path) else {
            phase = FileManager.default.fileExists(atPath: runtimeDirectory.path) ? .incompatible("The installed speech engine is incomplete. Repair or reinstall it.") : .missing
            return
        }
        guard let manifest = Self.loadManifest(at: manifestURL) else {
            phase = .incompatible("This speech engine needs to be repaired or reinstalled.")
            return
        }
        if let problem = manifest.compatibilityError(requiredRuntimeVersion: requiredRuntimeVersion) {
            phase = .incompatible(problem)
            return
        }
        let cacheKey = "\(runtimeDirectory.path):\(manifest.runtimeVersion):\(manifest.payloadBytes)"
        if healthCacheKey == cacheKey {
            phase = .ready
            return
        }
        phase = .checking
        healthTask?.cancel()
        let python = runtimeDirectory.appendingPathComponent("bin/python3.12")
        healthTask = Task { [weak self] in
            let result = await RuntimeHealthCheck.run(python: python, manifest: manifest)
            guard !Task.isCancelled else { return }
            self?.healthTask = nil
            switch result {
            case .success:
                self?.healthCacheKey = cacheKey
                self?.phase = .ready
            case let .failure(error):
                self?.phase = .failed("Speech engine health check failed: \(error.message)")
            }
        }
    }

    /// Starts an install, or asks the caller to confirm replacement of a
    /// currently healthy engine. Models and preferences are never touched.
    func install() {
        // Local builds run from their prepared development environment and do
        // not contain a downloadable runtime archive. Never turn a healthy
        // development engine into an installer-configuration error.
        guard canManageEngineInstallation else {
            refresh()
            return
        }
        guard !isReady else {
            requiresRepairConfirmation = true
            return
        }
        beginInstall()
    }

    func confirmRepairInstall() {
        requiresRepairConfirmation = false
        beginInstall()
    }

    func cancelRepairConfirmation() {
        requiresRepairConfirmation = false
    }

    func cancelInstall() {
        guard case .installing = phase else {
            installTask?.cancel()
            installTask = nil
            refresh()
            return
        }
        // Atomic replacement is synchronous and is intentionally not cancellable.
    }

    /// Makes this process behave like a fresh install without changing real
    /// runtime, model, preference, or permission files.
    func resetDeveloperTestInstall() {
        guard developerTestMode else { return }
        cancelInstall()
        simulatedRuntimeInstalled = false
        ModelCatalog.resetDeveloperTestModels()
        phase = .missing
    }

    /// Enters the simulator without changing preferences, permissions, the
    /// managed runtime, or the real Hugging Face cache. This is available only
    /// in a local development build.
    func activateDeveloperTestMode() {
        guard DeveloperTestMode.isAvailable else { return }
        DeveloperTestMode.activate()
        resetDeveloperTestInstall()
        NotificationCenter.default.post(name: .speekiumDeveloperTestModeActivated, object: nil)
    }

    private func beginInstall() {
        guard installTask == nil else { return }
        if developerTestMode {
            installSimulatedRuntime()
            return
        }
        guard let archiveURL = runtimeArchiveURL, let checksum = expectedChecksum,
              let archiveBytes = runtimeArchiveBytes, let installedBytes = runtimeInstalledBytes,
              let runtimeVersion = runtimeConfigurationVersion else {
            phase = .failed("The speech-engine installer is not fully configured for this build.")
            return
        }
        guard archiveURL.scheme?.lowercased() == "https" else {
            phase = .failed("The speech-engine installer must use HTTPS.")
            return
        }
        phase = .checkingStorage
        guard let required = StorageCapacity.requiredBytes(archiveBytes, installedBytes),
              let available = StorageCapacity.availableBytes(at: runtimeDirectory) else {
            phase = .failed("Could not determine available storage for the speech engine.")
            return
        }
        guard available >= required else {
            phase = .insufficientStorage(required: required, available: available)
            return
        }

        phase = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            var candidateInstalled = false
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: archiveURL)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode) else {
                    throw RuntimeError.downloadFailed
                }
                self.phase = .verifying
                let currentAvailable = StorageCapacity.availableBytes(at: self.runtimeDirectory) ?? 0
                guard currentAvailable >= required else {
                    throw RuntimeError.insufficientStorage(required: required, available: currentAvailable)
                }
                try Self.installArchive(
                    at: temporaryURL,
                    expectedChecksum: checksum,
                    destination: self.runtimeDirectory,
                    requiredRuntimeVersion: runtimeVersion
                )
                candidateInstalled = true
                self.phase = .installing
                let manifestURL = self.runtimeDirectory.appendingPathComponent("manifest.json")
                guard let manifest = Self.loadManifest(at: manifestURL),
                      manifest.runtimeVersion == runtimeVersion else {
                    throw RuntimeError.invalidArchive
                }
                switch await RuntimeHealthCheck.run(
                    python: self.runtimeDirectory.appendingPathComponent("bin/python3.12"),
                    manifest: manifest
                ) {
                case .success:
                    Self.finalizeInstalledRuntime(at: self.runtimeDirectory)
                    self.healthCacheKey = "\(self.runtimeDirectory.path):\(manifest.runtimeVersion):\(manifest.payloadBytes)"
                    self.phase = .ready
                    Log.write("runtime installed at \(self.runtimeDirectory.path)")
                case let .failure(error):
                    Self.rollbackInstalledRuntime(at: self.runtimeDirectory)
                    self.phase = .failed("Speech engine health check failed: \(error.message)")
                }
            } catch is CancellationError {
                self.phase = .missing
            } catch let RuntimeError.insufficientStorage(required, available) {
                if candidateInstalled { Self.rollbackInstalledRuntime(at: self.runtimeDirectory) }
                self.phase = .insufficientStorage(required: required, available: available)
            } catch {
                if candidateInstalled { Self.rollbackInstalledRuntime(at: self.runtimeDirectory) }
                Log.write("runtime install failed: \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func installSimulatedRuntime() {
        guard developmentPythonURL != nil else {
            phase = .failed("Developer test mode needs SPEEKIUM_PYTHON or a local development build.")
            return
        }
        phase = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            do {
                try await Task.sleep(nanoseconds: 650_000_000)
                try Task.checkCancellation()
                self.phase = .installing
                try await Task.sleep(nanoseconds: 450_000_000)
                try Task.checkCancellation()
                self.simulatedRuntimeInstalled = true
                // refresh() intentionally ignores calls while an install task
                // is active. Finish the simulated transition explicitly so it
                // cannot remain stuck in `.installing` until another refresh.
                self.phase = .ready
            } catch is CancellationError {
                self.phase = .missing
            } catch {
                self.phase = .failed("Could not simulate the speech-engine install.")
            }
        }
    }

    private var developerTestMode: Bool {
        DeveloperTestMode.isEnabled
    }

    private var isDevelopmentBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String ?? "").hasPrefix("dev.")
    }

    private var developmentPythonURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SPEEKIUM_PYTHON"], isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        if let developmentPath = Bundle.main.object(forInfoDictionaryKey: "SpeekiumDevelopmentPythonPath") as? String,
           isExecutable(developmentPath) {
            return URL(fileURLWithPath: developmentPath)
        }
        return nil
    }

    private var runtimeArchiveURL: URL? {
        let value = ProcessInfo.processInfo.environment["SPEEKIUM_RUNTIME_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SpeekiumRuntimeURL") as? String
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private var expectedChecksum: String? {
        let value = ProcessInfo.processInfo.environment["SPEEKIUM_RUNTIME_SHA256"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SpeekiumRuntimeSHA256") as? String
        guard let value,
              value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return nil }
        return value.lowercased()
    }

    private var runtimeConfigurationVersion: String? {
        let value = ProcessInfo.processInfo.environment["SPEEKIUM_RUNTIME_VERSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SpeekiumRuntimeVersion") as? String
        return value?.isEmpty == false ? value : nil
    }

    private var requiredRuntimeVersion: String { runtimeConfigurationVersion ?? "1.0.0" }

    private var runtimeArchiveBytes: Int64? { configurationBytes("SpeekiumRuntimeArchiveBytes") }
    private var runtimeInstalledBytes: Int64? { configurationBytes("SpeekiumRuntimeInstalledBytes") }

    private func configurationBytes(_ key: String) -> Int64? {
        let environmentKey: String
        switch key {
        case "SpeekiumRuntimeArchiveBytes": environmentKey = "SPEEKIUM_RUNTIME_ARCHIVE_BYTES"
        case "SpeekiumRuntimeInstalledBytes": environmentKey = "SPEEKIUM_RUNTIME_INSTALLED_BYTES"
        default: environmentKey = ""
        }
        let value = (environmentKey.isEmpty ? nil : ProcessInfo.processInfo.environment[environmentKey])
            ?? Bundle.main.object(forInfoDictionaryKey: key) as? String
        guard let value, let bytes = Int64(value), bytes > 0 else { return nil }
        return bytes
    }

    private var runtimeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SPEEKIUM_RUNTIME_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Speekium/Runtime", isDirectory: true)
    }

    private func isExecutable(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }

    private enum RuntimeError: LocalizedError {
        case downloadFailed
        case checksumMismatch
        case invalidArchive
        case extractionFailed
        case insufficientStorage(required: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "Could not download the speech engine."
            case .checksumMismatch: return "The downloaded speech engine did not pass verification."
            case .invalidArchive: return "The downloaded speech engine is incomplete or incompatible."
            case .extractionFailed: return "Could not install the downloaded speech engine."
            case let .insufficientStorage(required, available):
                return "Not enough storage: \(StorageCapacity.formatted(required)) required, \(StorageCapacity.formatted(available)) available."
            }
        }
    }

    private static func loadManifest(at url: URL) -> RuntimeManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    /// A staging directory makes interruption safe: the live runtime changes
    /// only after checksum, layout, manifest, and compatibility validation.
    static func installArchive(
        at archive: URL,
        expectedChecksum: String,
        destination: URL,
        requiredRuntimeVersion: String
    ) throws {
        guard try sha256(of: archive) == expectedChecksum.lowercased() else { throw RuntimeError.checksumMismatch }

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

        let topLevel = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard topLevel.count == 1, topLevel.first?.lastPathComponent == "runtime" else {
            throw RuntimeError.invalidArchive
        }
        let extracted = staging.appendingPathComponent("runtime", isDirectory: true)
        let python = extracted.appendingPathComponent("bin/python3.12")
        guard manager.isExecutableFile(atPath: python.path),
              let manifest = loadManifest(at: extracted.appendingPathComponent("manifest.json")),
              manifest.compatibilityError(requiredRuntimeVersion: requiredRuntimeVersion) == nil else {
            throw RuntimeError.invalidArchive
        }

        let previous = parent.appendingPathComponent("Runtime.previous", isDirectory: true)
        try? manager.removeItem(at: previous)
        if manager.fileExists(atPath: destination.path) {
            try manager.moveItem(at: destination, to: previous)
        }
        do {
            try manager.moveItem(at: extracted, to: destination)
        } catch {
            if manager.fileExists(atPath: previous.path), !manager.fileExists(atPath: destination.path) {
                try? manager.moveItem(at: previous, to: destination)
            }
            throw error
        }
    }

    private static func finalizeInstalledRuntime(at destination: URL) {
        let previous = destination.deletingLastPathComponent().appendingPathComponent("Runtime.previous", isDirectory: true)
        try? FileManager.default.removeItem(at: previous)
    }

    private static func rollbackInstalledRuntime(at destination: URL) {
        let manager = FileManager.default
        let previous = destination.deletingLastPathComponent().appendingPathComponent("Runtime.previous", isDirectory: true)
        try? manager.removeItem(at: destination)
        if manager.fileExists(atPath: previous.path) {
            try? manager.moveItem(at: previous, to: destination)
        }
    }

    static func sha256(of file: URL) throws -> String {
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
