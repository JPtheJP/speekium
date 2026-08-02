import Foundation

/// Drives the Python ASR sidecar over newline-delimited JSON.
///
/// The model load is expensive (~0.9s) and must happen exactly once, so the
/// process is started at launch and kept alive for the lifetime of the app.
final class ASRService {
    enum Event {
        case ready(ms: Int)
        case partial(committed: String, tail: String)
        case final(text: String, secs: Double, ms: Int)
        case error(String)
    }

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var buffer = Data()
    private let queue = DispatchQueue(label: "asr.stdout")

    var onEvent: ((Event) -> Void)?

    init(python: URL, script: URL, model: String, bits: Int, context: String) {
        process.executableURL = python
        process.arguments = [script.path]
        process.standardInput = inPipe
        process.standardOutput = outPipe
        // Keep stderr: without it a failing sidecar is silent and undebuggable.
        process.standardError = ASRService.makeLogHandle() ?? FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["WHISPR_MODEL"] = model
        env["WHISPR_BITS"] = String(bits)
        env["WHISPR_CONTEXT"] = context
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
    }

    /// ~/Library/Logs/WhisprStream.log — where sidecar stderr goes.
    static var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WhisprStream.log")
    }

    private static func makeLogHandle() -> FileHandle? {
        let url = logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    func start() throws {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.ingest(data) }
        }
        try process.run()
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

            let event: Event
            switch type {
            case "ready":
                event = .ready(ms: obj["ms"] as? Int ?? 0)
            case "partial":
                event = .partial(
                    committed: obj["committed"] as? String ?? "",
                    tail: obj["tail"] as? String ?? ""
                )
            case "final":
                event = .final(
                    text: obj["text"] as? String ?? "",
                    secs: obj["secs"] as? Double ?? 0,
                    ms: obj["ms"] as? Int ?? 0
                )
            default:
                event = .error(obj["message"] as? String ?? "unknown")
            }
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }

    private func send(_ dict: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A)
        inPipe.fileHandleForWriting.write(data)
    }

    func beginUtterance() { send(["cmd": "start"]) }
    func stopUtterance() { send(["cmd": "stop"]) }

    /// Push edited vocabulary to the resident sidecar. The model is not reloaded,
    /// so this is cheap enough to call on every keystroke in Settings.
    func setContext(_ terms: String) { send(["cmd": "context", "text": terms]) }

    /// `pcm` must be mono 16 kHz signed 16-bit.
    func sendAudio(_ pcm: Data) {
        send(["cmd": "audio", "pcm": pcm.base64EncodedString()])
    }

    func shutdown() {
        send(["cmd": "quit"])
        process.terminate()
    }
}
