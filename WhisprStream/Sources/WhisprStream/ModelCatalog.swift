import Foundation

/// The speech models this app can run.
///
/// Deliberately a closed list rather than a free-text field: these are the two
/// ids `mlx-qwen3-asr` names itself (`DEFAULT_MODEL_ID` / `ACCURACY_MODEL_ID`),
/// and they are the only ones known to handle zh/en code-switching the way this
/// app depends on.
enum ASRModel: String, CaseIterable, Identifiable {
    case small = "Qwen/Qwen3-ASR-0.6B"
    case large = "Qwen/Qwen3-ASR-1.7B"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Qwen3-ASR 0.6B"
        case .large: return "Qwen3-ASR 1.7B"
        }
    }

    var detail: String {
        switch self {
        case .small:
            return "The default. Transcribes a 12-second utterance in about 0.3 s, which is what makes the live preview feel instant."
        case .large:
            return "Roughly three times the compute. May read harder audio better, but every live pass costs proportionally more — unmeasured on your voice."
        }
    }

    /// Rough on-disk size, for the download button. The real total comes from
    /// the Hub at download time; this is only to set expectations beforehand.
    var approximateSize: String {
        switch self {
        case .small: return "~1.2 GB"
        case .large: return "~4 GB"
        }
    }

    /// `Qwen/Qwen3-ASR-0.6B` -> `models--Qwen--Qwen3-ASR-0.6B`
    var cacheFolderName: String {
        "models--" + rawValue.replacingOccurrences(of: "/", with: "--")
    }
}

enum ModelInstallState: Equatable {
    case installed
    /// Some weights fetched but the snapshot is unusable — the Xet stall leaves
    /// exactly this: a multi-GB `.incomplete` blob and a missing shard.
    case partial(bytes: Int64)
    case missing

    var isInstalled: Bool { self == .installed }
}

/// Reads the Hugging Face cache to decide whether a model can actually load.
///
/// Presence of the folder proves nothing — the 1.7B sat at 3.6 GB for weeks with
/// its first shard missing. A model counts as installed only when every weight
/// file its index references is on disk.
enum ModelCatalog {
    /// Shared with RuntimeManager's local first-run simulator. This state is
    /// process-only: developer testing never hides, deletes, or creates a real
    /// Hugging Face cache entry.
    static var isDeveloperTestMode: Bool {
        ProcessInfo.processInfo.environment["WHISPR_TEST_FIRST_RUN"] == "1"
    }
    private static var simulatedInstalledModels = Set<ASRModel>()

    static func markDeveloperTestInstalled(_ model: ASRModel) {
        guard isDeveloperTestMode else { return }
        simulatedInstalledModels.insert(model)
    }

    static func resetDeveloperTestModels() {
        simulatedInstalledModels.removeAll()
    }

    /// Honours the same environment variables `huggingface_hub` does, so a user
    /// with a relocated cache isn't told their models are missing.
    static var cacheRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let hubCache = env["HF_HUB_CACHE"], !hubCache.isEmpty {
            return URL(fileURLWithPath: (hubCache as NSString).expandingTildeInPath)
        }
        if let home = env["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
                .appendingPathComponent("hub")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub")
    }

    static func state(for model: ASRModel) -> ModelInstallState {
        if isDeveloperTestMode {
            return simulatedInstalledModels.contains(model) ? .installed : .missing
        }
        let fm = FileManager.default
        let repo = cacheRoot.appendingPathComponent(model.cacheFolderName)
        guard fm.fileExists(atPath: repo.path) else { return .missing }

        let snapshots = repo.appendingPathComponent("snapshots")
        let revisions = (try? fm.contentsOfDirectory(at: snapshots,
                                                     includingPropertiesForKeys: nil)) ?? []
        for revision in revisions where isComplete(revision) {
            return .installed
        }
        return .partial(bytes: downloadedBytes(in: repo))
    }

    /// A snapshot is usable when its weights are all present.
    ///
    /// 0.6B ships one `model.safetensors`; 1.7B is sharded and ships an index
    /// naming each shard, so both layouts have to be handled.
    private static func isComplete(_ snapshot: URL) -> Bool {
        let fm = FileManager.default
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")

        if fm.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = root["weight_map"] as? [String: String]
            else { return false }
            for shard in Set(map.values) {
                // resolvingSymlinksInPath: cache entries are symlinks into blobs/,
                // and a dangling link is exactly what a stalled download leaves.
                let file = snapshot.appendingPathComponent(shard).resolvingSymlinksInPath()
                guard fm.fileExists(atPath: file.path) else { return false }
            }
            return true
        }

        let single = snapshot.appendingPathComponent("model.safetensors").resolvingSymlinksInPath()
        return fm.fileExists(atPath: single.path)
    }

    /// Bytes already fetched, including partially-written blobs, so a resume can
    /// tell the user how far along it is.
    private static func downloadedBytes(in repo: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: repo.appendingPathComponent("blobs"),
                                         includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    static func formatted(bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
