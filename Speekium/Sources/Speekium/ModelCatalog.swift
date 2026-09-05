import Foundation

/// Runtime adapters that expose the common transcription interface used by the
/// sidecar. A model repository must match its adapter; a Hugging Face id alone
/// is not enough to determine how arbitrary weights should be executed.
enum ASREngine: String, CaseIterable, Codable, Identifiable {
    case qwen3
    case whisper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .qwen3: return "Qwen3-ASR"
        case .whisper: return "Whisper (MLX)"
        }
    }

    var detail: String {
        switch self {
        case .qwen3:
            return "For full Qwen3-ASR checkpoints and compatible fine-tunes."
        case .whisper:
            return "For Whisper models converted to MLX format."
        }
    }
}

enum ASRModelSource: String, CaseIterable, Codable, Identifiable {
    case huggingFace
    case local

    var id: String { rawValue }

    var label: String {
        switch self {
        case .huggingFace: return "Hugging Face"
        case .local: return "Local folder"
        }
    }
}

/// One selectable speech model. Built-ins and user-added models use the same
/// value type so switching either one follows exactly the same restart path.
struct ASRModel: Codable, Hashable, Identifiable, CaseIterable {
    let engine: ASREngine
    let source: ASRModelSource
    let location: String

    static let small = ASRModel(
        engine: .qwen3,
        source: .huggingFace,
        location: "Qwen/Qwen3-ASR-0.6B"
    )
    static let large = ASRModel(
        engine: .qwen3,
        source: .huggingFace,
        location: "Qwen/Qwen3-ASR-1.7B"
    )
    static let allCases: [ASRModel] = [.small, .large]

    /// Compatibility with the original enum-backed preference and call sites.
    init?(rawValue: String) {
        guard let builtIn = Self.allCases.first(where: { $0.location == rawValue }) else {
            return nil
        }
        self = builtIn
    }

    init(engine: ASREngine, source: ASRModelSource, location: String) {
        self.engine = engine
        self.source = source
        self.location = location
    }

    var rawValue: String { location }
    var id: String { "\(engine.rawValue):\(source.rawValue):\(location)" }
    var isBuiltIn: Bool { Self.allCases.contains(self) }
    var isDownloadable: Bool { source == .huggingFace }

    var label: String {
        if self == .small { return "Qwen3-ASR 0.6B" }
        if self == .large { return "Qwen3-ASR 1.7B" }
        let component = source == .local
            ? URL(fileURLWithPath: location).lastPathComponent
            : location.split(separator: "/").last.map(String.init) ?? location
        return component.isEmpty ? location : component
    }

    var detail: String {
        if self == .small {
            return "The fastest, broadest-compatible option for most Macs."
        }
        if self == .large {
            return "Larger and slower; may improve difficult audio. Best with 16 GB or more unified memory."
        }
        return "\(engine.label) · \(location)"
    }

    /// Rough on-disk size for built-ins. Custom repositories are measured by
    /// the Hub preflight before their download begins.
    var approximateSize: String {
        if self == .small { return "~1.9 GB" }
        if self == .large { return "~4.3 GB" }
        return source == .local ? "Local folder" : "Size checked before download"
    }

    /// `owner/model` -> `models--owner--model`
    var cacheFolderName: String? {
        guard source == .huggingFace else { return nil }
        return "models--" + location.replacingOccurrences(of: "/", with: "--")
    }

    var localURL: URL? {
        guard source == .local else { return nil }
        return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
            .standardizedFileURL
    }
}

enum ASRModelValidationError: LocalizedError, Equatable {
    case optionalModelsUnavailable
    case invalidRepository
    case invalidLocalPath
    case incompatibleLocalModel(ASREngine)

    var errorDescription: String? {
        switch self {
        case .optionalModelsUnavailable:
            return "Custom speech models are not available in this version of Speekium."
        case .invalidRepository:
            return "Enter a Hugging Face model id in owner/model format."
        case .invalidLocalPath:
            return "Choose an existing local model folder."
        case let .incompatibleLocalModel(engine):
            switch engine {
            case .qwen3:
                return "That folder is not a complete Qwen3-ASR model. It needs a qwen3_asr config.json and all model safetensors."
            case .whisper:
                return "That folder is not an MLX Whisper model. It needs a whisper config.json and model.safetensors, weights.safetensors, or weights.npz."
            }
        }
    }
}

enum ModelInstallState: Equatable {
    case installed
    /// Some weights fetched but the snapshot is unusable — an interrupted Hub
    /// transfer can leave multi-GB `.incomplete` blobs behind.
    case partial(bytes: Int64)
    case missing

    var isInstalled: Bool { self == .installed }
}

