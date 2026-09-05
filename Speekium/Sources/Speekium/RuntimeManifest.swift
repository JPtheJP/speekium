import Foundation

struct RuntimeManifest: Codable, Equatable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let runtimeVersion: String
    let pythonVersion: String
    let architecture: String
    let minimumMacOS: String
    let dependencySet: String
    let payloadBytes: Int64
    let dependencyVersions: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, runtimeVersion, pythonVersion, architecture
        case minimumMacOS, dependencySet, payloadBytes, dependencyVersions
    }

    init(
        schemaVersion: Int = RuntimeManifest.supportedSchemaVersion,
        runtimeVersion: String,
        pythonVersion: String,
        architecture: String,
        minimumMacOS: String,
        dependencySet: String,
        payloadBytes: Int64,
        dependencyVersions: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeVersion = runtimeVersion
        self.pythonVersion = pythonVersion
        self.architecture = architecture
        self.minimumMacOS = minimumMacOS
        self.dependencySet = dependencySet
        self.payloadBytes = payloadBytes
        self.dependencyVersions = dependencyVersions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        runtimeVersion = try values.decode(String.self, forKey: .runtimeVersion)
        pythonVersion = try values.decode(String.self, forKey: .pythonVersion)
        architecture = try values.decode(String.self, forKey: .architecture)
        minimumMacOS = try values.decode(String.self, forKey: .minimumMacOS)
        dependencySet = try values.decode(String.self, forKey: .dependencySet)
        payloadBytes = try values.decode(Int64.self, forKey: .payloadBytes)
        dependencyVersions = try values.decodeIfPresent([String: String].self, forKey: .dependencyVersions) ?? [:]
    }

    func compatibilityError(
        requiredRuntimeVersion: String,
        currentOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture currentArchitecture: String = "arm64",
        includeOptionalModels: Bool = FeatureFlags.optionalModelsEnabled
    ) -> String? {
        guard schemaVersion == Self.supportedSchemaVersion else {
            return "The speech engine uses an unsupported manifest format."
        }
        guard runtimeVersion == requiredRuntimeVersion else {
            return "The installed speech engine is version \(runtimeVersion); this app requires \(requiredRuntimeVersion)."
        }
        guard architecture == currentArchitecture else {
            return "The installed speech engine is not built for this Mac."
        }
        guard pythonVersion.hasPrefix("3.12") else {
            return "The installed speech engine does not contain Python 3.12."
        }
        guard let minimum = Self.parseOSVersion(minimumMacOS),
              Self.isAtLeast(currentOS, minimum) else {
            return "This speech engine requires macOS \(minimumMacOS) or later."
        }
        guard payloadBytes > 0 else { return "The speech engine manifest has no payload size." }
        let requiredDependencies = Set(FeatureFlags.requiredRuntimeModules(
            includeOptionalModels: includeOptionalModels
        ).values)
        guard requiredDependencies.isSubset(of: Set(dependencyVersions.keys)) else {
            return "The speech engine manifest does not describe all pinned dependencies."
        }
        return nil
    }

    private static func parseOSVersion(_ value: String) -> (Int, Int, Int)? {
        let parts = value.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { return nil }
        return (major, minor, parts.count > 2 ? parts[2] ?? 0 : 0)
    }

    private static func isAtLeast(_ value: OperatingSystemVersion, _ minimum: (Int, Int, Int)) -> Bool {
        if value.majorVersion != minimum.0 { return value.majorVersion > minimum.0 }
        if value.minorVersion != minimum.1 { return value.minorVersion > minimum.1 }
        return value.patchVersion >= minimum.2
    }
}
