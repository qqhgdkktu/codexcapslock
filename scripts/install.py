#!/usr/bin/env python3
"""Build and install the Codex and Claude Code hardware indicator on macOS."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
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


LABEL = "com.mikita.codex-capslock-indicator"
MAGSAFE_LABEL = "com.mikita.codex-capslock-indicator.magsafe"
ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
CODEX_HOME = Path(os.environ.get("CODEX_HOME", HOME / ".codex")).expanduser().resolve()
HOOKS_FILE = CODEX_HOME / "hooks.json"
CONFIG_FILE = CODEX_HOME / "config.toml"
CLAUDE_HOME = Path(os.environ.get("CLAUDE_CONFIG_DIR", HOME / ".claude")).expanduser().resolve()
CLAUDE_SETTINGS_FILE = CLAUDE_HOME / "settings.json"
INSTALL_BIN = HOME / ".local" / "bin" / "codex-capslock-indicator"
LAUNCH_AGENT = HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"
MAGSAFE_HELPER = Path("/Library/PrivilegedHelperTools") / MAGSAFE_LABEL
MAGSAFE_LAUNCH_DAEMON = Path("/Library/LaunchDaemons") / f"{MAGSAFE_LABEL}.plist"
MAGSAFE_SOCKET = Path("/var/run") / f"{MAGSAFE_LABEL}.sock"
STATE_DIR = HOME / "Library" / "Application Support" / "CodexCapsLockIndicator"
HOOK_MARKER = "codex-capslock-indicator hook "

CODEX_HOOKS = (
    ("UserPromptSubmit", "working", None),
    ("PreToolUse", "working", None),
    ("PermissionRequest", "waiting", None),
    ("PostToolUse", "working", None),
    ("Stop", "done", None),
)

CLAUDE_HOOKS = (
    ("UserPromptSubmit", "working", None),
    ("PreToolUse", "working", None),
    ("PermissionRequest", "waiting", None),
    ("Notification", "waiting", "permission_prompt"),
    ("PostToolUse", "working", None),
    ("Stop", "done", None),
    ("StopFailure", "done", None),
)


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


def administrator_run(shell_command: str) -> subprocess.CompletedProcess[str]:
    apple_script = (
        f"do shell script {json.dumps(shell_command, ensure_ascii=False)} "
        "with administrator privileges"
    )
    return subprocess.run(
        ["/usr/bin/osascript", "-e", apple_script],
        cwd=ROOT,
        check=True,
        text=True,
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def backup_user_files() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir = CODEX_HOME / "backups" / "codex-capslock-indicator" / stamp
    backup_dir.mkdir(parents=True, exist_ok=True)
    for source in (HOOKS_FILE, CONFIG_FILE, LAUNCH_AGENT, MAGSAFE_LAUNCH_DAEMON):
        if source.exists():
            shutil.copy2(source, backup_dir / source.name)
    if CLAUDE_SETTINGS_FILE.exists():
        shutil.copy2(CLAUDE_SETTINGS_FILE, backup_dir / "claude-settings.json")
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
    if settings_file.exists():
        try:
            document = json.loads(settings_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise InstallError(f"Не удалось безопасно прочитать {settings_file}: {error}") from error
    else:
        document = {}

    if not isinstance(document, dict):
        raise InstallError(f"{settings_file} должен содержать JSON-объект")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise InstallError(f"Поле hooks в {settings_file} должно быть JSON-объектом")

    # Remove older copies of this indicator from every supported or obsolete event.
    for event_name, existing_groups in list(hooks.items()):
        if not isinstance(existing_groups, list):
            raise InstallError(f"Секция {event_name} в {settings_file} должна быть массивом")
        cleaned_groups: list[dict[str, Any]] = []
        for group in existing_groups:
            if not isinstance(group, dict):
                cleaned_groups.append(group)
                continue
            handlers = group.get("hooks")
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

    for event_name, state, matcher in hook_specs:
        existing_groups = hooks.get(event_name, [])
        if not isinstance(existing_groups, list):
            raise InstallError(f"Секция {event_name} в {settings_file} должна быть массивом")
        command = f"{shlex.quote(str(INSTALL_BIN))} hook {state} {source}"
        group: dict[str, Any] = {
            "hooks": [{"type": "command", "command": command, "timeout": 5}]
        }
        if matcher is not None:
            group["matcher"] = matcher
        existing_groups.append(group)
        hooks[event_name] = existing_groups

    if description is not None:
        document.setdefault("description", description)
    atomic_json_write(settings_file, document)
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
                    "version": "1.3.0",
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

        privileged_commands = [
            f"({shlex.join(['/bin/launchctl', 'bootout', 'system', str(MAGSAFE_LAUNCH_DAEMON)])} >/dev/null 2>&1 || true)",
            shlex.join(["/usr/bin/install", "-d", "-o", "root", "-g", "wheel", "-m", "755", str(MAGSAFE_HELPER.parent)]),
            shlex.join(["/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "755", str(staged_helper), str(MAGSAFE_HELPER)]),
            shlex.join(["/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "644", str(temporary_plist), str(MAGSAFE_LAUNCH_DAEMON)]),
            shlex.join(["/bin/launchctl", "bootstrap", "system", str(MAGSAFE_LAUNCH_DAEMON)]),
        ]
        administrator_run(" && ".join(privileged_commands))
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
    claude = shutil.which("claude")
    swift = shutil.which("swift")
    if codex is None and claude is None:
        raise InstallError("Не найдены ни Codex, ни Claude Code; установите хотя бы один агент")
    if swift is None:
        raise InstallError("Swift toolchain не найден; установите Xcode Command Line Tools")

    print("1/9 Проверяю исходный код и тесты…")
    run([swift, "test"])
    print("2/9 Собираю оптимизированные бинарники…")
    run([swift, "build", "-c", "release"])

    backup_dir = backup_user_files()
    stop_launch_agent()
    stop_existing_daemon()
    LAUNCH_AGENT.unlink(missing_ok=True)

    print("3/9 Устанавливаю основной бинарник…")
    INSTALL_BIN.parent.mkdir(parents=True, exist_ok=True)
    built_binary = ROOT / ".build" / "release" / "codex-capslock-indicator"
    temporary_binary = INSTALL_BIN.with_name(f".{INSTALL_BIN.name}.new")
    shutil.copy2(built_binary, temporary_binary)
    os.chmod(temporary_binary, 0o755)
    os.replace(temporary_binary, INSTALL_BIN)

    print("4/9 Настраиваю управление MagSafe, если порт есть…")
    mag_safe_port = magsafe_port_present()
    mag_safe_helper_hash: str | None = None
    if mag_safe_port:
        mag_safe_helper_hash = install_magsafe_helper()
        print("   Помощник MagSafe готов и отвечает.")
    else:
        print("   Порт MagSafe не найден — остаётся режим Caps Lock.")

    print("5/9 Проверяю реальные LED и неизменность режима Caps Lock…")
    run([str(INSTALL_BIN), "self-test"])

    print("6/9 Добавляю lifecycle hooks Codex и Claude Code, сохраняя чужие настройки…")
    install_codex_hooks()
    claude_hook_count = install_claude_hooks()
    if codex is None:
        codex_hook_count = 0
        print("   Codex пока не найден; его hooks записаны, но после установки Codex запустите установщик повторно для доверия.")
    else:
        codex_hook_count = trust_indicator_hooks(codex)
    if claude is None:
        print("   Claude Code пока не найден; hooks уже готовы к его будущей установке.")
    else:
        version = run([claude, "--version"], check=False, capture=True).stdout.strip()
        print(f"   Claude Code найден: {version or claude}")

    print("7/9 Запускаю фоновый индикатор из пользовательского контекста…")
    expected_pid = start_indicator()

    print("8/9 Проверяю выбранный индикатор и фоновый процесс…")
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
            "autostart": "Codex or Claude Code lifecycle hook",
            "codexHooksFile": str(HOOKS_FILE),
            "claudeSettingsFile": str(CLAUDE_SETTINGS_FILE),
            "backup": str(backup_dir),
            "codexHookCount": codex_hook_count,
            "codexHooksTrusted": codex is not None,
            "claudeHookCount": claude_hook_count,
            "magSafePortPresent": mag_safe_port,
            "magSafeHelper": str(MAGSAFE_HELPER) if mag_safe_helper_hash else None,
            "magSafeHelperSHA256": mag_safe_helper_hash,
        },
    )

    print("9/9 Готово.")
    print(status.stdout.rstrip())
    print(f"Резервная копия конфигурации: {backup_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (InstallError, subprocess.CalledProcessError) as error:
        print(f"Ошибка установки: {error}", file=sys.stderr)
        raise SystemExit(1)