/// Reads local folders and the Hugging Face cache to decide whether a model can
/// actually load. Presence of a repository folder alone is never sufficient.
enum ModelCatalog {
    /// Shared with RuntimeManager's local first-run simulator. This state is
    /// process-only: developer testing never hides, deletes, or creates a real
    /// Hugging Face cache entry.
    static var isDeveloperTestMode: Bool {
        DeveloperTestMode.isEnabled
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

        if let local = model.localURL {
            return isComplete(local, for: model.engine) ? .installed : .missing
        }

        guard let cacheFolderName = model.cacheFolderName else { return .missing }
        let fm = FileManager.default
        let repo = cacheRoot.appendingPathComponent(cacheFolderName)
        guard fm.fileExists(atPath: repo.path) else { return .missing }

        let snapshots = repo.appendingPathComponent("snapshots")
        let revisions = (try? fm.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil
        )) ?? []
        for revision in revisions where isComplete(revision, for: model.engine) {
            return .installed
        }
        return .partial(bytes: downloadedBytes(in: repo))
    }

    static func validatedCustomModel(
        engine: ASREngine,
        source: ASRModelSource,
        location rawLocation: String
    ) throws -> ASRModel {
        guard FeatureFlags.optionalModelsEnabled else {
            throw ASRModelValidationError.optionalModelsUnavailable
        }
        let trimmed = rawLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .huggingFace:
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            guard parts.count == 2,
                  parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
            else { throw ASRModelValidationError.invalidRepository }
            return ASRModel(engine: engine, source: source, location: trimmed)
        case .local:
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard url.path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ASRModelValidationError.invalidLocalPath
            }
            let model = ASRModel(engine: engine, source: source, location: url.path)
            guard state(for: model).isInstalled else {
                throw ASRModelValidationError.incompatibleLocalModel(engine)
            }
            return model
        }
    }

    static func incompleteBytes(for model: ASRModel) -> Int64 {
        guard let cacheFolderName = model.cacheFolderName else { return 0 }
        let blobs = cacheRoot
            .appendingPathComponent(cacheFolderName)
            .appendingPathComponent("blobs")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.reduce(into: Int64(0)) { total, file in
            guard file.lastPathComponent.hasSuffix(".incomplete"),
                  let values = try? file.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size >= 0 else { return }
            total += Int64(size)
        }
    }

    private static func existingFile(_ folder: URL, named name: String) -> Bool {
        let root = folder.standardizedFileURL.path + "/"
        let candidate = folder.appendingPathComponent(name).standardizedFileURL
        // An index is downloaded data. It may name a legitimate cache symlink,
        // but its lexical path must stay inside the selected snapshot/folder.
        guard candidate.path.hasPrefix(root) else { return false }
        let resolved = candidate.resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: resolved.path)
    }

    private static func isComplete(_ folder: URL, for engine: ASREngine) -> Bool {
        guard hasCompatibleConfig(in: folder, for: engine) else { return false }
        switch engine {
        case .qwen3:
            return hasCompleteSafetensors(in: folder)
        case .whisper:
            return existingFile(folder, named: "model.safetensors")
                || existingFile(folder, named: "weights.safetensors")
                || existingFile(folder, named: "weights.npz")
        }
    }

    /// Both adapters can use a file named `model.safetensors`; the model type
    /// in config.json is what keeps a Whisper checkpoint from being offered to
    /// the Qwen loader (and vice versa).
    private static func hasCompatibleConfig(in folder: URL, for engine: ASREngine) -> Bool {
        let config = folder.appendingPathComponent("config.json")
        guard existingFile(folder, named: "config.json"),
              let data = try? Data(contentsOf: config.resolvingSymlinksInPath()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = object["model_type"] as? String else {
            return false
        }
        switch engine {
        case .qwen3: return modelType == "qwen3_asr"
        case .whisper: return modelType == "whisper"
        }
    }

    /// Handles both single-file and indexed/sharded safetensor layouts.
    private static func hasCompleteSafetensors(in folder: URL) -> Bool {
        let fm = FileManager.default
        let index = folder.appendingPathComponent("model.safetensors.index.json")
        if fm.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = root["weight_map"] as? [String: String]
            else { return false }
            return Set(map.values).allSatisfy { existingFile(folder, named: $0) }
        }
        return existingFile(folder, named: "model.safetensors")
    }

    /// Bytes already fetched, including partially-written blobs, so cleanup can
    /// explain how much unused storage an interrupted transfer occupies.
    private static func downloadedBytes(in repo: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: repo.appendingPathComponent("blobs"),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    static func formatted(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static var hardwareGuidance: String {
        let sixteenGB = 16 * 1024 * 1024 * 1024
        if ProcessInfo.processInfo.physicalMemory < UInt64(sixteenGB) {
            return "Larger models are allowed on this Mac, but they may create memory pressure and respond more slowly."
        }
        if FeatureFlags.optionalModelsEnabled {
            return "The 0.6B model is the faster default. Larger and custom models can use more memory and take longer to load."
        }
        return "The 0.6B model is the faster default. The 1.7B model uses more memory and takes longer to load."
    }
}
