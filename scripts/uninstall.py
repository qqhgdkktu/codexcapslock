#!/usr/bin/env python3
"""Remove the current user's Codex Caps Lock indicator installation."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


LABEL = "com.mikita.codex-capslock-indicator"
HOME = Path.home()
CODEX_HOME = Path(os.environ.get("CODEX_HOME", HOME / ".codex")).expanduser().resolve()
HOOKS_FILE = CODEX_HOME / "hooks.json"
INSTALL_BIN = HOME / ".local" / "bin" / "codex-capslock-indicator"
LAUNCH_AGENT = HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"
STATE_DIR = HOME / "Library" / "Application Support" / "CodexCapsLockIndicator"
HOOK_MARKER = "codex-capslock-indicator hook "


def atomic_json_write(path: Path, value: dict[str, Any]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def remove_hooks() -> int:
    if not HOOKS_FILE.exists():
        return 0
    document = json.loads(HOOKS_FILE.read_text(encoding="utf-8"))
    hooks = document.get("hooks")
    if not isinstance(hooks, dict):
        return 0

    removed = 0
    for event_name, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        cleaned_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                cleaned_groups.append(group)
                continue
            retained = []
            for handler in group["hooks"]:
                is_ours = (
                    isinstance(handler, dict)
                    and isinstance(handler.get("command"), str)
                    and HOOK_MARKER in handler["command"]
                )
                if is_ours:
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

    atomic_json_write(HOOKS_FILE, document)
    return removed


def stop_daemon() -> None:
    try:
        status = json.loads((STATE_DIR / "status.json").read_text(encoding="utf-8"))
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


def main() -> int:
    domain = f"gui/{os.getuid()}"
    subprocess.run(
        ["/bin/launchctl", "bootout", domain, str(LAUNCH_AGENT)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    stop_daemon()
    removed_hooks = remove_hooks()

    if INSTALL_BIN.exists():
        subprocess.run([str(INSTALL_BIN), "led", "restore"], check=False)
        INSTALL_BIN.unlink()
    LAUNCH_AGENT.unlink(missing_ok=True)

    print(f"Удалено hooks: {removed_hooks}")
    print("Индикатор удалён; диагностические данные и резервные копии сохранены.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
