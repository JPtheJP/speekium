import Foundation

/// Compile-time product gates. Public release builds deliberately omit the
/// optional-model flag, so saved preferences or process environment variables
/// cannot turn the feature back on after the app has shipped.
enum FeatureFlags {
    #if DEBUG || WHISPR_ENABLE_OPTIONAL_MODELS
    static let optionalModelsEnabled = true
    #else
    static let optionalModelsEnabled = false
    #endif

    /// Python modules and matching distribution names required by the runtime.
    /// The public 1.0.1 runtime only needs the Qwen stack; developer builds add
    /// the experimental MLX Whisper adapter when optional models are enabled.
    static func requiredRuntimeModules(
        includeOptionalModels: Bool = FeatureFlags.optionalModelsEnabled
    ) -> [String: String] {
        var modules = [
            "mlx": "mlx",
            "numpy": "numpy",
            "huggingface_hub": "huggingface-hub",
            "mlx_qwen3_asr": "mlx-qwen3-asr",
        ]
        if includeOptionalModels {
            modules["mlx_whisper"] = "mlx-whisper"
        }
        return modules
    }
}
