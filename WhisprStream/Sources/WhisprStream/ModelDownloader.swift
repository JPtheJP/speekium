import Foundation

/// Runs `model_download.py` and publishes its progress.
///
/// Downloading is delegated to Python for one reason: `huggingface_hub` owns the
/// cache layout — blob hashing, symlinked snapshots, resume state — and a
/// hand-rolled Swift fetch would have to reproduce all of it exactly or produce
/// a tree the loader can't read.
@MainActor
final class ModelDownloader: ObservableObject {
    @Published private(set) var active: ASRModel?
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var failure: String?

    /// Nil until the Hub reports a total, which keeps the bar indeterminate
    /// rather than showing a confident but wrong 0 %.
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1.0, Double(received) / Double(total))
    }

    var isRunning: Bool { active != nil }

    private var process: Process?
    private var buffer = Data()
    private var simulationTask: Task<Void, Never>?

    /// Called when a download finishes, so the UI can re-check install state.
    var onFinish: ((ASRModel, Bool) -> Void)?

    func start(_ model: ASRModel) {
        guard active == nil else { return }

        if ModelCatalog.isDeveloperTestMode {
            startDeveloperSimulation(model)
            return
        }

        guard let script = Bundle.main.url(forResource: "model_download", withExtension: "py") else {
            failure = "model_download.py missing from the app bundle"
            return
        }
        guard let python = RuntimeManager.shared.executableURL else {
            failure = "The speech engine is not installed"
            return
        }

        active = model
        received = 0
        total = 0
        failure = nil
        buffer = Data()

        let proc = Process()
        proc.executableURL = python
        proc.arguments = [script.path, model.rawValue]
        var childEnv = ProcessInfo.processInfo.environment
        childEnv["PYTHONUNBUFFERED"] = "1"
        proc.environment = childEnv

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in self?.finish(ok: p.terminationStatus == 0) }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            active = nil
            failure = "Could not start the download"
        }
    }

    func cancel() {
        simulationTask?.cancel()
        simulationTask = nil
        process?.terminate()
        process = nil
        active = nil
    }

    private func startDeveloperSimulation(_ model: ASRModel) {
        active = model
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
                // `cancel()` has already restored the idle state.
            } catch {
                self.finish(ok: false)
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = buffer[buffer.index(after: nl)...]
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "total":
                total = (obj["bytes"] as? NSNumber)?.int64Value ?? 0
            case "progress":
                received = (obj["bytes"] as? NSNumber)?.int64Value ?? received
                if let t = (obj["total"] as? NSNumber)?.int64Value, t > 0 { total = t }
            case "error":
                failure = obj["message"] as? String ?? "Download failed"
            default:
                break
            }
        }
    }

    private func finish(ok: Bool) {
        let model = active
        process = nil
        active = nil
        if let model {
            // A non-zero exit with no parsed message still needs to say something.
            if !ok && failure == nil { failure = "Download did not complete" }
            onFinish?(model, ok && failure == nil)
        }
    }
}
