import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest


MODULE_PATH = Path(__file__).parents[1] / "WhisprStream" / "Resources" / "model_download.py"
SPEC = importlib.util.spec_from_file_location("whispr_model_download", MODULE_PATH)
model_download = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(model_download)


class FakeAPI:
    def __init__(self, siblings):
        self.siblings = siblings

    def model_info(self, repo_id, files_metadata=True):
        assert files_metadata is True
        return SimpleNamespace(siblings=self.siblings)


def fake_usage(free):
    return lambda _path: SimpleNamespace(free=free)


def repo(root, model="Qwen/Qwen3-ASR-0.6B"):
    path = model_download.repo_folder(root, model)
    (path / "blobs").mkdir(parents=True)
    return path


def test_preflight_sums_only_download_patterns(tmp_path):
    api = FakeAPI([
        SimpleNamespace(rfilename="config.json", size=10),
        SimpleNamespace(rfilename="tokenizer.txt", size=20),
        SimpleNamespace(rfilename="model.safetensors", size=30),
        SimpleNamespace(rfilename="README.md", size=10_000),
        SimpleNamespace(rfilename="model.bin", size=10_000),
    ])

    result = model_download.preflight(
        "Qwen/Qwen3-ASR-0.6B",
        api=api,
        cache_root=tmp_path / "custom-cache",
        usage=fake_usage(10_000),
    )

    assert result["totalBytes"] == 60
    assert result["availableBytes"] == 10_000
    assert result["cacheRoot"].endswith("custom-cache")
    assert result["requiredBytes"] == 60 + model_download.SAFETY_MARGIN_BYTES


def test_preflight_exposes_capacity_failure_without_downloading(tmp_path):
    api = FakeAPI([SimpleNamespace(rfilename="model.safetensors", size=1_000)])
    result = model_download.preflight(
        "Qwen/Qwen3-ASR-0.6B",
        api=api,
        cache_root=tmp_path,
        usage=fake_usage(1),
    )

    assert result["availableBytes"] < result["requiredBytes"]


def test_custom_cache_environment_is_resolved(monkeypatch, tmp_path):
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hub-cache"))
    monkeypatch.delenv("HF_HOME", raising=False)
    assert model_download.resolve_cache_root() == tmp_path / "hub-cache"


def test_incomplete_bytes_and_cleanup_are_scoped_to_selected_repository(tmp_path):
    selected = repo(tmp_path)
    other = repo(tmp_path, "Qwen/Qwen3-ASR-1.7B")
    (selected / "blobs" / "old.incomplete").write_bytes(b"12345")
    (selected / "blobs" / "complete").write_bytes(b"complete")
    (other / "blobs" / "other.incomplete").write_bytes(b"other")

    assert model_download.incomplete_bytes(selected) == 5
    assert model_download.cleanup_incomplete("Qwen/Qwen3-ASR-0.6B", cache_root=tmp_path) == 5
    assert not (selected / "blobs" / "old.incomplete").exists()
    assert (selected / "blobs" / "complete").exists()
    assert (other / "blobs" / "other.incomplete").exists()


def test_cleanup_refuses_active_attempt(tmp_path):
    selected = repo(tmp_path)
    (selected / "blobs" / "old.incomplete").write_bytes(b"123")
    lock = model_download.acquire_repo_lock(selected)
    assert lock is not None

    try:
        with pytest.raises(RuntimeError, match="active"):
            model_download.cleanup_incomplete("Qwen/Qwen3-ASR-0.6B", cache_root=tmp_path)
    finally:
        model_download.release_repo_lock(lock)
    assert (selected / "blobs" / "old.incomplete").exists()


def test_stale_marker_does_not_block_cleanup(tmp_path):
    selected = repo(tmp_path)
    (selected / model_download.ACTIVE_MARKER).write_text("stale legacy marker")
    partial = selected / "blobs" / "old.incomplete"
    partial.write_bytes(b"123")

    assert model_download.cleanup_incomplete(
        "Qwen/Qwen3-ASR-0.6B", cache_root=tmp_path
    ) == 3
    assert not partial.exists()


def test_progress_excludes_stale_partial_files(tmp_path):
    selected = repo(tmp_path)
    stale = selected / "blobs" / "stale.incomplete"
    stale.write_bytes(b"stale-data")
    before = set(model_download.incomplete_files(selected))
    fresh = selected / "blobs" / "fresh.incomplete"
    fresh.write_bytes(b"fresh")

    assert model_download.attempt_progress(selected, before, 100) == len(b"fresh")


def test_metadata_failure_is_distinct_from_capacity_result(tmp_path):
    class OfflineAPI:
        def model_info(self, *_args, **_kwargs):
            raise OSError("offline")

    with pytest.raises(model_download.MetadataError, match="offline"):
        model_download.preflight(
            "Qwen/Qwen3-ASR-0.6B",
            api=OfflineAPI(),
            cache_root=tmp_path,
            usage=fake_usage(10**12),
        )
