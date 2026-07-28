"""Exact ownership checks for managed lifecycle hook commands."""

from __future__ import annotations

import shlex
from pathlib import Path


MANAGED_ACTIONS = {
    "prompt-submitted",
    "tool-started",
    "permission-requested",
    "input-requested",
    "tool-finished",
    "stopped",
    "stop-failed",
    "session-ended",
    # Upgrade cleanup for the v1 command surface.
    "working",
    "waiting",
    "done",
    "off",
}


def parse_indicator_hook(
    command: str,
    install_binary: Path,
) -> tuple[str, str] | None:
    try:
        arguments = shlex.split(command)
    except ValueError:
        return None
    if len(arguments) != 4:
        return None
    executable, operation, action, source = arguments
    if operation != "hook" or action not in MANAGED_ACTIONS:
        return None
    if source not in {"codex", "claude"}:
        return None
    if Path(executable).expanduser().resolve(
        strict=False
    ) != install_binary.resolve(strict=False):
        return None
    return action, source


def is_indicator_hook(handler: object, install_binary: Path) -> bool:
    return (
        isinstance(handler, dict)
        and isinstance(handler.get("command"), str)
        and parse_indicator_hook(handler["command"], install_binary) is not None
    )
