#!/usr/bin/env python3
"""Build and install the Codex Caps Lock indicator for the current macOS user."""

from __future__ import annotations

import json
import os
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any


LABEL = "com.mikita.codex-capslock-indicator"
ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
CODEX_HOME = Path(os.environ.get("CODEX_HOME", HOME / ".codex")).expanduser().resolve()
HOOKS_FILE = CODEX_HOME / "hooks.json"
CONFIG_FILE = CODEX_HOME / "config.toml"
INSTALL_BIN = HOME / ".local" / "bin" / "codex-capslock-indicator"
LAUNCH_AGENT = HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"
STATE_DIR = HOME / "Library" / "Application Support" / "CodexCapsLockIndicator"
HOOK_MARKER = "codex-capslock-indicator hook "

HOOK_STATES = {
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PermissionRequest": "waiting",
    "PostToolUse": "working",
    "Stop": "done",
}


class InstallError(RuntimeError):
    pass


def run(command: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def backup_user_files() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir = CODEX_HOME / "backups" / "codex-capslock-indicator" / stamp
    backup_dir.mkdir(parents=True, exist_ok=True)
    for source in (HOOKS_FILE, CONFIG_FILE, LAUNCH_AGENT):
        if source.exists():
            shutil.copy2(source, backup_dir / source.name)
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


def install_hooks() -> None:
    if HOOKS_FILE.exists():
        try:
            document = json.loads(HOOKS_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise InstallError(f"Не удалось безопасно прочитать {HOOKS_FILE}: {error}") from error
    else:
        document = {}

    if not isinstance(document, dict):
        raise InstallError(f"{HOOKS_FILE} должен содержать JSON-объект")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise InstallError(f"Поле hooks в {HOOKS_FILE} должно быть JSON-объектом")

    # Remove older copies of this indicator from every supported or obsolete event.
    for event_name, existing_groups in list(hooks.items()):
        if not isinstance(existing_groups, list):
            raise InstallError(f"Секция {event_name} в {HOOKS_FILE} должна быть массивом")
        cleaned_groups: list[dict[str, Any]] = []
        for group in existing_groups:
            if not isinstance(group, dict):
                cleaned_groups.append(group)
                continue
            handlers = group.get("hooks", [])
            if not isinstance(handlers, list):
                cleaned_groups.append(group)
                continue
            retained = [
                handler
                for handler in handlers
                if not (
                    isinstance(handler, dict)
                    and isinstance(handler.get("command"), str)
                    and HOOK_MARKER in handler["command"]
                )
            ]
            if retained:
                updated = dict(group)
                updated["hooks"] = retained
                cleaned_groups.append(updated)

        if cleaned_groups:
            hooks[event_name] = cleaned_groups
        else:
            hooks.pop(event_name, None)

    for event_name, state in HOOK_STATES.items():
        existing_groups = hooks.get(event_name, [])
        if not isinstance(existing_groups, list):
            raise InstallError(f"Секция {event_name} в {HOOKS_FILE} должна быть массивом")
        command = f"{INSTALL_BIN} hook {state}"
        existing_groups.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
        hooks[event_name] = existing_groups

    document.setdefault("description", "User hooks, including the local Codex Caps Lock activity indicator.")
    atomic_json_write(HOOKS_FILE, document)


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
                    "version": "1.0.0",
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
                if hook.get("sourcePath") == str(HOOKS_FILE) and HOOK_MARKER in (hook.get("command") or ""):
                    discovered.append(hook)

        if len(discovered) != len(HOOK_STATES):
            warnings = [warning for row in rows for warning in row.get("warnings", [])]
            errors = [error for row in rows for error in row.get("errors", [])]
            details = "; ".join(warnings + errors) or "без дополнительных диагностик"
            raise InstallError(
                f"Codex обнаружил {len(discovered)} из {len(HOOK_STATES)} hooks ({details})"
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
            if hook.get("sourcePath") == str(HOOKS_FILE) and HOOK_MARKER in (hook.get("command") or "")
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


def start_indicator() -> int:
    process = subprocess.Popen(
        [str(INSTALL_BIN), "daemon"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return process.pid


def main() -> int:
    if sys.platform != "darwin":
        raise InstallError("Индикатор предназначен только для macOS")
    codex = shutil.which("codex")
    swift = shutil.which("swift")
    if codex is None:
        raise InstallError("Команда codex не найдена в PATH")
    if swift is None:
        raise InstallError("Swift toolchain не найден; установите Xcode Command Line Tools")

    print("1/7 Проверяю исходный код и тесты…")
    run([swift, "test"])
    print("2/7 Собираю оптимизированный бинарник…")
    run([swift, "build", "-c", "release"])

    backup_dir = backup_user_files()
    stop_launch_agent()
    stop_existing_daemon()
    LAUNCH_AGENT.unlink(missing_ok=True)

    print("3/7 Устанавливаю бинарник…")
    INSTALL_BIN.parent.mkdir(parents=True, exist_ok=True)
    built_binary = ROOT / ".build" / "release" / "codex-capslock-indicator"
    temporary_binary = INSTALL_BIN.with_name(f".{INSTALL_BIN.name}.new")
    shutil.copy2(built_binary, temporary_binary)
    os.chmod(temporary_binary, 0o755)
    os.replace(temporary_binary, INSTALL_BIN)

    print("4/7 Проверяю реальный LED и неизменность режима Caps Lock…")
    run([str(INSTALL_BIN), "self-test"])

    print("5/7 Добавляю lifecycle hooks Codex, не меняя существующий notify…")
    install_hooks()
    hook_count = trust_indicator_hooks(codex)

    print("6/7 Запускаю фоновый индикатор из пользовательского контекста…")
    expected_pid = start_indicator()

    status: subprocess.CompletedProcess[str] | None = None
    for _ in range(20):
        time.sleep(0.5)
        candidate = run([str(INSTALL_BIN), "status"], check=False, capture=True)
        output = candidate.stdout or ""
        if (
            candidate.returncode == 0
            and "Состояние:" in output
            and "Клавиатура: не найдена" not in output
            and f"PID: {expected_pid}" in output
        ):
            status = candidate
            break
    if status is None:
        raise InstallError("Фоновый процесс не получил доступ к LED клавиатуры за 10 секунд")

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    atomic_json_write(
        STATE_DIR / "installation.json",
        {
            "installedAt": datetime.now().astimezone().isoformat(),
            "binary": str(INSTALL_BIN),
            "autostart": "Codex lifecycle hook",
            "hooksFile": str(HOOKS_FILE),
            "backup": str(backup_dir),
            "hookCount": hook_count,
        },
    )

    print("7/7 Готово.")
    print(status.stdout.rstrip())
    print(f"Резервная копия конфигурации: {backup_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (InstallError, subprocess.CalledProcessError) as error:
        print(f"Ошибка установки: {error}", file=sys.stderr)
        raise SystemExit(1)
