#!/usr/bin/env python3
"""Compute WhisprStream's deterministic runtime content digest."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import struct


FORMAT_MARKER = b"whispr-runtime-tree-v1\0"


class RuntimeTreeError(ValueError):
    pass


def remove_bytecode(root: Path) -> None:
    """Remove legacy Python caches without following attacker-controlled links."""
    root = root.resolve(strict=True)
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = Path(directory)
        for name in list(names):
            if name != "__pycache__":
                continue
            cache = directory_path / name
            if cache.is_symlink():
                cache.unlink()
            else:
                shutil.rmtree(cache)
            names.remove(name)
        for name in files:
            if not name.endswith((".pyc", ".pyo")):
                continue
            bytecode = directory_path / name
            bytecode.unlink()


def _length(value: int) -> bytes:
    return struct.pack(">Q", value)


def _entries(root: Path) -> list[tuple[bytes, bytes, Path, bytes | None]]:
    root = root.resolve(strict=True)
    entries: list[tuple[bytes, bytes, Path, bytes | None]] = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = Path(directory)

        for name in list(names):
            path = directory_path / name
            relative = path.relative_to(root).as_posix().encode("utf-8")
            if path.is_symlink():
                names.remove(name)
                target = os.readlink(path).encode("utf-8")
                _validate_symlink(root, path, target)
                entries.append((relative, b"L", path, target))
                continue
            metadata = path.lstat()
            if not stat.S_ISDIR(metadata.st_mode):
                raise RuntimeTreeError(f"unsupported runtime entry: {path}")
            entries.append((relative, b"D", path, None))

        for name in files:
            path = directory_path / name
            relative = path.relative_to(root).as_posix().encode("utf-8")
            if path.is_symlink():
                target = os.readlink(path).encode("utf-8")
                _validate_symlink(root, path, target)
                entries.append((relative, b"L", path, target))
                continue
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise RuntimeTreeError(f"unsupported runtime entry: {path}")
            if metadata.st_nlink != 1:
                raise RuntimeTreeError(f"hard-linked runtime file: {path}")
            entries.append((relative, b"F", path, None))

    entries.sort(key=lambda entry: entry[0])
    return entries


def _validate_symlink(root: Path, path: Path, target: bytes) -> None:
    try:
        target_text = target.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RuntimeTreeError(f"non-UTF-8 runtime symlink: {path}") from error
    if os.path.isabs(target_text):
        raise RuntimeTreeError(f"absolute runtime symlink: {path}")
    resolved = (path.parent / target_text).resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise RuntimeTreeError(f"escaping runtime symlink: {path}") from error


def content_digest(root: Path) -> str:
    root = root.resolve(strict=True)
    digest = hashlib.sha256(FORMAT_MARKER)
    for relative, kind, path, target in _entries(root):
        digest.update(kind)
        digest.update(_length(len(relative)))
        digest.update(relative)
        if kind == b"F":
            metadata = path.lstat()
            file_digest = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    file_digest.update(chunk)
            digest.update(_length(metadata.st_size))
            digest.update(file_digest.digest())
        elif kind == b"L":
            assert target is not None
            digest.update(_length(len(target)))
            digest.update(target)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument(
        "--remove-bytecode",
        action="store_true",
        help="remove legacy __pycache__, .pyc, and .pyo entries before hashing",
    )
    args = parser.parse_args()
    if args.remove_bytecode:
        remove_bytecode(args.root)
    print(content_digest(args.root))


if __name__ == "__main__":
    main()
