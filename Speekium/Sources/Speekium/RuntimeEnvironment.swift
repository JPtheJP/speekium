import Foundation

/// Gate for the `SPEEKIUM_*` override variables that can redirect the speech
/// runtime's executable, install location, download source, or model.
///
/// These overrides are a **local development affordance only**. Honoring them in
/// a shipped release would let a poisoned launch environment (a LaunchAgent
/// `EnvironmentVariables` entry, `launchctl setenv`, etc.) point the sidecar at
/// an attacker-chosen executable — code that would then run inside a process
/// holding Microphone and Accessibility grants. So overrides are accepted only
/// when the bundle identifier marks a development build (`dev.` prefix); every
/// release ignores them and trusts only the signed Info.plist and managed
/// runtime directory.
struct RuntimeEnvironment {
    let allowsOverrides: Bool
    private let environment: [String: String]

    init(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        allowsOverrides = Self.isDevelopmentBundle(bundleIdentifier)
        self.environment = environment
    }

    /// A development build is any whose bundle identifier is prefixed `dev.`.
    /// Release builds use `com.jpthejp.speekium` and are never development.
    static func isDevelopmentBundle(_ bundleIdentifier: String?) -> Bool {
        (bundleIdentifier ?? "").hasPrefix("dev.")
    }

    /// The non-empty value of an override variable, or `nil` in a release build
    /// (regardless of the process environment) and whenever the variable is
    /// unset or empty.
    func value(_ key: String) -> String? {
        guard allowsOverrides else { return nil }
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }
}
