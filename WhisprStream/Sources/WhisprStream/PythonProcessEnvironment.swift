import Foundation

/// Builds the environment used by every Python sidecar process.
///
/// The app intentionally inherits ordinary networking, locale, Hugging Face,
/// and WhisprStream settings, but removes shell/virtual-environment state that
/// could redirect imports or native-library loading to the user's Python.
enum PythonProcessEnvironment {
    static let removedKeys: Set<String> = [
        "PYTHONHOME",
        "PYTHONPATH",
        "PYTHONSTARTUP",
        "PYTHONEXECUTABLE",
        "VIRTUAL_ENV",
        "CONDA_PREFIX",
        "CONDA_DEFAULT_ENV",
        "_OLD_VIRTUAL_PATH",
        "LD_LIBRARY_PATH",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_INSERT_LIBRARIES",
    ]

    static func sanitized(
        base: [String: String] = ProcessInfo.processInfo.environment,
        additions: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        for key in removedKeys {
            environment.removeValue(forKey: key)
        }
        // Importing asr_engine from Contents/Resources must never create a
        // __pycache__ inside the signed app bundle. Any new file there breaks
        // the code-signing seal and makes the next launch fail Gatekeeper.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        for (key, value) in additions {
            environment[key] = value
        }
        return environment
    }

    static func scriptArguments(script: URL, arguments: [String] = []) -> [String] {
        ["-B", "-s", "-u", script.path] + arguments
    }

    static func codeArguments(_ code: String) -> [String] {
        ["-B", "-s", "-u", "-c", code]
    }
}
