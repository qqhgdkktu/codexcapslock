"""Recoverable user-scoped installation transaction primitives."""

from __future__ import annotations

import fcntl
import os
import shutil
import stat
import tempfile
from collections.abc import Callable
from pathlib import Path


class TransactionError(RuntimeError):
    pass


class InstallationLock:
    def __init__(self, state_directory: Path) -> None:
        self.state_directory = state_directory
        self.descriptor = -1

    def __enter__(self) -> "InstallationLock":
        self.state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        information = os.lstat(self.state_directory)
        if (
            not stat.S_ISDIR(information.st_mode)
            or information.st_uid != os.geteuid()
        ):
            raise TransactionError(
                f"Небезопасный runtime directory: {self.state_directory}"
            )
        os.chmod(self.state_directory, 0o700)
        path = self.state_directory / "install.lock"
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self.descriptor = os.open(path, flags, 0o600)
        information = os.fstat(self.descriptor)
        if (
            not stat.S_ISREG(information.st_mode)
            or information.st_uid != os.geteuid()
            or information.st_nlink != 1
        ):
            self.__exit__(None, None, None)
            raise TransactionError(f"Небезопасный installation lock: {path}")
        os.fchmod(self.descriptor, 0o600)
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self.__exit__(None, None, None)
            raise TransactionError("Установка или удаление уже выполняется") from error
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            try:
                fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            finally:
                os.close(self.descriptor)
                self.descriptor = -1


class InstallTransaction:
    def __init__(self, state_directory: Path) -> None:
        self.temporary_directory = Path(
            tempfile.mkdtemp(
                prefix=".transaction-",
                dir=state_directory,
            )
        )
        os.chmod(self.temporary_directory, 0o700)
        self.rollbacks: list[Callable[[], None]] = []
        self.finished = False

    def capture(self, path: Path) -> None:
        index = len(self.rollbacks)
        snapshot = self.temporary_directory / str(index)
        if path.is_symlink():
            raise TransactionError(f"Небезопасная цель транзакции: {path}")
        existed = path.exists()
        if existed:
            if path.is_symlink() or not path.is_file():
                raise TransactionError(f"Небезопасная цель транзакции: {path}")
            shutil.copy2(path, snapshot)
            os.chmod(snapshot, 0o600)

        def restore() -> None:
            if existed:
                path.parent.mkdir(parents=True, exist_ok=True)
                descriptor, temporary_name = tempfile.mkstemp(
                    prefix=f".{path.name}.rollback.",
                    dir=path.parent,
                )
                os.close(descriptor)
                temporary = Path(temporary_name)
                try:
                    shutil.copy2(snapshot, temporary)
                    os.replace(temporary, path)
                    directory = os.open(path.parent, os.O_RDONLY)
                    try:
                        os.fsync(directory)
                    finally:
                        os.close(directory)
                finally:
                    temporary.unlink(missing_ok=True)
            else:
                path.unlink(missing_ok=True)

        self.rollbacks.append(restore)

    def add_rollback(self, callback: Callable[[], None]) -> None:
        self.rollbacks.append(callback)

    def finish(self) -> None:
        self.finished = True

    def __enter__(self) -> "InstallTransaction":
        return self

    def __exit__(
        self,
        exception_type: object,
        exception_value: object,
        *_: object,
    ) -> None:
        rollback_error: Exception | None = None
        if exception_type is not None or not self.finished:
            for rollback in reversed(self.rollbacks):
                try:
                    rollback()
                except Exception as error:  # noqa: BLE001 - preserve all rollback attempts
                    rollback_error = rollback_error or error
        shutil.rmtree(self.temporary_directory, ignore_errors=True)
        if rollback_error is not None:
            original = f"; исходная ошибка: {exception_value}" if exception_value else ""
            raise TransactionError(
                f"Rollback завершился с ошибкой: {rollback_error}{original}"
            )
