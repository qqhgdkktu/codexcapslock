from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import privileged_subprocess  # noqa: E402


def load_script(module_name: str, filename: str):
    spec = importlib.util.spec_from_file_location(module_name, SCRIPTS_DIR / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


indicator_install = load_script("indicator_install_privileged", "install.py")
indicator_uninstall = load_script("indicator_uninstall_privileged", "uninstall.py")


class PrivilegedSubprocessTests(unittest.TestCase):
    def test_administrator_run_uses_complete_minimal_environment(self) -> None:
        hostile_environment = {
            "PERL5LIB": "/tmp/hostile-perl",
            "PERL5OPT": "-MHostile",
            "PERLLIB": "/tmp/legacy-perl",
            "BASH_ENV": "/tmp/bash-env",
            "ENV": "/tmp/shell-env",
            "PYTHONPATH": "/tmp/python",
            "PYTHONINSPECT": "1",
            "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
        }

        completed = subprocess.CompletedProcess(
            args=["/usr/bin/osascript"],
            returncode=0,
        )
        with (
            mock.patch.dict(os.environ, hostile_environment, clear=False),
            mock.patch.object(
                privileged_subprocess.subprocess,
                "run",
                return_value=completed,
            ) as run_mock,
        ):
            result = privileged_subprocess.administrator_run(
                "/usr/bin/true",
                cwd=Path("/tmp"),
            )

        self.assertIs(result, completed)
        environment = run_mock.call_args.kwargs["env"]
        self.assertEqual(
            environment,
            {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "LC_ALL": "C",
            },
        )
        self.assertTrue(hostile_environment.keys().isdisjoint(environment))

    def test_install_and_uninstall_share_the_privilege_launcher(self) -> None:
        self.assertIs(
            indicator_install.administrator_run,
            privileged_subprocess.administrator_run,
        )
        self.assertIs(
            indicator_uninstall.administrator_run,
            privileged_subprocess.administrator_run,
        )


if __name__ == "__main__":
    unittest.main()
