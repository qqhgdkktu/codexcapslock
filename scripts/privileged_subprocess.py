"""Shared policy for administrator-authorized subprocesses on macOS."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


_PRIVILEGED_ENVIRONMENT = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "C",
    "LC_ALL": "C",
}


def privileged_environment() -> dict[str, str]:
    """Return the complete environment allowed to cross the root boundary."""
    return _PRIVILEGED_ENVIRONMENT.copy()


def administrator_run(
    shell_command: str,
    *,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one fixed, caller-constructed command after macOS authentication."""
    apple_script = (
        f"do shell script {json.dumps(shell_command, ensure_ascii=False)} "
        "with administrator privileges"
    )
    return subprocess.run(
        ["/usr/bin/osascript", "-e", apple_script],
        cwd=cwd,
        check=True,
        text=True,
        env=privileged_environment(),
    )
