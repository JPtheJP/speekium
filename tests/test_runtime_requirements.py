from pathlib import Path


ROOT = Path(__file__).parents[1]


def requirement_names(path):
    return {
        line.split("==", 1)[0]
        for line in path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    }


def test_whisper_runtime_omits_conversion_only_pytorch_dependency():
    regular = requirement_names(ROOT / "requirements-macos-arm64.txt")
    nodeps = requirement_names(ROOT / "requirements-macos-arm64-nodeps.txt")

    assert nodeps == {"mlx-whisper"}
    assert "torch" not in regular
    assert "mlx-whisper" not in regular
    assert {"numba", "scipy", "tiktoken", "tqdm"}.issubset(regular)


def test_setup_and_release_runtime_install_whisper_without_dependencies():
    for relative in ("setup-mac.sh", "WhisprStream/build-runtime.sh"):
        script = (ROOT / relative).read_text(encoding="utf-8")
        assert "requirements-macos-arm64-nodeps.txt" in script
        assert "--no-deps" in script


def test_bundled_and_development_engine_sources_stay_in_sync():
    assert (ROOT / "asr_engine.py").read_bytes() == (
        ROOT / "WhisprStream/Resources/asr_engine.py"
    ).read_bytes()
