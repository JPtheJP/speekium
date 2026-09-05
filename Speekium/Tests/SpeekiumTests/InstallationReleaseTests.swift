import XCTest
@testable import Speekium

final class InstallationReleaseTests: XCTestCase {
    func testRuntimeContentDigestMatchesReleaseToolFormatAndDetectsChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speekium-runtime-digest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("lib"),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let module = root.appendingPathComponent("lib/module.py")
        try Data("print(\"ok\")\n".utf8).write(to: module)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("bin/python3").path,
            withDestinationPath: "../lib/module.py"
        )

        XCTAssertEqual(
            try RuntimeIntegrityCheck.contentDigest(at: root),
            "70be1b8f7e8ca844ba6716a3bc95c22faeb65f2638d778e2deb7ad4df1f3a978"
        )

        try Data("print(\"changed\")\n".utf8).write(to: module)
        XCTAssertNotEqual(
            try RuntimeIntegrityCheck.contentDigest(at: root),
            "70be1b8f7e8ca844ba6716a3bc95c22faeb65f2638d778e2deb7ad4df1f3a978"
        )
    }

    func testRuntimeIntegrityAcceptsOnlyTheExactAuthenticatedTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speekium-runtime-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("lib/__pycache__", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("trusted-bytecode".utf8).write(
            to: cache.appendingPathComponent("module.cpython-312.pyc")
        )
        let manifest = RuntimeManifest(
            runtimeVersion: "1.0.0",
            pythonVersion: "3.12.12",
            architecture: "arm64",
            minimumMacOS: "14.0",
            dependencySet: "test",
            payloadBytes: 1,
            dependencyVersions: [
                "mlx": "0.29.4",
                "numpy": "2.5.1",
                "huggingface-hub": "1.26.0",
                "mlx-qwen3-asr": "0.3.5",
                "mlx-whisper": "0.4.3",
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent("manifest.json")
        )
        let module = root.appendingPathComponent("lib/module.py")
        try Data("trusted".utf8).write(to: module)

        let expected = try RuntimeIntegrityCheck.contentDigest(at: root)
        guard case .success = RuntimeIntegrityCheck.runSynchronously(
            runtimeDirectory: root,
            expectedDigest: expected
        ) else {
            return XCTFail("trusted runtime did not pass integrity verification")
        }

        try Data("tampered".utf8).write(to: module)
        guard case .failure = RuntimeIntegrityCheck.runSynchronously(
            runtimeDirectory: root,
            expectedDigest: expected
        ) else {
            return XCTFail("modified runtime passed integrity verification")
        }

        try Data("trusted".utf8).write(to: module)
        try Data("unexpected".utf8).write(to: root.appendingPathComponent("extra.py"))
        guard case .failure = RuntimeIntegrityCheck.runSynchronously(
            runtimeDirectory: root,
            expectedDigest: expected
        ) else {
            return XCTFail("runtime with an added file passed integrity verification")
        }
    }

    func testRuntimeIntegrityRejectsHardLinksAndEscapingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speekium-runtime-links-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("module.py")
        try Data("trusted".utf8).write(to: original)
        try FileManager.default.linkItem(
            at: original,
            to: root.appendingPathComponent("module-copy.py")
        )
        XCTAssertThrowsError(try RuntimeIntegrityCheck.contentDigest(at: root))

        try FileManager.default.removeItem(at: root.appendingPathComponent("module-copy.py"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("escape").path,
            withDestinationPath: "../../outside"
        )
        XCTAssertThrowsError(try RuntimeIntegrityCheck.contentDigest(at: root))
    }

    func testProductionRuntimeConfigurationIgnoresEnvironmentOverrides() {
        XCTAssertEqual(
            RuntimeConfiguration.value(
                environmentValue: "attacker",
                bundleValue: "signed",
                allowsEnvironmentOverride: false
            ),
            "signed"
        )
        XCTAssertEqual(
            RuntimeConfiguration.value(
                environmentValue: "developer",
                bundleValue: "signed",
                allowsEnvironmentOverride: true
            ),
            "developer"
        )
    }

    func testStorageRequiredBytesIncludesOneSafetyMargin() {
        XCTAssertEqual(
            StorageCapacity.requiredBytes(100, 200, margin: 50),
            350
        )
        XCTAssertEqual(
            StorageCapacity.check(available: 350, required: 350),
            .enough(required: 350, available: 350)
        )
        XCTAssertEqual(
            StorageCapacity.check(available: 349, required: 350),
            .insufficient(required: 350, available: 349)
        )
    }

    func testStorageArithmeticRejectsOverflowAndUnknownCapacity() {
        XCTAssertNil(StorageCapacity.requiredBytes(Int64.max, 1, margin: 0))
        XCTAssertEqual(StorageCapacity.check(available: nil, required: 1), .unavailable)
        XCTAssertEqual(StorageCapacity.check(available: 1, required: nil), .unavailable)
    }

    func testRuntimeManifestCompatibilityAndUnsupportedSchema() throws {
        let manifest = RuntimeManifest(
            runtimeVersion: "1.0.0",
            pythonVersion: "3.12.12",
            architecture: "arm64",
            minimumMacOS: "14.0",
            dependencySet: "mlx-qwen3-asr-0.3.5+mlx-whisper-0.4.3",
            payloadBytes: 100,
            dependencyVersions: [
                "mlx": "0.29.4",
                "numpy": "2.5.1",
                "huggingface-hub": "1.26.0",
                "mlx-qwen3-asr": "0.3.5",
                "mlx-whisper": "0.4.3",
            ]
        )
        let current = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        XCTAssertNil(manifest.compatibilityError(requiredRuntimeVersion: "1.0.0", currentOS: current))
        XCTAssertNotNil(manifest.compatibilityError(requiredRuntimeVersion: "1.1.0", currentOS: current))

        let unsupported = RuntimeManifest(
            schemaVersion: 2,
            runtimeVersion: "1.0.0",
            pythonVersion: "3.12.12",
            architecture: "arm64",
            minimumMacOS: "14.0",
            dependencySet: "test",
            payloadBytes: 100
        )
        XCTAssertNotNil(unsupported.compatibilityError(requiredRuntimeVersion: "1.0.0", currentOS: current))

        let data = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeManifest.self, from: data), manifest)
    }

    func testPublicRuntimeDoesNotRequireOptionalModelDependencies() {
        let manifest = RuntimeManifest(
            runtimeVersion: "1.0.0",
            pythonVersion: "3.12.12",
            architecture: "arm64",
            minimumMacOS: "14.0",
            dependencySet: "mlx-qwen3-asr-0.3.5",
            payloadBytes: 100,
            dependencyVersions: [
                "mlx": "0.29.4",
                "numpy": "2.5.1",
                "huggingface-hub": "1.26.0",
                "mlx-qwen3-asr": "0.3.5",
            ]
        )
        let current = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

        XCTAssertNil(manifest.compatibilityError(
            requiredRuntimeVersion: "1.0.0",
            currentOS: current,
            includeOptionalModels: false
        ))
        XCTAssertNotNil(manifest.compatibilityError(
            requiredRuntimeVersion: "1.0.0",
            currentOS: current,
            includeOptionalModels: true
        ))
    }

    func testCompileTimeOptionalModelGateMatchesRuntimeRequirements() {
        let requirements = FeatureFlags.requiredRuntimeModules()
        #if DEBUG || SPEEKIUM_ENABLE_OPTIONAL_MODELS
        XCTAssertTrue(FeatureFlags.optionalModelsEnabled)
        XCTAssertEqual(requirements["mlx_whisper"], "mlx-whisper")
        #else
        XCTAssertFalse(FeatureFlags.optionalModelsEnabled)
        XCTAssertNil(requirements["mlx_whisper"])
        #endif
    }

    func testPythonEnvironmentRemovesHostileOverridesAndPreservesIntentionalSettings() {
        let environment = PythonProcessEnvironment.sanitized(base: [
            "PYTHONPATH": "/tmp/poison",
            "PYTHONHOME": "/tmp/poison-home",
            "VIRTUAL_ENV": "/tmp/venv",
            "DYLD_LIBRARY_PATH": "/tmp/poison-dylib",
            "HF_HOME": "/tmp/hf",
            "HF_HUB_CACHE": "/tmp/hf/hub",
            "HTTPS_PROXY": "https://proxy.example",
            "SPEEKIUM_MODEL": "custom",
        ])

        XCTAssertNil(environment["PYTHONPATH"])
        XCTAssertNil(environment["PYTHONHOME"])
        XCTAssertNil(environment["VIRTUAL_ENV"])
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
        XCTAssertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(environment["PYTHONNOUSERSITE"], "1")
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(environment["HF_HUB_CACHE"], "/tmp/hf/hub")
        XCTAssertEqual(environment["HTTPS_PROXY"], "https://proxy.example")
        XCTAssertEqual(environment["SPEEKIUM_MODEL"], "custom")
    }

    func testPythonArgumentsDoNotUseBareInterpreterMode() {
        let script = URL(fileURLWithPath: "/tmp/model_download.py")
        XCTAssertEqual(
            PythonProcessEnvironment.scriptArguments(script: script, arguments: ["--preflight", "Qwen/model"]),
            ["-B", "-s", "-u", "/tmp/model_download.py", "--preflight", "Qwen/model"]
        )
    }

    func testModelPreflightDecodesMachineReadableMetadata() throws {
        let data = #"{"model":"Qwen/Qwen3-ASR-0.6B","totalBytes":1900000000,"availableBytes":5000000000,"incompleteBytes":0,"reusableBytes":0,"requiredBytes":2436870912,"cacheRoot":"/tmp/hub"}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(ModelPreflight.self, from: data)
        XCTAssertEqual(result.totalBytes, 1_900_000_000)
        XCTAssertEqual(result.availableBytes, 5_000_000_000)
        XCTAssertEqual(result.incompleteBytes, 0)
    }
}
