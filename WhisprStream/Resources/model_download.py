#!/usr/bin/env python3
"""Download supported speech-model weights with preflight and safe recovery.

All output is newline-delimited JSON so Swift can show state without parsing
human-oriented progress text. The selected Hugging Face repository is the only
place this helper may inspect or clean.
"""

from __future__ import annotations

import fnmatch
import fcntl
import json
import os
import re
import shutil
import sys
import threading
from pathlib import Path
from typing import Callable, Iterable, TextIO

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

ENGINE_PATTERNS = {
    "qwen3": ("*.json", "*.txt", "*.safetensors"),
    "whisper": (
        "config.json",
        "model.safetensors",
        "weights.safetensors",
        "weights.npz",
    ),
}
SAFETY_MARGIN_BYTES = 512 * 1024 * 1024
ACTIVE_MARKER = ".whisprstream-download-active"
REPO_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class MetadataError(RuntimeError):
    pass


class StorageCapacityError(RuntimeError):
    pass


class CompatibilityError(RuntimeError):
    pass


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def validate_repo_id(repo_id: str) -> None:
    if not REPO_ID_RE.fullmatch(repo_id):
        raise ValueError("invalid model repository")


def validate_engine(engine: str) -> None:
    if engine not in ENGINE_PATTERNS:
        raise ValueError("unsupported speech engine")


def repo_folder(cache_root: str | Path, repo_id: str) -> Path:
    validate_repo_id(repo_id)
    return Path(cache_root) / ("models--" + repo_id.replace("/", "--"))


def resolve_cache_root() -> Path:
    """Resolve the same cache precedence used by huggingface_hub."""
    try:
        from huggingface_hub.constants import HF_HUB_CACHE

        return Path(HF_HUB_CACHE).expanduser()
    except Exception:
        if os.environ.get("HF_HUB_CACHE"):
            return Path(os.environ["HF_HUB_CACHE"]).expanduser()
        if os.environ.get("HF_HOME"):
            return Path(os.environ["HF_HOME"]).expanduser() / "hub"
        return Path.home() / ".cache" / "huggingface" / "hub"


def matching_file(name: str, engine: str = "qwen3") -> bool:
    validate_engine(engine)
    return any(fnmatch.fnmatch(name, pattern) for pattern in ENGINE_PATTERNS[engine])


def regular_files(root: Path) -> Iterable[Path]:
    if not root.is_dir():
        return ()
    return (path for path in root.rglob("*") if path.is_file() and not path.is_symlink())


def bytes_on_disk(path: str | Path) -> int:
    total = 0
    for file in regular_files(Path(path)):
        try:
            total += file.stat().st_size
        except OSError:
            pass
    return total


def incomplete_files(repo: Path) -> list[Path]:
    blobs = repo / "blobs"
    if not blobs.is_dir():
        return []
    return [
        file
        for file in blobs.iterdir()
        if file.is_file() and not file.is_symlink() and file.name.endswith(".incomplete")
    ]


def incomplete_bytes(repo: Path) -> int:
    total = 0
    for file in incomplete_files(repo):
        try:
            total += file.stat().st_size
        except OSError:
            pass
    return total


