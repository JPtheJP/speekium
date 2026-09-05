import XCTest
@testable import Speekium

/// Regression tests for the F1–F3 security hardening.
final class SecurityHardeningTests: XCTestCase {

    // MARK: - F1: SPEEKIUM_* overrides are development-only

    private let overrideKeys = [
        "SPEEKIUM_PYTHON",
        "SPEEKIUM_RUNTIME_DIRECTORY",
        "SPEEKIUM_RUNTIME_URL",
        "SPEEKIUM_RUNTIME_SHA256",
        "SPEEKIUM_RUNTIME_VERSION",
        "SPEEKIUM_RUNTIME_ARCHIVE_BYTES",
        "SPEEKIUM_RUNTIME_INSTALLED_BYTES",
        "SPEEKIUM_MODEL",
        "SPEEKIUM_ENGINE",
        "SPEEKIUM_BITS",
    ]

    func testReleaseBuildIgnoresEveryOverrideVariable() {
        let environment = Dictionary(uniqueKeysWithValues: overrideKeys.map { ($0, "/attacker/controlled") })
        let release = RuntimeEnvironment(
            bundleIdentifier: "com.jpthejp.speekium",
            environment: environment
        )

        XCTAssertFalse(release.allowsOverrides)
        for key in overrideKeys {
            XCTAssertNil(
                release.value(key),
                "\(key) must be ignored in a release build even when present in the environment"
            )
        }
    }

    func testDevelopmentBuildHonorsOverrideVariables() {
        let development = RuntimeEnvironment(
            bundleIdentifier: "dev.local.speekium",
            environment: ["SPEEKIUM_PYTHON": "/opt/python3.12"]
        )

        XCTAssertTrue(development.allowsOverrides)
        XCTAssertEqual(development.value("SPEEKIUM_PYTHON"), "/opt/python3.12")
    }

    func testMissingBundleIdentifierIsTreatedAsRelease() {
        // The test host and a shipped app both lack a `dev.` identifier, so a nil
        // identifier must fail closed rather than open.
        XCTAssertFalse(RuntimeEnvironment.isDevelopmentBundle(nil))
        XCTAssertFalse(RuntimeEnvironment.isDevelopmentBundle("com.jpthejp.speekium"))
        XCTAssertTrue(RuntimeEnvironment.isDevelopmentBundle("dev.local.speekium"))
    }

    func testEmptyOverrideValueIsIgnoredInDevelopment() {
        let development = RuntimeEnvironment(
            bundleIdentifier: "dev.local.speekium",
            environment: ["SPEEKIUM_PYTHON": ""]
        )
        XCTAssertNil(development.value("SPEEKIUM_PYTHON"))
    }

    // MARK: - F3: log file is owner-only (0600)

    func testEnsureSecureLogFileCreatesOwnerOnlyFile() throws {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("speekium-log-\(UUID().uuidString).log")
        defer { try? fileManager.removeItem(at: url) }

        Log.ensureSecureLogFile(at: url, fileManager: fileManager)

        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
        XCTAssertEqual(try posixPermissions(of: url), 0o600)
    }

    func testEnsureSecureLogFileTightensAWorldReadableFile() throws {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("speekium-log-\(UUID().uuidString).log")
        defer { try? fileManager.removeItem(at: url) }

        // Simulate a log left behind by an earlier version at 0644.
        fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644])
        XCTAssertEqual(try posixPermissions(of: url), 0o644)

        Log.ensureSecureLogFile(at: url, fileManager: fileManager)

        XCTAssertEqual(try posixPermissions(of: url), 0o600)
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
