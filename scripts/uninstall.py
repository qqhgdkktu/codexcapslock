#!/usr/bin/env python3
"""Transactionally remove the current user's hardware indicator."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from config_edit import ConfigEditError, update_json
from hook_ownership import is_indicator_hook
from privileged_subprocess import administrator_run
from transaction import InstallTransaction, InstallationLock, TransactionError


LABEL = "com.mikita.codex-capslock-indicator"
MAGSAFE_LABEL = "com.mikita.codex-capslock-indicator.magsafe"
USER_HOME = Path.home()
CODEX_HOME = Path(
    os.environ.get("CODEX_HOME", USER_HOME / ".codex")
).expanduser().resolve()
HOOKS_FILE = CODEX_HOME / "hooks.json"
CLAUDE_HOME = Path(
    os.environ.get("CLAUDE_CONFIG_DIR", USER_HOME / ".claude")
).expanduser().resolve()
CLAUDE_SETTINGS_FILE = CLAUDE_HOME / "settings.json"
INSTALL_BIN = USER_HOME / ".local" / "bin" / "codex-capslock-indicator"
LAUNCH_AGENT = USER_HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"
MAGSAFE_HELPER = Path("/Library/PrivilegedHelperTools") / MAGSAFE_LABEL
MAGSAFE_LAUNCH_DAEMON = Path("/Library/LaunchDaemons") / f"{MAGSAFE_LABEL}.plist"
MAGSAFE_SOCKET = Path("/var/run") / f"{MAGSAFE_LABEL}.sock"
STATE_DIR = USER_HOME / "Library" / "Application Support" / "CodexCapsLockIndicator"
BACKUP_ROOT = CODEX_HOME / "backups" / "codex-capslock-indicator"


class UninstallError(RuntimeError):
    pass


def parse_arguments(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Remove Codex Caps Lock Indicator.")
    parser.add_argument(
        "--purge",
        action="store_true",
        help="also remove runtime state and retained configuration backups",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show exact targets without changing anything",
    )
    return parser.parse_args(arguments)


def remove_hooks(settings_file: Path) -> int:
    if not settings_file.exists():
        return 0
    removed = 0

    def transform(document: dict[str, Any]) -> dict[str, Any]:
        nonlocal removed
        hooks = document.get("hooks")
        if not isinstance(hooks, dict):
            return document

        for event_name, groups in list(hooks.items()):
            if not isinstance(groups, list):
                continue
            cleaned_groups: list[object] = []
            for group in groups:
                if not isinstance(group, dict):
                    cleaned_groups.append(group)
                    continue
                handlers = group.get("hooks")
                if not isinstance(handlers, list):
                    cleaned_groups.append(group)
                    continue
                retained = []
                for handler in handlers:
                    if is_indicator_hook(handler, INSTALL_BIN):
                        removed += 1
                    else:
                        retained.append(handler)
                if retained:
                    updated = dict(group)
                    updated["hooks"] = retained
                    cleaned_groups.append(updated)
            if cleaned_groups:
                hooks[event_name] = cleaned_groups
            else:
                hooks.pop(event_name, None)
        return document

    try:
        update_json(settings_file, transform)
    except ConfigEditError as error:
        raise UninstallError(str(error)) from error
    return removed


def stop_launch_agent() -> None:
    subprocess.run(
        [
            "/bin/launchctl",
            "bootout",
            f"gui/{os.getuid()}",
            str(LAUNCH_AGENT),
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def restore_previous_launch_agent() -> None:
    if not LAUNCH_AGENT.exists():
        return
    domain = f"gui/{os.getuid()}"
    subprocess.run(
        ["/bin/launchctl", "bootstrap", domain, str(LAUNCH_AGENT)],
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


def _installed_daemon_pid() -> int | None:
    try:
        status = json.loads((STATE_DIR / "status.json").read_text(encoding="utf-8"))
        pid = int(status["pid"])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return None
    probe = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "command="],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if str(INSTALL_BIN) not in probe.stdout or " daemon" not in probe.stdout:
        return None
    return pid


def stop_daemon() -> None:
    pid = _installed_daemon_pid()
    if pid is None:
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
    os.kill(pid, signal.SIGKILL)
    for _ in range(20):
        time.sleep(0.1)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
    raise UninstallError(f"Daemon PID {pid} не завершился даже после SIGKILL")


def restore_outputs() -> None:
    if not INSTALL_BIN.exists():
        return
    mag_safe = subprocess.run(
        [str(INSTALL_BIN), "magsafe", "system"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    caps_lock = subprocess.run(
        [str(INSTALL_BIN), "led", "restore"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if caps_lock.returncode != 0:
        raise UninstallError(
            f"Не удалось восстановить Caps Lock LED: {caps_lock.stdout.strip()}"
        )
    if (MAGSAFE_HELPER.exists() or MAGSAFE_LAUNCH_DAEMON.exists()) and mag_safe.returncode != 0:
        raise UninstallError(
            f"Не удалось восстановить MagSafe: {mag_safe.stdout.strip()}"
        )


def remove_magsafe_helper() -> bool:
    if not MAGSAFE_HELPER.exists() and not MAGSAFE_LAUNCH_DAEMON.exists():
        return False

    print("Для удаления системного помощника macOS покажет окно администратора.")
    helper_backup = MAGSAFE_HELPER.with_name(
        f".{MAGSAFE_HELPER.name}.uninstall-backup"
    )
    plist_backup = MAGSAFE_LAUNCH_DAEMON.with_name(
        f".{MAGSAFE_LAUNCH_DAEMON.name}.uninstall-backup"
    )
    bootout = shlex.join(
        [
            "/bin/launchctl",
            "bootout",
            "system",
            str(MAGSAFE_LAUNCH_DAEMON),
        ]
    )
    bootstrap = shlex.join(
        [
            "/bin/launchctl",
            "bootstrap",
            "system",
            str(MAGSAFE_LAUNCH_DAEMON),
        ]
    )
    cleanup_backups = shlex.join(
        [
            "/bin/rm",
            "-f",
            str(helper_backup),
            str(plist_backup),
        ]
    )
    rollback = "; ".join(
        [
            "status=$?",
            (
                'if /bin/test "$status" -ne 0; then '
                f"if /bin/test -f {shlex.quote(str(helper_backup))}; "
                f"then /bin/mv -f {shlex.quote(str(helper_backup))} "
                f"{shlex.quote(str(MAGSAFE_HELPER))}; fi; "
                f"if /bin/test -f {shlex.quote(str(plist_backup))}; "
                f"then /bin/mv -f {shlex.quote(str(plist_backup))} "
                f"{shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))}; "
                f"({bootstrap} >/dev/null 2>&1 || true); fi; "
                "fi"
            ),
            cleanup_backups,
            'exit "$status"',
        ]
    )
    commands = [
        f"trap {shlex.quote(rollback)} EXIT",
        cleanup_backups,
        (
            f"if /bin/test -f {shlex.quote(str(MAGSAFE_HELPER))}; "
            f"then /bin/cp -p {shlex.quote(str(MAGSAFE_HELPER))} "
            f"{shlex.quote(str(helper_backup))}; fi"
        ),
        (
            f"if /bin/test -f {shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))}; "
            f"then /bin/cp -p {shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))} "
            f"{shlex.quote(str(plist_backup))}; fi"
        ),
        f"({bootout} >/dev/null 2>&1 || true)",
        shlex.join([
            "/bin/rm",
            "-f",
            str(MAGSAFE_HELPER),
            str(MAGSAFE_LAUNCH_DAEMON),
            str(MAGSAFE_SOCKET),
        ]),
        f"/bin/test ! -e {shlex.quote(str(MAGSAFE_HELPER))}",
        f"/bin/test ! -e {shlex.quote(str(MAGSAFE_LAUNCH_DAEMON))}",
        f"/bin/test ! -e {shlex.quote(str(MAGSAFE_SOCKET))}",
        cleanup_backups,
        "trap - EXIT",
    ]
    administrator_run(" && ".join(commands))
    if MAGSAFE_HELPER.exists() or MAGSAFE_LAUNCH_DAEMON.exists() or MAGSAFE_SOCKET.exists():
        raise UninstallError("Системный MagSafe helper удалён не полностью")
    return True


def managed_hook_count(settings_file: Path) -> int:
    if not settings_file.exists():
        return 0
    document = json.loads(settings_file.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or not isinstance(document.get("hooks"), dict):
        return 0
    return sum(
        1
        for groups in document["hooks"].values()
        if isinstance(groups, list)
        for group in groups
        if isinstance(group, dict) and isinstance(group.get("hooks"), list)
        for handler in group["hooks"]
        if is_indicator_hook(handler, INSTALL_BIN)
    )


def verify_postconditions(*, include_root: bool = True) -> None:
    failures: list[str] = []
    if _installed_daemon_pid() is not None:
        failures.append("daemon всё ещё работает")
    if LAUNCH_AGENT.exists():
        failures.append("LaunchAgent plist остался")
    if INSTALL_BIN.exists():
        failures.append("основной binary остался")
    if include_root:
        if MAGSAFE_HELPER.exists() or MAGSAFE_LAUNCH_DAEMON.exists():
            failures.append("root helper остался")
        if MAGSAFE_SOCKET.exists():
            failures.append("MagSafe socket остался")
    if managed_hook_count(HOOKS_FILE) or managed_hook_count(CLAUDE_SETTINGS_FILE):
        failures.append("managed hooks остались")
    if failures:
        raise UninstallError("; ".join(failures))


def purge_retained_data() -> None:
    if STATE_DIR.exists():
        shutil.rmtree(STATE_DIR)
    if BACKUP_ROOT.exists():
        shutil.rmtree(BACKUP_ROOT)


def main(arguments: list[str] | None = None) -> int:
    options = parse_arguments(arguments)
    targets = [
        INSTALL_BIN,
        LAUNCH_AGENT,
        HOOKS_FILE,
        CLAUDE_SETTINGS_FILE,
        MAGSAFE_HELPER,
        MAGSAFE_LAUNCH_DAEMON,
        MAGSAFE_SOCKET,
    ]
    if options.purge:
        targets.extend([STATE_DIR, BACKUP_ROOT])
    if options.dry_run:
        print("Uninstall preview; изменений не выполнено:")
        for target in targets:
            print(f"- {target}")
        return 0

    with InstallationLock(STATE_DIR):
        with InstallTransaction(STATE_DIR) as transaction:
            transaction.add_rollback(restore_previous_launch_agent)
            for path in (
                INSTALL_BIN,
                LAUNCH_AGENT,
                HOOKS_FILE,
                CLAUDE_SETTINGS_FILE,
            ):
                transaction.capture(path)

            removed_codex_hooks = remove_hooks(HOOKS_FILE)
            removed_claude_hooks = remove_hooks(CLAUDE_SETTINGS_FILE)
            stop_launch_agent()
            stop_daemon()
            restore_outputs()
            INSTALL_BIN.unlink(missing_ok=True)
            LAUNCH_AGENT.unlink(missing_ok=True)
            verify_postconditions(include_root=False)
            removed_magsafe = remove_magsafe_helper()
            verify_postconditions()
            transaction.finish()

    if options.purge:
        purge_retained_data()

    print(f"Удалено hooks Codex: {removed_codex_hooks}")
    print(f"Удалено hooks Claude Code: {removed_claude_hooks}")
    print(f"Помощник MagSafe: {'удалён' if removed_magsafe else 'не был установлен'}")
    print(
        "Runtime и backups удалены."
        if options.purge
        else "Runtime и резервные копии сохранены; для полного удаления используйте --purge."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        ConfigEditError,
        TransactionError,
        UninstallError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Ошибка удаления: {error}", file=sys.stderr)
        raise SystemExit(1)
