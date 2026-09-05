from pathlib import Path
import re


ROOT = Path(__file__).parents[1]
LOCKED_REQUIREMENT = re.compile(
    r"^([a-z0-9][a-z0-9._-]*)==([^\s]+) --hash=sha256:([0-9a-f]{64})$"
)


def requirement_versions(path):
    return {
        line.split("==", 1)[0]: line.split("==", 1)[1]
        for line in path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    }


def locked_requirement_versions(path):
    versions = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        match = LOCKED_REQUIREMENT.fullmatch(line)
        assert match, f"unlocked runtime requirement: {line}"
        versions[match.group(1)] = match.group(2)
    return versions


def requirement_names(path):
    return set(requirement_versions(path))


def test_whisper_runtime_omits_conversion_only_pytorch_dependency():
    regular = requirement_names(ROOT / "requirements-macos-arm64.txt")
    nodeps = requirement_names(ROOT / "requirements-macos-arm64-nodeps.txt")

    assert nodeps == {"mlx-whisper"}
    assert "torch" not in regular
    assert "mlx-whisper" not in regular
    assert {"numba", "scipy", "tiktoken", "tqdm"}.issubset(regular)


def test_setup_and_release_runtime_install_whisper_without_dependencies():
    setup = (ROOT / "setup-mac.sh").read_text(encoding="utf-8")
    release_builder = (ROOT / "WhisprStream/build-runtime.sh").read_text(encoding="utf-8")

    assert "requirements-macos-arm64-nodeps.txt" in setup
    assert "requirements-macos-arm64-nodeps.lock" in release_builder
    assert "--no-deps" in setup
    assert "--no-deps" in release_builder


def test_release_runtime_uses_complete_hash_locked_inputs():
    direct = requirement_versions(ROOT / "requirements-macos-arm64.txt")
    direct_nodeps = requirement_versions(ROOT / "requirements-macos-arm64-nodeps.txt")
    regular_lock = locked_requirement_versions(ROOT / "requirements-macos-arm64.lock")
    nodeps_lock = locked_requirement_versions(ROOT / "requirements-macos-arm64-nodeps.lock")
    script = (ROOT / "WhisprStream" / "build-runtime.sh").read_text(encoding="utf-8")

    assert direct == {name: regular_lock[name] for name in direct}
    assert direct_nodeps == nodeps_lock == {"mlx-whisper": "0.4.3"}
    assert "requirements-macos-arm64.lock" in script
    assert "requirements-macos-arm64-nodeps.lock" in script
    assert script.count("--require-hashes") >= 2
    assert script.count("--no-deps") >= 2
    assert '"$PROJECT_ROOT/requirements-macos-arm64.lock"' in script
    assert '"$PROJECT_ROOT/requirements-macos-arm64-nodeps.lock"' in script


def test_release_build_compiles_out_developer_runtime_overrides():
    build_script = (ROOT / "WhisprStream" / "build.sh").read_text(encoding="utf-8")
    runtime_manager = (
        ROOT / "WhisprStream/Sources/WhisprStream/RuntimeManager.swift"
    ).read_text(encoding="utf-8")

    assert "WHISPR_RELEASE" in build_script
    assert "#if WHISPR_RELEASE" in runtime_manager


def test_bundled_and_development_engine_sources_stay_in_sync():
    assert (ROOT / "asr_engine.py").read_bytes() == (
        ROOT / "WhisprStream/Resources/asr_engine.py"
    ).read_bytes()
