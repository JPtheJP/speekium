import Foundation
import XCTest
@testable import Speekium

@MainActor
final class ModelCatalogTests: XCTestCase {
    func testBuiltInPreferenceAndCustomModelCodableRoundTrip() throws {
        XCTAssertEqual(
            ASRModel(rawValue: "Qwen/Qwen3-ASR-0.6B"),
            .small
        )
        XCTAssertNil(ASRModel(rawValue: "someone/custom-model"))

        let custom = ASRModel(
            engine: .whisper,
            source: .huggingFace,
            location: "mlx-community/whisper-small-mlx"
        )
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(ASRModel.self, from: data), custom)
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertEqual(custom.label, "whisper-small-mlx")
    }

    #if DEBUG || SPEEKIUM_ENABLE_OPTIONAL_MODELS
    func testLocalModelValidationUsesEngineSpecificWeightLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Speekium-ModelCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let whisper = root.appendingPathComponent("custom whisper")
        try FileManager.default.createDirectory(at: whisper, withIntermediateDirectories: true)
        try Data(#"{"model_type":"whisper"}"#.utf8).write(
            to: whisper.appendingPathComponent("config.json")
        )
        try Data([0]).write(to: whisper.appendingPathComponent("weights.npz"))
        let whisperModel = try ModelCatalog.validatedCustomModel(
            engine: .whisper,
            source: .local,
            location: whisper.path
        )
        XCTAssertEqual(ModelCatalog.state(for: whisperModel), .installed)

        let qwen = root.appendingPathComponent("custom-qwen")
        try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3_asr"}"#.utf8).write(
            to: qwen.appendingPathComponent("config.json")
        )
        try Data([0]).write(to: qwen.appendingPathComponent("model.safetensors"))
        let qwenModel = try ModelCatalog.validatedCustomModel(
            engine: .qwen3,
            source: .local,
            location: qwen.path
        )
        XCTAssertEqual(ModelCatalog.state(for: qwenModel), .installed)

        XCTAssertThrowsError(try ModelCatalog.validatedCustomModel(
            engine: .qwen3,
            source: .local,
            location: whisper.path
        )) { error in
            XCTAssertEqual(
                error as? ASRModelValidationError,
                .incompatibleLocalModel(.qwen3)
            )
        }

        try Data([0]).write(to: whisper.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try ModelCatalog.validatedCustomModel(
            engine: .qwen3,
            source: .local,
            location: whisper.path
        ))

        let redirected = root.appendingPathComponent("redirected-index")
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3_asr"}"#.utf8).write(
            to: redirected.appendingPathComponent("config.json")
        )
        try Data([0]).write(to: root.appendingPathComponent("outside.safetensors"))
        let unsafeIndex = #"{"weight_map":{"layer":"../outside.safetensors"}}"#
        try Data(unsafeIndex.utf8).write(
            to: redirected.appendingPathComponent("model.safetensors.index.json")
        )
        let redirectedModel = ASRModel(
            engine: .qwen3,
            source: .local,
            location: redirected.path
        )
        XCTAssertEqual(ModelCatalog.state(for: redirectedModel), .missing)
    }

    func testSettingsPersistCustomModelAndSelectedEngine() throws {
        let suite = "Speekium.ModelCatalogTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = Settings(defaults: defaults)
        let custom = try first.addCustomModel(
            engine: .whisper,
            source: .huggingFace,
            location: "mlx-community/whisper-small-mlx"
        )
        first.model = custom

        let restored = Settings(defaults: defaults)
        XCTAssertEqual(restored.model, custom)
        XCTAssertEqual(restored.model.engine, .whisper)
        XCTAssertEqual(restored.customModels, [custom])

        restored.forgetCustomModel(custom)
        XCTAssertTrue(restored.customModels.isEmpty)
        XCTAssertTrue(restored.model.isBuiltIn)
    }
    #else
    func testReleaseGateHidesSavedCustomModelsAndRejectsActivation() throws {
        let suite = "Speekium.ModelCatalogTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let custom = ASRModel(
            engine: .whisper,
            source: .huggingFace,
            location: "mlx-community/whisper-small-mlx"
        )
        defaults.set(try JSONEncoder().encode([custom]), forKey: "customModels.v1")
        defaults.set(try JSONEncoder().encode(custom), forKey: "selectedModel.v2")

        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.availableModels, ASRModel.allCases)
        XCTAssertTrue(settings.customModels.isEmpty)
        XCTAssertEqual(settings.model, .small)

        settings.model = custom
        XCTAssertEqual(settings.model, .small)
        XCTAssertThrowsError(try settings.addCustomModel(
            engine: .whisper,
            source: .huggingFace,
            location: custom.location
        )) { error in
            XCTAssertEqual(
                error as? ASRModelValidationError,
                .optionalModelsUnavailable
            )
        }

        // The gate must not erase a developer's saved definitions.
        XCTAssertNotNil(defaults.data(forKey: "customModels.v1"))
        XCTAssertNotNil(defaults.data(forKey: "selectedModel.v2"))
    }
    #endif
}
