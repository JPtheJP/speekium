import importlib.util
from pathlib import Path

import pytest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "WhisprStream" / "runtime-content-sha256.py"
SPEC = importlib.util.spec_from_file_location("runtime_content_sha256", SCRIPT)
runtime_digest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime_digest)


def fixture_runtime(root: Path) -> None:
    (root / "bin").mkdir(parents=True)
    (root / "lib").mkdir()
    (root / "manifest.json").write_bytes(b"{}\n")
    (root / "lib" / "module.py").write_bytes(b'print("ok")\n')
    (root / "bin" / "python3").symlink_to("../lib/module.py")


def test_runtime_digest_covers_names_types_bytes_and_symlink_targets(tmp_path):
    fixture_runtime(tmp_path)

    assert runtime_digest.content_digest(tmp_path) == (
        "f331f4a76bf51dabc4732328f1df4e723b117b51e6859bdb79f1b2323f68b3e1"
    )

    original = runtime_digest.content_digest(tmp_path)
    (tmp_path / "lib" / "module.py").write_bytes(b'print("changed")\n')
    assert runtime_digest.content_digest(tmp_path) != original

    (tmp_path / "lib" / "module.py").write_bytes(b'print("ok")\n')
    (tmp_path / "extra.py").write_text("extra", encoding="utf-8")
    assert runtime_digest.content_digest(tmp_path) != original


def test_runtime_digest_removes_legacy_bytecode_without_following_links(tmp_path):
    fixture_runtime(tmp_path)
    cache = tmp_path / "lib" / "__pycache__"
    cache.mkdir()
    (cache / "module.cpython-312.pyc").write_bytes(b"legacy")
    (tmp_path / "stray.pyc").write_bytes(b"legacy")

    runtime_digest.remove_bytecode(tmp_path)

    assert not cache.exists()
    assert not (tmp_path / "stray.pyc").exists()
    assert runtime_digest.content_digest(tmp_path) == (
        "f331f4a76bf51dabc4732328f1df4e723b117b51e6859bdb79f1b2323f68b3e1"
    )


def test_runtime_digest_rejects_escaping_symlink(tmp_path):
    fixture_runtime(tmp_path)
    (tmp_path / "escape").symlink_to("../../outside")

    with pytest.raises(runtime_digest.RuntimeTreeError, match="escaping runtime symlink"):
        runtime_digest.content_digest(tmp_path)
