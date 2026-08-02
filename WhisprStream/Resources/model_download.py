#!/usr/bin/env python3
"""Download a Qwen3-ASR model, reporting progress as newline-delimited JSON.

    out: {"type":"total","bytes":4012345678}
         {"type":"progress","bytes":1234567,"total":4012345678}
         {"type":"done","path":"/…/snapshots/abc"}
         {"type":"error","message":"…"}

Xet is force-disabled: on this connection it fails with `CAS Client Error:
Format error`, which is how the 1.7B originally stalled.

**This does not resume.** huggingface_hub writes every attempt to a
process-unique `<etag>.<uuid>.incomplete` (file_download.py:1920, so a broken
`flock` can't corrupt a shared file) and starts from byte zero. Disabling Xet
does not change that — verified by interrupting and restarting, which produced a
fourth `.incomplete` blob rather than continuing the third. An interrupted
download therefore costs its bytes twice, and the caller must not offer a
"Resume" button.

Progress is measured by walking the cache directory rather than hooking tqdm, so
it survives huggingface_hub version changes.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time

os.environ["HF_HUB_DISABLE_XET"] = "1"
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")


def emit(obj) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def repo_folder(cache_root: str, repo_id: str) -> str:
    return os.path.join(cache_root, "models--" + repo_id.replace("/", "--"))


def bytes_on_disk(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            p = os.path.join(root, name)
            try:
                # Follow nothing: blobs are real files, snapshot entries are
                # symlinks to them, so counting both would double every byte.
                if os.path.islink(p):
                    continue
                total += os.path.getsize(p)
            except OSError:
                pass
    return total


def main() -> int:
    if len(sys.argv) < 2:
        emit({"type": "error", "message": "usage: model_download.py <repo_id>"})
        return 2
    repo_id = sys.argv[1]

    try:
        from huggingface_hub import snapshot_download
        from huggingface_hub.constants import HF_HUB_CACHE
    except Exception as e:
        emit({"type": "error", "message": f"huggingface_hub unavailable: {e}"})
        return 1

    cache_root = HF_HUB_CACHE
    folder = repo_folder(cache_root, repo_id)

    # Ask the Hub what the finished download weighs, so progress is a real
    # fraction instead of a spinner.
    total = 0
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(repo_id, files_metadata=True)
        for f in info.siblings or []:
            if f.size:
                total += f.size
    except Exception:
        total = 0
    emit({"type": "total", "bytes": total})

    done = threading.Event()
    result = {}

    def watch() -> None:
        while not done.is_set():
            if os.path.isdir(folder):
                emit({"type": "progress", "bytes": bytes_on_disk(folder), "total": total})
            done.wait(1.0)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()

    try:
        path = snapshot_download(
            repo_id,
            allow_patterns=["*.json", "*.txt", "*.safetensors"],
            max_workers=4,
        )
        result["path"] = path
    except Exception as e:
        done.set()
        emit({"type": "error", "message": str(e)})
        return 1

    done.set()
    watcher.join(timeout=2.0)
    emit({"type": "progress", "bytes": bytes_on_disk(folder), "total": total})
    emit({"type": "done", "path": result["path"]})
    return 0


if __name__ == "__main__":
    sys.exit(main())
