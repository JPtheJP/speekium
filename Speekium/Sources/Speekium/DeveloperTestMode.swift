import Foundation

/// Controls the local-only first-run simulator.
///
/// Environment variables are captured when the process starts. The explicit
/// launch argument and the in-app activation path make the mode easier to
/// exercise when an already-running menu-bar app would otherwise hide that
/// the new shell command started a different process.
enum DeveloperTestMode {
    static let environmentKey = "SPEEKIUM_TEST_FIRST_RUN"
    static let launchArgument = "--speekium-test-first-run"

    private static var manuallyActivated = false

    static var isEnabled: Bool {
        guard isLocalDevelopmentBuild else { return false }
        return manuallyActivated
            || ProcessInfo.processInfo.environment[environmentKey] == "1"
            || CommandLine.arguments.contains(launchArgument)
    }

    /// Only local development builds may activate the simulator from the UI.
    /// A public release can still never enter it accidentally.
    static var isAvailable: Bool {
        isLocalDevelopmentBuild
    }

    static func activate() {
        guard isAvailable else { return }
        manuallyActivated = true
    }

    private static var isLocalDevelopmentBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String ?? "")
            .hasPrefix("dev.")
    }
}

extension Notification.Name {
    static let speekiumDeveloperTestModeActivated = Notification.Name(
        "SpeekiumDeveloperTestModeActivated"
    )
}
