import Foundation

struct ModelPreflight: Codable, Equatable {
    let model: String
    let totalBytes: Int64
    let availableBytes: Int64
    let incompleteBytes: Int64
    let reusableBytes: Int64
    let requiredBytes: Int64
    let cacheRoot: String
}

/// Runs model metadata checks and downloads through the private runtime.
@MainActor
final class ModelDownloader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case awaitingCleanup
        case downloading
        case cleaning
    }

    @Published private(set) var active: ASRModel?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var preflight: ModelPreflight?
    @Published private(set) var failure: String?
    @Published private(set) var cleanupPrompt: ASRModel?

    var fraction: Double? {
        guard total > 0 else { return nil }
        return max(0, min(1.0, Double(received) / Double(total)))
    }

    var isRunning: Bool { active != nil }
    var isDownloading: Bool { phase == .downloading }
    var cleanupWillContinueDownload: Bool { continueAfterCleanup }

    private enum ProcessMode { case preflight, cleanup, download }
    private var process: Process?
    private var processMode: ProcessMode?
    private var buffer = Data()
    private var simulationTask: Task<Void, Never>?
    private var continueAfterCleanup = false

    var onFinish: ((ASRModel, Bool) -> Void)?

    func start(_ model: ASRModel) {
        guard active == nil else { return }
        guard FeatureFlags.optionalModelsEnabled || model.isBuiltIn else {
            failure = "Custom speech models are not available in this version of WhisprStream."
            return
        }
        guard !ModelCatalog.state(for: model).isInstalled else { return }
        guard model.isDownloadable else {
            failure = "The selected local model folder is unavailable."
            return
        }

        if ModelCatalog.isDeveloperTestMode {
            Log.write("model: developer simulation started for " + model.rawValue)
            startDeveloperSimulation(model)
            return
        }

        Log.write("model: real download started for " + model.rawValue)

        guard let script = Bundle.main.url(forResource: "model_download", withExtension: "py") else {
            failure = "model_download.py missing from the app bundle"
            return
        }
        guard let python = RuntimeManager.shared.executableURL else {
            failure = "The speech engine is not installed"
            return
        }

        active = model
        phase = .checking
        received = 0
        total = 0
        preflight = nil
        failure = nil
        cleanupPrompt = nil
        continueAfterCleanup = false
        runProcess(
            python: python,
            script: script,
            arguments: operationArguments("--preflight", model: model),
            mode: .preflight
        )
    }

    func downloadAnyway() {
        guard let model = active, phase == .awaitingCleanup else { return }
        guard let preflight, preflight.availableBytes >= preflight.requiredBytes else {
            failure = "Not enough storage for the speech model."
            cancel()
            return
        }
        startDownload(model)
    }

    func requestCleanup() {
        guard phase == .awaitingCleanup, let active else { return }
        cleanupPrompt = active
    }

    /// Opens the same scoped cleanup flow from Settings without starting a
    /// network request first.
    func requestCleanup(for model: ASRModel) {
        guard FeatureFlags.optionalModelsEnabled || model.isBuiltIn else { return }
        guard active == nil, ModelCatalog.incompleteBytes(for: model) > 0 else { return }
        active = model
        phase = .awaitingCleanup
        cleanupPrompt = model
        continueAfterCleanup = false
    }

    func dismissCleanupPrompt() {
        cleanupPrompt = nil
    }

    func removeIncompleteDownload() {
        guard let model = cleanupPrompt ?? active, phase == .awaitingCleanup else { return }
        cleanupPrompt = nil
        guard let script = Bundle.main.url(forResource: "model_download", withExtension: "py"),
              let python = RuntimeManager.shared.executableURL else {
            failure = "The speech engine is not installed"
            return
        }
        phase = .cleaning
        failure = nil
        runProcess(
            python: python,
            script: script,
            arguments: operationArguments("--cleanup", model: model),
            mode: .cleanup
        )
    }

    func cancel() {
        simulationTask?.cancel()
        simulationTask = nil
        process?.terminate()
        process = nil
        processMode = nil
        cleanupPrompt = nil
        continueAfterCleanup = false
        active = nil
        phase = .idle
    }

    private func startDownload(_ model: ASRModel) {
        guard let script = Bundle.main.url(forResource: "model_download", withExtension: "py"),
              let python = RuntimeManager.shared.executableURL else {
            failure = "The speech engine is not installed"
            cancel()
            return
        }
        phase = .downloading
        buffer = Data()
        runProcess(
            python: python,
            script: script,
            arguments: operationArguments("--download", model: model),
            mode: .download
        )
    }

    private func runProcess(
        python: URL,
        script: URL,
        arguments: [String],
        mode: ProcessMode
    ) {
        let proc = Process()
        proc.executableURL = python
        proc.arguments = PythonProcessEnvironment.scriptArguments(script: script, arguments: arguments)
        proc.environment = PythonProcessEnvironment.sanitized()

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        processMode = mode
        process = proc
        buffer = Data()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }
        proc.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.finishProcess(ok: process.terminationStatus == 0)
            }
        }

        do {
            try proc.run()
        } catch {
            process = nil
            processMode = nil
            active = nil
            phase = .idle
            failure = "Could not start the model operation"
        }
    }

    private func startDeveloperSimulation(_ model: ASRModel) {
        active = model
        phase = .downloading
        received = 0
        total = 100
        failure = nil
        simulationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.simulationTask = nil }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                try Task.checkCancellation()
                self.received = 62
                try await Task.sleep(nanoseconds: 650_000_000)
                try Task.checkCancellation()
                ModelCatalog.markDeveloperTestInstalled(model)
                self.received = self.total
                self.finish(ok: true)
            } catch is CancellationError {
                // cancel() already restored the idle state.
            } catch {
                self.finish(ok: false)
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }

            switch type {
            case "preflight":
                preflight = Self.decodePreflight(object)
                if let preflight {
                    total = preflight.totalBytes
                    received = min(preflight.totalBytes, max(0, preflight.reusableBytes))
                }
            case "total":
                total = (object["bytes"] as? NSNumber)?.int64Value ?? 0
            case "progress":
                received = (object["bytes"] as? NSNumber)?.int64Value ?? received
                if let value = (object["total"] as? NSNumber)?.int64Value, value > 0 { total = value }
            case "error":
                let category = object["category"] as? String
                let message = object["message"] as? String ?? "Model operation failed"
                failure = category == "metadata"
                    ? "Could not check model information. Check your connection and try again."
                    : message
            case "cleanup":
                let bytes = (object["removedBytes"] as? NSNumber)?.int64Value ?? 0
                let files = (object["files"] as? [String]) ?? []
                Log.write("removed incomplete model data: files=\(files.joined(separator: ",")) bytes=\(bytes)")
            default:
                break
            }
        }
    }

    private func finishProcess(ok: Bool) {
        // A final short line can arrive immediately before termination.
        if !buffer.isEmpty {
            var remainder = buffer
            remainder.append(0x0A)
            buffer = Data()
            ingest(remainder)
        }
        let mode = processMode
        process = nil
        processMode = nil

        guard let model = active else { return }
        switch mode {
        case .preflight:
            guard ok, let preflight else {
                if failure == nil { failure = "Could not check model information. Check your connection and try again." }
                active = nil
                phase = .idle
                return
            }
            guard preflight.availableBytes >= preflight.requiredBytes else {
                failure = "Not enough storage: \(StorageCapacity.formatted(preflight.requiredBytes)) required, \(StorageCapacity.formatted(preflight.availableBytes)) available."
                active = nil
                phase = .idle
                return
            }
            if preflight.incompleteBytes > 0 {
                continueAfterCleanup = true
                phase = .awaitingCleanup
            } else {
                startDownload(model)
            }
        case .cleanup:
            guard ok else {
                if failure == nil { failure = "Could not clear the partial model data." }
                phase = .awaitingCleanup
                return
            }
            guard continueAfterCleanup else {
                active = nil
                phase = .idle
                onFinish?(model, ModelCatalog.state(for: model).isInstalled)
                return
            }
            continueAfterCleanup = false
            // Re-run both the install-state and capacity checks before the
            // download that the user already chose to continue.
            preflight = nil
            phase = .checking
            guard let script = Bundle.main.url(forResource: "model_download", withExtension: "py"),
                  let python = RuntimeManager.shared.executableURL else {
                failure = "The speech engine is not installed"
                active = nil
                phase = .idle
                return
            }
            runProcess(
                python: python,
                script: script,
                arguments: operationArguments("--preflight", model: model),
                mode: .preflight
            )
        case .download:
            finish(ok: ok)
        case .none:
            break
        }
    }

    private func finish(ok: Bool) {
        let model = active
        active = nil
        phase = .idle
        if let model {
            let installed = ok && ModelCatalog.state(for: model).isInstalled
            let operation = ModelCatalog.isDeveloperTestMode ? "developer simulation" : "download"
            let result = installed ? "finished" : "failed"
            Log.write("model: " + operation + " " + result + " for " + model.rawValue)
            if !installed && failure == nil {
                failure = ok ? "The model download finished but the model is incomplete." : "Download did not complete."
            }
            onFinish?(model, installed)
        }
    }

    private static func decodePreflight(_ object: [String: Any]) -> ModelPreflight? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ModelPreflight.self, from: data)
    }

    private func operationArguments(_ operation: String, model: ASRModel) -> [String] {
        [operation, model.rawValue, model.engine.rawValue]
    }
}
