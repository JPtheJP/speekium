import XCTest
@testable import Speekium

final class InstallationReleaseTests: XCTestCase {
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
            dependencySet: "mlx-qwen3-asr-0.3.5",
            payloadBytes: 100,
            dependencyVersions: [
                "mlx": "0.32.0",
                "numpy": "2.5.1",
                "huggingface-hub": "1.26.0",
                "mlx-qwen3-asr": "0.3.5",
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
            ["-s", "-u", "/tmp/model_download.py", "--preflight", "Qwen/model"]
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