def acquire_repo_lock(repo: Path) -> TextIO | None:
    """Lock one model repository without relying on a removable marker.

    The lock is owned by the OS and is released automatically if the helper is
    cancelled or crashes. The file intentionally remains on disk; its presence
    alone does not mean a download is active.
    """
    marker = repo / ACTIVE_MARKER
    if marker.is_symlink():
        raise RuntimeError("refusing to use a redirected model lock")
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(marker, flags, 0o600)
    except OSError as exc:
        raise RuntimeError(f"could not open the model lock: {exc}") from exc
    handle = os.fdopen(descriptor, "r+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    try:
        handle.seek(0)
        handle.truncate()
        handle.write(str(os.getpid()))
        handle.flush()
    except Exception:
        release_repo_lock(handle)
        raise
    return handle


def release_repo_lock(handle: TextIO) -> None:
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def complete_blob_bytes(repo: Path) -> int:
    blobs = repo / "blobs"
    total = 0
    if not blobs.is_dir():
        return 0
    for file in blobs.iterdir():
        if not file.is_file() or file.is_symlink() or file.name.endswith(".incomplete"):
            continue
        try:
            total += file.stat().st_size
        except OSError:
            pass
    return total


def nearest_existing_parent(path: Path) -> Path:
    current = path
    while not current.exists():
        parent = current.parent
        if parent == current:
            raise OSError("could not resolve cache volume")
        current = parent
    return current


def available_bytes(cache_root: Path, usage: Callable[[str], object] = shutil.disk_usage) -> int:
    usage_result = usage(str(nearest_existing_parent(cache_root)))
    return int(usage_result.free)


def validate_model_files(
    names: Iterable[str],
    engine: str,
    config: object | None = None,
) -> None:
    validate_engine(engine)
    # Required files must be at the repository root because both runtime
    # loaders resolve config.json and weights directly from the snapshot.
    files = set(names)
    if "config.json" not in files:
        raise CompatibilityError("The repository has no config.json file.")
    if isinstance(config, dict):
        declared_type = config.get("model_type")
        expected_type = "qwen3_asr" if engine == "qwen3" else "whisper"
        if isinstance(declared_type, str) and declared_type != expected_type:
            raise CompatibilityError(
                f"The repository declares model type {declared_type!r}, "
                f"not {expected_type!r}."
            )
    if engine == "qwen3":
        if not {
            "model.safetensors", "model.safetensors.index.json"
        }.intersection(files):
            raise CompatibilityError(
                "The repository is not a full Qwen3-ASR checkpoint."
            )
    elif not {
        "model.safetensors", "weights.safetensors", "weights.npz"
    }.intersection(files):
        raise CompatibilityError(
            "The repository is not an MLX-format Whisper model."
        )


def metadata_total(api: object, repo_id: str, engine: str = "qwen3") -> int:
    info = api.model_info(repo_id, files_metadata=True)
    siblings = info.siblings or []
    names = [
        getattr(sibling, "rfilename", None)
        or getattr(sibling, "path", None)
        or ""
        for sibling in siblings
    ]
    validate_model_files(names, engine, getattr(info, "config", None))
    total = 0
    for sibling in siblings:
        name = getattr(sibling, "rfilename", None) or getattr(sibling, "path", None) or ""
        size = getattr(sibling, "size", None)
        if matching_file(name, engine) and size is not None:
            total += int(size)
    if total <= 0:
        raise RuntimeError("the model did not report downloadable file sizes")
    return total


def preflight(
    repo_id: str,
    *,
    engine: str = "qwen3",
    api: object | None = None,
    cache_root: str | Path | None = None,
    usage: Callable[[str], object] = shutil.disk_usage,
) -> dict:
    validate_repo_id(repo_id)
    validate_engine(engine)
    if api is None:
        from huggingface_hub import HfApi

        api = HfApi()
    root = Path(cache_root).expanduser() if cache_root is not None else resolve_cache_root()
    repo = repo_folder(root, repo_id)
    try:
        total = metadata_total(api, repo_id, engine)
    except CompatibilityError:
        raise
    except Exception as exc:
        raise MetadataError(str(exc)) from exc
    try:
        available = available_bytes(root, usage)
    except Exception as exc:
        raise StorageCapacityError(str(exc)) from exc
    partial = incomplete_bytes(repo)
    return {
        "type": "preflight",
        "model": repo_id,
        "totalBytes": total,
        "availableBytes": available,
        "incompleteBytes": partial,
        "reusableBytes": complete_blob_bytes(repo),
        "requiredBytes": total + SAFETY_MARGIN_BYTES,
        "cacheRoot": str(root),
    }


def cleanup_incomplete(repo_id: str, *, cache_root: str | Path | None = None) -> int:
    validate_repo_id(repo_id)
    root = Path(cache_root).expanduser() if cache_root is not None else resolve_cache_root()
    repo_path = repo_folder(root, repo_id)
    if repo_path.is_symlink():
        raise RuntimeError("refusing to clean a redirected model repository")
    repo = repo_path.resolve()
    blobs_path = repo / "blobs"
    if blobs_path.is_symlink():
        raise RuntimeError("refusing to clean a redirected blobs directory")
    blobs = blobs_path.resolve()
    lock = acquire_repo_lock(repo)
    if lock is None:
        raise RuntimeError("a model download is active")

    try:
        removed = 0
        for file in incomplete_files(repo):
            resolved = file.resolve()
            if resolved.parent != blobs or not resolved.is_file() or resolved.is_symlink():
                raise RuntimeError("refusing to remove an unsafe partial download")
            try:
                removed += file.stat().st_size
                file.unlink()
            except OSError as exc:
                raise RuntimeError(f"could not remove incomplete download: {exc}") from exc
        return removed
    finally:
        release_repo_lock(lock)


def attempt_progress(repo: Path, before_incomplete: set[Path], total: int) -> int:
    current_complete = complete_blob_bytes(repo)
    current_partial = 0
    for file in incomplete_files(repo):
        if file not in before_incomplete:
            try:
                current_partial += file.stat().st_size
            except OSError:
                pass
    return min(total, current_complete + current_partial)


def run_download(repo_id: str, engine: str = "qwen3") -> int:
    from huggingface_hub import HfApi, snapshot_download

    root = resolve_cache_root()
    first = preflight(repo_id, engine=engine, api=HfApi(), cache_root=root)
    if first["availableBytes"] < first["requiredBytes"]:
        emit({
            "type": "error",
            "category": "storage",
            "message": "Not enough storage for the speech model.",
            "requiredBytes": first["requiredBytes"],
            "availableBytes": first["availableBytes"],
        })
        return 1

    # Repeat both metadata and capacity immediately before downloading. The
    # first response is informative; this one is the enforceable guarantee.
    second = preflight(repo_id, engine=engine, api=HfApi(), cache_root=root)
    if second["availableBytes"] < second["requiredBytes"]:
        emit({
            "type": "error",
            "category": "storage",
            "message": "Not enough storage for the speech model.",
            "requiredBytes": second["requiredBytes"],
            "availableBytes": second["availableBytes"],
        })
        return 1

    repo = repo_folder(root, repo_id)
    repo.mkdir(parents=True, exist_ok=True)
    lock = acquire_repo_lock(repo)
    if lock is None:
        emit({"type": "error", "category": "active", "message": "Another model download is active."})
        return 1

    before_incomplete = set(incomplete_files(repo))
    total = int(second["totalBytes"])
    emit({"type": "total", "bytes": total})
    done = threading.Event()

    def watch() -> None:
        while not done.is_set():
            emit({
                "type": "progress",
                "bytes": attempt_progress(repo, before_incomplete, total),
                "total": total,
            })
            done.wait(1.0)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        path = snapshot_download(
            repo_id,
            allow_patterns=list(ENGINE_PATTERNS[engine]),
            max_workers=4,
        )
    except Exception as exc:
        done.set()
        watcher.join(timeout=2.0)
        emit({"type": "error", "category": "network", "message": str(exc)})
        return 1
    finally:
        done.set()
        watcher.join(timeout=2.0)
        release_repo_lock(lock)

    final = attempt_progress(repo, before_incomplete, total)
    emit({"type": "progress", "bytes": final, "total": total})
    emit({"type": "done", "path": str(path)})
    return 0


def main() -> int:
    if len(sys.argv) not in {3, 4} or sys.argv[1] not in {"--preflight", "--cleanup", "--download"}:
        emit({
            "type": "error",
            "category": "usage",
            "message": (
                "usage: model_download.py --preflight|--cleanup|--download "
                "<repo_id> [qwen3|whisper]"
            ),
        })
        return 2
    mode, repo_id = sys.argv[1:3]
    engine = sys.argv[3] if len(sys.argv) == 4 else "qwen3"
    try:
        validate_engine(engine)
        if mode == "--preflight":
            emit(preflight(repo_id, engine=engine))
            return 0
        if mode == "--cleanup":
            root = resolve_cache_root()
            selected_repo = repo_folder(root, repo_id)
            removed_files = [file.name for file in incomplete_files(selected_repo)]
            removed = cleanup_incomplete(repo_id)
            emit({"type": "cleanup", "removedBytes": removed, "files": removed_files})
            return 0
        return run_download(repo_id, engine=engine)
    except Exception as exc:
        if isinstance(exc, CompatibilityError):
            category = "compatibility"
        elif isinstance(exc, MetadataError):
            category = "metadata"
        elif isinstance(exc, StorageCapacityError):
            category = "storage"
        else:
            category = "metadata" if mode == "--preflight" else "network"
        emit({"type": "error", "category": category, "message": str(exc)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
