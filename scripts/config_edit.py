"""Locked, compare-and-swap JSON configuration edits."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import stat
import tempfile
from pathlib import Path
from typing import Any, Callable


class ConfigEditError(RuntimeError):
    pass


class ConcurrentConfigEdit(ConfigEditError):
    pass


def _digest(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def _read_regular_user_file(path: Path) -> bytes:
    if not os.path.lexists(path):
        return b""
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ConfigEditError(f"Небезопасный config path: {path}") from error
    try:
        information = os.fstat(descriptor)
        if (
            not stat.S_ISREG(information.st_mode)
            or information.st_uid != os.geteuid()
            or information.st_nlink != 1
        ):
            raise ConfigEditError(f"Небезопасный config path: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
    finally:
        os.close(descriptor)


def _read_json(path: Path) -> tuple[bytes, dict[str, Any]]:
    existed = os.path.lexists(path)
    raw = _read_regular_user_file(path)
    if not existed:
        return b"", {}
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ConfigEditError(f"Не удалось безопасно прочитать {path}: {error}") from error
    if not isinstance(document, dict):
        raise ConfigEditError(f"{path} должен содержать JSON-объект")
    return raw, document


def update_json(
    path: Path,
    transform: Callable[[dict[str, Any]], dict[str, Any]],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.parent / f".{path.name}.codex-capslock.lock"
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        information = os.fstat(descriptor)
        if (
            not stat.S_ISREG(information.st_mode)
            or information.st_uid != os.geteuid()
            or information.st_nlink != 1
        ):
            raise ConfigEditError(f"Небезопасный config lock: {lock_path}")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)

        original, document = _read_json(path)
        original_digest = _digest(original)
        updated = transform(document)
        if not isinstance(updated, dict):
            raise ConfigEditError("Config transform должен вернуть JSON-объект")
        encoded = (
            json.dumps(updated, ensure_ascii=False, indent=2).encode("utf-8")
            + b"\n"
        )

        current = _read_regular_user_file(path)
        if _digest(current) != original_digest:
            raise ConcurrentConfigEdit(f"{path} изменился во время установки")

        file_mode = (
            stat.S_IMODE(os.lstat(path).st_mode)
            if os.path.lexists(path)
            else 0o600
        )
        temporary_descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            dir=path.parent,
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(temporary_descriptor, "wb") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            if os.path.lexists(path):
                shutil.copystat(path, temporary, follow_symlinks=False)
            os.chmod(temporary, file_mode)
            os.replace(temporary, path)
            directory_descriptor = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        finally:
            temporary.unlink(missing_ok=True)
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)
