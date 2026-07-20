from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

INSTALL_SCRIPT = SCRIPTS_DIR / "install.py"
SPEC = importlib.util.spec_from_file_location("indicator_install", INSTALL_SCRIPT)
assert SPEC is not None and SPEC.loader is not None
indicator_install = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(indicator_install)


class HookConfigurationTests(unittest.TestCase):
    def test_privileged_magsafe_install_verifies_root_owned_staging_before_launch(self) -> None:
        command = indicator_install.build_privileged_magsafe_install_command(
            Path("/private/tmp/staged-helper"),
            Path("/private/tmp/staged-daemon.plist"),
            "a" * 64,
            "b" * 64,
        )

        helper_staging = str(
            indicator_install.MAGSAFE_HELPER.with_name(
                f".{indicator_install.MAGSAFE_HELPER.name}.new"
            )
        )
        plist_staging = str(
            indicator_install.MAGSAFE_LAUNCH_DAEMON.with_name(
                f".{indicator_install.MAGSAFE_LAUNCH_DAEMON.name}.new"
            )
        )
        first_hash_check = command.index("/usr/bin/shasum -a 256")
        bootout = command.index("/bin/launchctl bootout")
        bootstrap = command.index("/bin/launchctl bootstrap")

        self.assertIn(helper_staging, command)
        self.assertIn(plist_staging, command)
        self.assertIn("a" * 64, command)
        self.assertIn("b" * 64, command)
        self.assertIn("/bin/test", command)
        self.assertNotIn("/usr/bin/test", command)
        self.assertLess(first_hash_check, bootout)
        self.assertLess(bootout, bootstrap)
        self.assertIn("trap ", command)

    def test_claude_hooks_preserve_foreign_settings_and_are_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings_file = Path(directory) / "settings.json"
            settings_file.write_text(
                json.dumps(
                    {
                        "permissions": {"allow": ["Read"]},
                        "hooks": {
                            "PreToolUse": [{"matcher": "Bash", "foreign": True}],
                            "Stop": [
                                {
                                    "hooks": [
                                        {
                                            "type": "command",
                                            "command": "/usr/local/bin/foreign-hook",
                                            "timeout": 10,
                                        }
                                    ]
                                }
                            ]
                        },
                    }
                ),
                encoding="utf-8",
            )

            first_count = indicator_install.install_lifecycle_hooks(
                settings_file,
                indicator_install.CLAUDE_HOOKS,
                "claude",
            )
            second_count = indicator_install.install_lifecycle_hooks(
                settings_file,
                indicator_install.CLAUDE_HOOKS,
                "claude",
            )

            document = json.loads(settings_file.read_text(encoding="utf-8"))
            self.assertEqual(first_count, len(indicator_install.CLAUDE_HOOKS))
            self.assertEqual(second_count, len(indicator_install.CLAUDE_HOOKS))
            self.assertEqual(document["permissions"], {"allow": ["Read"]})
            self.assertIn(
                {"matcher": "Bash", "foreign": True},
                document["hooks"]["PreToolUse"],
            )

            commands = [
                handler["command"]
                for groups in document["hooks"].values()
                for group in groups
                for handler in group.get("hooks", [])
                if isinstance(handler, dict) and "command" in handler
            ]
            indicator_commands = [
                command
                for command in commands
                if indicator_install.HOOK_MARKER in command
            ]
            self.assertIn("/usr/local/bin/foreign-hook", commands)
            self.assertEqual(len(indicator_commands), len(indicator_install.CLAUDE_HOOKS))
            self.assertTrue(all(command.endswith(" claude") for command in indicator_commands))

            notification_groups = document["hooks"]["Notification"]
            self.assertEqual(notification_groups[-1]["matcher"], "permission_prompt")

    def test_invalid_settings_are_rejected_without_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings_file = Path(directory) / "settings.json"
            settings_file.write_text("[]\n", encoding="utf-8")

            with self.assertRaises(indicator_install.InstallError):
                indicator_install.install_lifecycle_hooks(
                    settings_file,
                    indicator_install.CLAUDE_HOOKS,
                    "claude",
                )

            self.assertEqual(settings_file.read_text(encoding="utf-8"), "[]\n")


if __name__ == "__main__":
    unittest.main()
