#!/usr/bin/env python3
"""Build and install the Codex and Claude Code hardware indicator on macOS."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from config_edit import ConfigEditError, update_json
from hook_ownership import (
    is_indicator_hook as _is_indicator_hook,
    parse_indicator_hook as _parse_indicator_hook,
)
from privileged_subprocess import administrator_run
from transaction import InstallTransaction, InstallationLock, TransactionError


LABEL = "com.mikita.codex-capslock-indicator"
MAGSAFE_LABEL = "com.mikita.codex-capslock-indicator.magsafe"
ROOT = Path(__file__).resolve().parents[1]
USER_HOME = Path.home()
CODEX_HOME = Path(os.environ.get("CODEX_HOME", USER_HOME / ".codex")).expanduser().resolve()
HOOKS_FILE = CODEX_HOME / "hooks.json"
CONFIG_FILE = CODEX_HOME / "config.toml"
CLAUDE_HOME = Path(os.environ.get("CLAUDE_CONFIG_DIR", USER_HOME / ".claude")).expanduser().resolve()
CLAUDE_SETTINGS_FILE = CLAUDE_HOME / "settings.json"
INSTALL_BIN = USER_HOME / ".local" / "bin" / "codex-capslock-indicator"
LAUNCH_AGENT = USER_HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"
MAGSAFE_HELPER = Path("/Library/PrivilegedHelperTools") / MAGSAFE_LABEL
MAGSAFE_LAUNCH_DAEMON = Path("/Library/LaunchDaemons") / f"{MAGSAFE_LABEL}.plist"
MAGSAFE_SOCKET = Path("/var/run") / f"{MAGSAFE_LABEL}.sock"
STATE_DIR = USER_HOME / "Library" / "Application Support" / "CodexCapsLockIndicator"

CODEX_HOOKS = (
    ("UserPromptSubmit", "prompt-submitted", None),
    ("PreToolUse", "tool-started", None),
    ("PermissionRequest", "permission-requested", None),
    ("PostToolUse", "tool-finished", None),
    ("Stop", "stopped", None),
    ("SessionEnd", "session-ended", None),
)

CLAUDE_HOOKS = (
    ("UserPromptSubmit", "prompt-submitted", None),
    ("PreToolUse", "tool-started", None),
    ("PermissionRequest", "permission-requested", None),
    ("Notification", "input-requested", "permission_prompt"),
    ("PostToolUse", "tool-finished", None),
    ("PostToolUseFailure", "tool-finished", None),
    ("Stop", "stopped", None),
    ("StopFailure", "stop-failed", None),
    ("SessionEnd", "session-ended", None),
)


class InstallError(RuntimeError):
    pass


def parse_indicator_hook(command: str) -> tuple[str, str] | None:
    return _parse_indicator_hook(command, INSTALL_BIN)


def is_indicator_hook(handler: object) -> bool:
    return _is_indicator_hook(handler, INSTALL_BIN)


def run(command: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_privileged_magsafe_install_command(
    staged_helper: Path,
    staged_plist: Path,
    expected_helper_hash: str,
    expected_plist_hash: str,
) -> str:
    root_helper_staging = MAGSAFE_HELPER.with_name(f".{MAGSAFE_HELPER.name}.new")
    root_plist_staging = MAGSAFE_LAUNCH_DAEMON.with_name(
        f".{MAGSAFE_LAUNCH_DAEMON.name}.new"
    )
    root_helper_backup = MAGSAFE_HELPER.with_name(f".{MAGSAFE_HELPER.name}.previous")
    root_plist_backup = MAGSAFE_LAUNCH_DAEMON.with_name(
        f".{MAGSAFE_LAUNCH_DAEMON.name}.previous"
    )
    cleanup = shlex.join([
        "/bin/rm",
        "-f",
        str(root_helper_staging),
        str(root_plist_staging),
        str(root_helper_backup),
        str(root_plist_backup),
    ])
    bootout = shlex.join(
        ["/bin/launchctl", "bootout", "system", str(MAGSAFE_LAUNCH_DAEMON)]
    )
    bootstrap = shlex.join(
        ["/bin/launchctl", "bootstrap", "system", str(MAGSAFE_LAUNCH_DAEMON)]
    )
    rollback = "; ".join(
        [
            "status=$?",
            (
                'if /bin/test "$status" -ne 0 '
                '&& /bin/test "${commit_started:-0}" -eq 1; then '
                f"({bootout} >/dev/null 2>&1 || true); "
                f"if /bin/test -f {shlex.quote(str(root_helper_backup))}; "
                f"then /bin/mv -f {shlex.quote(str(root_helper_backup))} "
                f"{shlex.quote(str(MAGSAFE_HELPER))}; "
                f"else /bin/rm -f {shlex.quote(str(MAGSAFE_HELPER))}; fi; "
                f"if /bin/test -f {shlex.quote(str(root_plist_backup))}; "
                f"then /bin/mv -f {shlex.quote(str(root_plist_backup))} "
                f"{shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))}; "
                f"({bootstrap} >/dev/null 2>&1 || true); "
                f"else /bin/rm -f {shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))}; fi; "
                "fi"
            ),
            cleanup,
            'exit "$status"',
        ]
    )

    def verify_hash(path: Path, expected_hash: str, variable: str) -> str:
        assignment = (
            f"{variable}=$(/usr/bin/shasum -a 256 {shlex.quote(str(path))})"
        )
        comparison = (
            f'/bin/test "${{{variable}%% *}}" = {shlex.quote(expected_hash)}'
        )
        return f"{assignment} && {comparison}"

    commands = [
        f"trap {shlex.quote(rollback)} EXIT",
        "commit_started=0",
        shlex.join([
            "/usr/bin/install",
            "-d",
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            "755",
            str(MAGSAFE_HELPER.parent),
        ]),
        cleanup,
        (
            f"if /bin/test -f {shlex.quote(str(MAGSAFE_HELPER))}; "
            f"then /bin/cp -p {shlex.quote(str(MAGSAFE_HELPER))} "
            f"{shlex.quote(str(root_helper_backup))}; fi"
        ),
        (
            f"if /bin/test -f {shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))}; "
            f"then /bin/cp -p {shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))} "
            f"{shlex.quote(str(root_plist_backup))}; fi"
        ),
        shlex.join([
            "/usr/bin/install",
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            "755",
            str(staged_helper),
            str(root_helper_staging),
        ]),
        verify_hash(root_helper_staging, expected_helper_hash, "helper_hash"),
        shlex.join([
            "/usr/bin/install",
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            "644",
            str(staged_plist),
            str(root_plist_staging),
        ]),
        verify_hash(root_plist_staging, expected_plist_hash, "plist_hash"),
        "commit_started=1",
        f"({bootout} >/dev/null 2>&1 || true)",
        shlex.join(["/bin/mv", "-f", str(root_helper_staging), str(MAGSAFE_HELPER)]),
        shlex.join(["/bin/mv", "-f", str(root_plist_staging), str(MAGSAFE_LAUNCH_DAEMON)]),
        bootstrap,
        cleanup,
        "trap - EXIT",
    ]
    return " && ".join(commands)


def capture_magsafe_state(transaction_directory: Path) -> dict[str, Path | None]:
    captured: dict[str, Path | None] = {}
    for label, source in (
        ("helper", MAGSAFE_HELPER),
        ("plist", MAGSAFE_LAUNCH_DAEMON),
    ):
        if not os.path.lexists(source):
            captured[label] = None
            continue
        if source.is_symlink() or not source.is_file():
            raise InstallError(f"Небезопасный системный компонент: {source}")
        destination = transaction_directory / f"magsafe-{label}.previous"
        shutil.copy2(source, destination)
        os.chmod(destination, 0o600)
        captured[label] = destination
    return captured


def restore_magsafe_state(captured: dict[str, Path | None]) -> None:
    helper = captured["helper"]
    plist = captured["plist"]
    bootout = shlex.join(
        ["/bin/launchctl", "bootout", "system", str(MAGSAFE_LAUNCH_DAEMON)]
    )
    commands = [f"({bootout} >/dev/null 2>&1 || true)"]
    if helper is None:
        commands.append(shlex.join(["/bin/rm", "-f", str(MAGSAFE_HELPER)]))
    else:
        commands.append(
            shlex.join([
                "/usr/bin/install",
                "-o",
                "root",
                "-g",
                "wheel",
                "-m",
                "755",
                str(helper),
                str(MAGSAFE_HELPER),
            ])
        )
    if plist is None:
        commands.append(
            shlex.join(["/bin/rm", "-f", str(MAGSAFE_LAUNCH_DAEMON)])
        )
    else:
        commands.append(
            shlex.join([
                "/usr/bin/install",
                "-o",
                "root",
                "-g",
                "wheel",
                "-m",
                "644",
                str(plist),
                str(MAGSAFE_LAUNCH_DAEMON),
            ])
        )
    commands.append(shlex.join(["/bin/rm", "-f", str(MAGSAFE_SOCKET)]))
    if helper is not None and plist is not None:
        commands.append(
            shlex.join([
                "/bin/launchctl",
                "bootstrap",
                "system",
                str(MAGSAFE_LAUNCH_DAEMON),
            ])
        )
    administrator_run(" && ".join(commands), cwd=ROOT)


def backup_user_files() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup_root = CODEX_HOME / "backups" / "codex-capslock-indicator"
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(backup_root, 0o700)
    backup_dir = backup_root / stamp
    backup_dir.mkdir(mode=0o700)
    os.chmod(backup_dir, 0o700)
    manifest: list[dict[str, Any]] = []
    for source in (HOOKS_FILE, CONFIG_FILE, LAUNCH_AGENT, MAGSAFE_LAUNCH_DAEMON):
        if source.exists():
            if source.is_symlink() or not source.is_file():
                raise InstallError(f"Небезопасный файл для backup: {source}")
            destination = backup_dir / source.name
            destination.write_bytes(source.read_bytes())
            os.chmod(destination, 0o600)
            information = source.stat()
            manifest.append(
                {
                    "originalPath": str(source),
                    "backupFile": destination.name,
                    "sha256": sha256(source),
                    "mode": oct(information.st_mode & 0o777),
                    "uid": information.st_uid,
                    "gid": information.st_gid,
                }
            )
    if CLAUDE_SETTINGS_FILE.exists():
        if CLAUDE_SETTINGS_FILE.is_symlink() or not CLAUDE_SETTINGS_FILE.is_file():
            raise InstallError(f"Небезопасный файл для backup: {CLAUDE_SETTINGS_FILE}")
        destination = backup_dir / "claude-settings.json"
        destination.write_bytes(CLAUDE_SETTINGS_FILE.read_bytes())
        os.chmod(destination, 0o600)
        information = CLAUDE_SETTINGS_FILE.stat()
        manifest.append(
            {
                "originalPath": str(CLAUDE_SETTINGS_FILE),
                "backupFile": destination.name,
                "sha256": sha256(CLAUDE_SETTINGS_FILE),
                "mode": oct(information.st_mode & 0o777),
                "uid": information.st_uid,
                "gid": information.st_gid,
            }
        )
    atomic_json_write(backup_dir / "manifest.json", {"files": manifest})
    return backup_dir


def atomic_json_write(path: Path, value: dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def install_lifecycle_hooks(
    settings_file: Path,
    hook_specs: tuple[tuple[str, str, str | None], ...],
    source: str,
    *,
    description: str | None = None,
) -> int:
    def transform(document: dict[str, Any]) -> dict[str, Any]:
        hooks = document.setdefault("hooks", {})
        if not isinstance(hooks, dict):
            raise InstallError(f"Поле hooks в {settings_file} должно быть JSON-объектом")

        for event_name, existing_groups in list(hooks.items()):
            if not isinstance(existing_groups, list):
                raise InstallError(
                    f"Секция {event_name} в {settings_file} должна быть массивом"
                )
            cleaned_groups: list[object] = []
            for group in existing_groups:
                if not isinstance(group, dict):
                    cleaned_groups.append(group)
                    continue
                handlers = group.get("hooks")
                if not isinstance(handlers, list):
                    cleaned_groups.append(group)
                    continue
                retained = [handler for handler in handlers if not is_indicator_hook(handler)]
                if retained:
                    updated = dict(group)
                    updated["hooks"] = retained
                    cleaned_groups.append(updated)

            if cleaned_groups:
                hooks[event_name] = cleaned_groups
            else:
                hooks.pop(event_name, None)

        for event_name, action, matcher in hook_specs:
            existing_groups = hooks.get(event_name, [])
            if not isinstance(existing_groups, list):
                raise InstallError(
                    f"Секция {event_name} в {settings_file} должна быть массивом"
                )
            command = f"{shlex.quote(str(INSTALL_BIN))} hook {action} {source}"
            group: dict[str, Any] = {
                "hooks": [{"type": "command", "command": command, "timeout": 5}]
            }
            if matcher is not None:
                group["matcher"] = matcher
            existing_groups.append(group)
            hooks[event_name] = existing_groups

        if description is not None:
            document.setdefault("description", description)
        return document

    try:
        update_json(settings_file, transform)
    except ConfigEditError as error:
        raise InstallError(str(error)) from error
    return len(hook_specs)


def install_codex_hooks() -> int:
    return install_lifecycle_hooks(
        HOOKS_FILE,
        CODEX_HOOKS,
        "codex",
        description="User hooks, including the local Codex Caps Lock activity indicator.",
    )


def install_claude_hooks() -> int:
    return install_lifecycle_hooks(CLAUDE_SETTINGS_FILE, CLAUDE_HOOKS, "claude")


class AppServerClient:
    def __init__(self, codex: str) -> None:
        self.process = subprocess.Popen(
            [codex, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        if self.process.stdin is None or self.process.stdout is None:
            raise InstallError("Не удалось открыть канал к codex app-server")
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.next_id = 1
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.stdout, selectors.EVENT_READ)

        self.request(
            "initialize",
            {
                "clientInfo": {
                    "name": "codex_capslock_indicator_installer",
                    "title": "Codex Caps Lock Indicator Installer",
                    "version": "2.0.0",
                }
            },
        )
        self.notify("initialized", {})

    def close(self) -> None:
        try:
            self.stdin.close()
        except OSError:
            pass
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.selector.close()

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self.stdin.write(json.dumps({"method": method, "params": params}) + "\n")
        self.stdin.flush()

    def request(self, method: str, params: dict[str, Any], timeout: float = 20) -> Any:
        request_id = self.next_id
        self.next_id += 1
        self.stdin.write(json.dumps({"method": method, "id": request_id, "params": params}) + "\n")
        self.stdin.flush()

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = max(0.0, deadline - time.monotonic())
            if not self.selector.select(remaining):
                break
            line = self.stdout.readline()
            if not line:
                break
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise InstallError(f"codex app-server отклонил {method}: {message['error']}")
            return message.get("result")
        raise InstallError(f"codex app-server не ответил на {method} за {timeout:.0f} секунд")


def trust_indicator_hooks(codex: str) -> int:
    client = AppServerClient(codex)
    try:
        result = client.request("hooks/list", {"cwds": [str(ROOT)]})
        rows = (result or {}).get("data", [])
        discovered = []
        for row in rows:
            for hook in row.get("hooks", []):
                if (
                    hook.get("sourcePath") == str(HOOKS_FILE)
                    and isinstance(hook.get("command"), str)
                    and parse_indicator_hook(hook["command"]) is not None
                ):
                    discovered.append(hook)

        if len(discovered) != len(CODEX_HOOKS):
            warnings = [warning for row in rows for warning in row.get("warnings", [])]
            errors = [error for row in rows for error in row.get("errors", [])]
            details = "; ".join(warnings + errors) or "без дополнительных диагностик"
            raise InstallError(
                f"Codex обнаружил {len(discovered)} из {len(CODEX_HOOKS)} hooks ({details})"
            )

        state = {
            hook["key"]: {"enabled": True, "trusted_hash": hook["currentHash"]}
            for hook in discovered
        }
        client.request(
            "config/batchWrite",
            {
                "edits": [{"keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"}],
                "reloadUserConfig": True,
            },
        )

        verified = client.request("hooks/list", {"cwds": [str(ROOT)]})
        verified_hooks = [
            hook
            for row in (verified or {}).get("data", [])
            for hook in row.get("hooks", [])
            if (
                hook.get("sourcePath") == str(HOOKS_FILE)
                and isinstance(hook.get("command"), str)
                and parse_indicator_hook(hook["command"]) is not None
            )
        ]
        untrusted = [hook for hook in verified_hooks if hook.get("trustStatus") != "trusted" or not hook.get("enabled")]
        if untrusted:
            raise InstallError("Codex не подтвердил доверие к одному или нескольким hooks")
        return len(verified_hooks)
    finally:
        client.close()


def stop_launch_agent() -> None:
    domain = f"gui/{os.getuid()}"
    subprocess.run(
        ["/bin/launchctl", "bootout", domain, str(LAUNCH_AGENT)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def stop_existing_daemon() -> None:
    status_file = STATE_DIR / "status.json"
    try:
        status = json.loads(status_file.read_text(encoding="utf-8"))
        pid = int(status["pid"])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return

    probe = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "command="],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if str(INSTALL_BIN) not in probe.stdout or " daemon" not in probe.stdout:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    for _ in range(25):
        time.sleep(0.2)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
    raise InstallError(f"Фоновый индикатор PID {pid} не завершился после SIGTERM")


def magsafe_port_present() -> bool:
    for class_name in ("AppleHPMInterfaceType11", "AppleTCControllerType11"):
        probe = subprocess.run(
            ["/usr/sbin/ioreg", "-r", "-c", class_name, "-l"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if '"PortType" = 17' in probe.stdout or "Port-MagSafe" in probe.stdout:
            return True
    return False


def install_magsafe_helper() -> str:
    built_helper = ROOT / ".build" / "release" / "codex-capslock-magsafe-helper"
    if not built_helper.exists():
        raise InstallError("Release-бинарник помощника MagSafe не найден")

    document = {
        "Label": MAGSAFE_LABEL,
        "ProgramArguments": [str(MAGSAFE_HELPER)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "Nice": 10,
        "LowPriorityIO": True,
        "ThrottleInterval": 10,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }
    expected_hash = sha256(built_helper)
    try:
        installed_document = plistlib.loads(MAGSAFE_LAUNCH_DAEMON.read_bytes())
        installed_is_current = (
            sha256(MAGSAFE_HELPER) == expected_hash
            and installed_document == document
        )
    except (OSError, ValueError, plistlib.InvalidFileException):
        installed_is_current = False

    if installed_is_current:
        probe = run([str(INSTALL_BIN), "magsafe", "probe"], check=False, capture=True)
        if probe.returncode == 0:
            print("   Помощник MagSafe уже актуален; системное окно не требуется.")
            return expected_hash

    print("   Для управления SMC macOS покажет защищённое окно администратора.")
    staging_directory = Path(tempfile.mkdtemp(prefix=f"{MAGSAFE_LABEL}.", dir="/private/tmp"))
    staged_helper = staging_directory / "helper"
    temporary_plist = staging_directory / f"{MAGSAFE_LABEL}.plist"
    try:
        shutil.copy2(built_helper, staged_helper)
        os.chmod(staged_helper, 0o755)
        with temporary_plist.open("wb") as handle:
            plistlib.dump(document, handle, fmt=plistlib.FMT_XML, sort_keys=True)
        administrator_run(
            build_privileged_magsafe_install_command(
                staged_helper,
                temporary_plist,
                expected_hash,
                sha256(temporary_plist),
            ),
            cwd=ROOT,
        )
    finally:
        shutil.rmtree(staging_directory, ignore_errors=True)

    installed_hash = sha256(MAGSAFE_HELPER)
    if installed_hash != expected_hash:
        raise InstallError("Хеш установленного помощника MagSafe не совпал с release-сборкой")

    for _ in range(20):
        time.sleep(0.25)
        probe = run([str(INSTALL_BIN), "magsafe", "probe"], check=False, capture=True)
        if probe.returncode == 0:
            return installed_hash
    raise InstallError("Привилегированный помощник MagSafe не ответил за 5 секунд")


def parse_arguments(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and install Codex Caps Lock Indicator.",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument(
        "--caps-lock-only",
        action="store_true",
        help="install without the root MagSafe helper or administrator prompt",
    )
    output.add_argument(
        "--magsafe",
        action="store_true",
        help="require a supported MagSafe port and helper installation",
    )
    output.add_argument(
        "--auto",
        action="store_true",
        help="select MagSafe when supported, otherwise Caps Lock (default)",
    )
    parser.add_argument(
        "--no-hardware-test",
        action="store_true",
        help="skip the visible self-test with an explicit warning",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show the preflight and intended changes without modifying files",
    )
    return parser.parse_args(arguments)


def _swift_version(swift: str) -> tuple[int, int, int]:
    output = run([swift, "--version"], capture=True).stdout
    match = re.search(r"Swift version (\d+)\.(\d+)(?:\.(\d+))?", output)
    if match is None:
        raise InstallError(f"Не удалось определить версию Swift: {output.strip()}")
    return tuple(int(value or 0) for value in match.groups())  # type: ignore[return-value]


def _validate_json_object(path: Path) -> None:
    if not path.exists():
        return
    if path.is_symlink() or not path.is_file():
        raise InstallError(f"Небезопасный config path: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InstallError(f"Некорректный JSON в {path}: {error}") from error
    if not isinstance(document, dict):
        raise InstallError(f"{path} должен содержать JSON-объект")


def preflight(options: argparse.Namespace) -> dict[str, Any]:
    if sys.platform != "darwin":
        raise InstallError("Индикатор предназначен только для macOS")
    mac_version_text = platform.mac_ver()[0]
    mac_version = tuple(
        int(part) for part in (mac_version_text.split(".") + ["0", "0"])[:3]
    )
    if mac_version < (14, 0, 0):
        raise InstallError("Требуется macOS 14 или новее")
    if sys.version_info < (3, 10):
        raise InstallError("Требуется Python 3.10 или новее")

    codex = shutil.which("codex")
    claude = shutil.which("claude")
    swift = shutil.which("swift")
    if codex is None and claude is None:
        raise InstallError("Не найдены ни Codex, ни Claude Code; установите хотя бы один агент")
    if swift is None:
        raise InstallError("Swift toolchain не найден; установите Xcode Command Line Tools")
    swift_version = _swift_version(swift)
    if swift_version < (6, 2, 0):
        raise InstallError("Требуется Swift 6.2 или новее")

    if STATE_DIR.exists() and (STATE_DIR.is_symlink() or not STATE_DIR.is_dir()):
        raise InstallError(f"Небезопасный runtime directory: {STATE_DIR}")
    _validate_json_object(HOOKS_FILE)
    _validate_json_object(CLAUDE_SETTINGS_FILE)
    free_bytes = shutil.disk_usage(USER_HOME).free
    if free_bytes < 100 * 1024 * 1024:
        raise InstallError("Для сборки и rollback требуется минимум 100 MiB свободного места")

    mag_safe_port = magsafe_port_present()
    if options.magsafe and not mag_safe_port:
        raise InstallError("Запрошен MagSafe mode, но физический порт MagSafe не найден")

    return {
        "macOS": mac_version_text,
        "python": platform.python_version(),
        "swift": ".".join(str(part) for part in swift_version),
        "codex": codex,
        "claude": claude,
        "magSafePortPresent": mag_safe_port,
        "outputMode": "caps-lock"
        if options.caps_lock_only
        else ("magsafe" if options.magsafe else "auto"),
        "freeBytes": free_bytes,
    }


def launch_agent_document(output_mode: str) -> dict[str, Any]:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "CODEX_CAPS_INDICATOR_OUTPUT": output_mode,
    }
    if CODEX_HOME != USER_HOME / ".codex":
        environment["CODEX_HOME"] = str(CODEX_HOME)
    return {
        "Label": LABEL,
        "ProgramArguments": [str(INSTALL_BIN), "daemon"],
        "EnvironmentVariables": environment,
        "RunAtLoad": False,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Background",
        "ThrottleInterval": 2,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }


def write_launch_agent(output_mode: str) -> None:
    LAUNCH_AGENT.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{LAUNCH_AGENT.name}.",
        dir=LAUNCH_AGENT.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            plistlib.dump(
                launch_agent_document(output_mode),
                handle,
                fmt=plistlib.FMT_XML,
                sort_keys=True,
            )
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, LAUNCH_AGENT)
    finally:
        temporary.unlink(missing_ok=True)


def start_launch_agent() -> None:
    domain = f"gui/{os.getuid()}"
    run(
        ["/bin/launchctl", "bootstrap", domain, str(LAUNCH_AGENT)],
    )
    run(
        ["/bin/launchctl", "kickstart", f"{domain}/{LABEL}"],
    )


def restore_previous_launch_agent() -> None:
    stop_launch_agent()
    if LAUNCH_AGENT.exists():
        domain = f"gui/{os.getuid()}"
        subprocess.run(
            [
                "/bin/launchctl",
                "bootstrap",
                domain,
                str(LAUNCH_AGENT),
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["/bin/launchctl", "kickstart", f"{domain}/{LABEL}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def install_user_binary() -> str:
    INSTALL_BIN.parent.mkdir(parents=True, exist_ok=True)
    built_binary = ROOT / ".build" / "release" / "codex-capslock-indicator"
    temporary_binary = INSTALL_BIN.with_name(f".{INSTALL_BIN.name}.new")
    shutil.copy2(built_binary, temporary_binary)
    os.chmod(temporary_binary, 0o755)
    os.replace(temporary_binary, INSTALL_BIN)
    installed_hash = sha256(INSTALL_BIN)
    if installed_hash != sha256(built_binary):
        raise InstallError("Хеш установленного бинарника не совпал с release-сборкой")
    return installed_hash


def wait_for_indicator(output_mode: str) -> subprocess.CompletedProcess[str]:
    status: subprocess.CompletedProcess[str] | None = None
    for _ in range(20):
        time.sleep(0.5)
        candidate = run([str(INSTALL_BIN), "status"], check=False, capture=True)
        output = candidate.stdout or ""
        if (
            candidate.returncode == 0
            and "Состояние:" in output
            and "Клавиатура: не найдена" not in output
            and "PID:" in output
            and (
                output_mode == "auto"
                or (
                    output_mode == "caps-lock"
                    and "Индикатор: Caps Lock" in output
                )
                or (
                    output_mode == "magsafe"
                    and "Индикатор: MagSafe" in output
                )
            )
        ):
            status = candidate
            break
    if status is None:
        raise InstallError("LaunchAgent не получил доступ к аппаратному индикатору за 10 секунд")

    processes = subprocess.run(
        ["/bin/ps", "-axo", "pid=,command="],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.splitlines()
    daemon_rows = [
        row
        for row in processes
        if str(INSTALL_BIN) in row and row.rstrip().endswith(" daemon")
    ]
    if len(daemon_rows) != 1:
        raise InstallError(
            f"Ожидался один установленный daemon, обнаружено: {len(daemon_rows)}"
        )
    return status


def main(arguments: list[str] | None = None) -> int:
    options = parse_arguments(arguments)
    report = preflight(options)
    if options.dry_run:
        print("Preflight OK; изменений не выполнено.")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"Будет установлен бинарник: {INSTALL_BIN}")
        print(f"Будут обновлены hooks: {HOOKS_FILE}, {CLAUDE_SETTINGS_FILE}")
        print(f"Будет установлен LaunchAgent: {LAUNCH_AGENT}")
        return 0

    codex = report["codex"]
    claude = report["claude"]
    swift = shutil.which("swift")
    assert isinstance(swift, str)
    mag_safe_port = bool(report["magSafePortPresent"])
    output_mode = str(report["outputMode"])

    with InstallationLock(STATE_DIR):
        print("1/10 Проверяю исходный код и тесты…")
        run([swift, "test"])
        print("2/10 Собираю оптимизированные бинарники…")
        run([swift, "build", "-c", "release"])

        backup_dir = backup_user_files()
        with InstallTransaction(STATE_DIR) as transaction:
            transaction.add_rollback(restore_previous_launch_agent)
            for path in (
                INSTALL_BIN,
                LAUNCH_AGENT,
                HOOKS_FILE,
                CLAUDE_SETTINGS_FILE,
                STATE_DIR / "installation.json",
            ):
                transaction.capture(path)

            stop_launch_agent()
            stop_existing_daemon()

            print("3/10 Устанавливаю основной бинарник и crash-supervised LaunchAgent…")
            installed_binary_hash = install_user_binary()
            write_launch_agent(output_mode)

            print("4/10 Настраиваю MagSafe policy…")
            mag_safe_helper_hash: str | None = None
            should_install_magsafe = (
                not options.caps_lock_only and mag_safe_port
            )
            if should_install_magsafe:
                captured_magsafe = capture_magsafe_state(
                    transaction.temporary_directory
                )
                transaction.add_rollback(
                    lambda: restore_magsafe_state(captured_magsafe)
                )
                mag_safe_helper_hash = install_magsafe_helper()
                print("   Помощник MagSafe protocol v2 готов и отвечает.")
            elif options.caps_lock_only:
                print("   Caps-Lock-only: root helper не устанавливается.")
            else:
                print("   Порт MagSafe не найден — остаётся режим Caps Lock.")

            print("5/10 Проверяю реальные LED и неизменность режима Caps Lock…")
            if options.no_hardware_test:
                print("   ВНИМАНИЕ: hardware self-test пропущен по явному флагу.")
            else:
                run([str(INSTALL_BIN), "self-test"])

            print("6/10 Добавляю exact lifecycle hooks, сохраняя чужие настройки…")
            install_codex_hooks()
            claude_hook_count = install_claude_hooks()
            if codex is None:
                codex_hook_count = 0
                print("   Codex не найден; hooks записаны, trust будет нужен позже.")
            else:
                codex_hook_count = trust_indicator_hooks(str(codex))
            if claude is None:
                print("   Claude Code не найден; hooks готовы к будущей установке.")
            else:
                version = run(
                    [str(claude), "--version"],
                    check=False,
                    capture=True,
                ).stdout.strip()
                print(f"   Claude Code найден: {version or claude}")

            print("7/10 Запускаю crash-supervised LaunchAgent…")
            (STATE_DIR / "status.json").unlink(missing_ok=True)
            start_launch_agent()

            print("8/10 Проверяю daemon, output и установленные хеши…")
            status = wait_for_indicator(output_mode)
            installed_version = run(
                [str(INSTALL_BIN), "--version"],
                capture=True,
            ).stdout.strip()
            if installed_version != "2.0.0":
                raise InstallError(
                    f"Установлена неожиданная версия: {installed_version}"
                )

            print("9/10 Записываю проверенный installation manifest…")
            STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(STATE_DIR, 0o700)
            atomic_json_write(
                STATE_DIR / "installation.json",
                {
                    "installedAt": datetime.now().astimezone().isoformat(),
                    "version": installed_version,
                    "binary": str(INSTALL_BIN),
                    "binarySHA256": installed_binary_hash,
                    "autostart": "LaunchAgent crash supervision + lifecycle hook kickstart",
                    "launchAgent": str(LAUNCH_AGENT),
                    "outputMode": output_mode,
                    "codexHooksFile": str(HOOKS_FILE),
                    "claudeSettingsFile": str(CLAUDE_SETTINGS_FILE),
                    "backup": str(backup_dir),
                    "codexHookCount": codex_hook_count,
                    "codexHooksTrusted": codex is not None,
                    "claudeHookCount": claude_hook_count,
                    "magSafePortPresent": mag_safe_port,
                    "magSafeProtocolVersion": 2 if mag_safe_helper_hash else None,
                    "magSafeHelper": str(MAGSAFE_HELPER)
                    if mag_safe_helper_hash
                    else None,
                    "magSafeHelperSHA256": mag_safe_helper_hash,
                },
            )
            transaction.finish()

        print("10/10 Готово.")
        print(status.stdout.rstrip())
        print(f"Резервная копия конфигурации: {backup_dir}")
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        ConfigEditError,
        InstallError,
        TransactionError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Ошибка установки: {error}", file=sys.stderr)
        raise SystemExit(1)
