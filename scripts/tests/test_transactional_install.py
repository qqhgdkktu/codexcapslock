from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


def load_script(module_name: str, filename: str):
    spec = importlib.util.spec_from_file_location(module_name, SCRIPTS_DIR / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


indicator_install = load_script("indicator_install_transaction", "install.py")
indicator_uninstall = load_script("indicator_uninstall_transaction", "uninstall.py")

from config_edit import (  # noqa: E402
    ConcurrentConfigEdit,
    ConfigEditError,
    update_json,
)
from transaction import (  # noqa: E402
    InstallationLock,
    InstallTransaction,
    TransactionError,
)


class TransactionalInstallTests(unittest.TestCase):
    def test_exact_hook_ownership_handles_spaces_and_preserves_marker_substrings(self) -> None:
        with tempfile.TemporaryDirectory(prefix="indicator path ") as directory:
            install_binary = Path(directory) / "bin with spaces" / "indicator"
            settings_file = Path(directory) / "settings.json"
            foreign = (
                "/usr/bin/printf 'codex-capslock-indicator hook stopped claude'"
            )
            settings_file.write_text(
                json.dumps(
                    {
                        "hooks": {
                            "Stop": [
                                {
                                    "hooks": [
                                        {"type": "command", "command": foreign},
                                    ]
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )

            with mock.patch.object(
                indicator_install,
                "INSTALL_BIN",
                install_binary,
            ):
                indicator_install.install_lifecycle_hooks(
                    settings_file,
                    (("Stop", "stopped", None),),
                    "claude",
                )
                document = json.loads(settings_file.read_text(encoding="utf-8"))
                commands = [
                    handler["command"]
                    for group in document["hooks"]["Stop"]
                    for handler in group.get("hooks", [])
                ]
                managed = [
                    command
                    for command in commands
                    if indicator_install.parse_indicator_hook(command) is not None
                ]

            self.assertIn(foreign, commands)
            self.assertEqual(len(managed), 1)
            self.assertIn(str(install_binary), managed[0])

    def test_uninstall_removes_only_exact_managed_hook(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            install_binary = Path(directory) / "indicator"
            settings_file = Path(directory) / "settings.json"
            managed = f"{install_binary} hook stopped codex"
            foreign = f"/usr/bin/echo {install_binary} hook stopped codex"
            settings_file.write_text(
                json.dumps(
                    {
                        "foreign": True,
                        "hooks": {
                            "Stop": [
                                {
                                    "hooks": [
                                        {"type": "command", "command": managed},
                                        {"type": "command", "command": foreign},
                                    ]
                                }
                            ]
                        },
                    }
                ),
                encoding="utf-8",
            )

            with mock.patch.object(
                indicator_uninstall,
                "INSTALL_BIN",
                install_binary,
            ):
                removed = indicator_uninstall.remove_hooks(settings_file)

            document = json.loads(settings_file.read_text(encoding="utf-8"))
            commands = [
                handler["command"]
                for group in document["hooks"]["Stop"]
                for handler in group["hooks"]
            ]
            self.assertEqual(removed, 1)
            self.assertEqual(commands, [foreign])
            self.assertTrue(document["foreign"])

    def test_installation_lock_rejects_concurrent_operation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_directory = Path(directory) / "state"
            with InstallationLock(state_directory):
                with self.assertRaises(TransactionError):
                    with InstallationLock(state_directory):
                        pass

    def test_installation_lock_rejects_symlinked_runtime_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real_state = root / "real-state"
            real_state.mkdir()
            linked_state = root / "linked-state"
            linked_state.symlink_to(real_state, target_is_directory=True)

            with self.assertRaises(TransactionError):
                with InstallationLock(linked_state):
                    pass

    def test_config_editor_rejects_symlink_and_empty_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.json"
            target.write_text("{}\n", encoding="utf-8")
            linked = root / "settings.json"
            linked.symlink_to(target)
            with self.assertRaises(ConfigEditError):
                update_json(linked, lambda document: document)

            empty = root / "empty.json"
            empty.touch()
            with self.assertRaises(ConfigEditError):
                update_json(empty, lambda document: document)

    def test_config_editor_detects_concurrent_noncooperating_write(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            path.write_text('{"value": 1}\n', encoding="utf-8")

            def transform(document):
                path.write_text('{"foreign": true}\n', encoding="utf-8")
                document["value"] = 2
                return document

            with self.assertRaises(ConcurrentConfigEdit):
                update_json(path, transform)
            self.assertEqual(
                json.loads(path.read_text(encoding="utf-8")),
                {"foreign": True},
            )

    def test_user_file_transaction_rolls_back_existing_and_new_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir()
            existing = root / "existing"
            created = root / "created"
            existing.write_text("before", encoding="utf-8")

            with self.assertRaises(RuntimeError):
                with InstallTransaction(state) as transaction:
                    transaction.capture(existing)
                    transaction.capture(created)
                    existing.write_text("after", encoding="utf-8")
                    created.write_text("new", encoding="utf-8")
                    raise RuntimeError("fault injection")

            self.assertEqual(existing.read_text(encoding="utf-8"), "before")
            self.assertFalse(created.exists())

    def test_secure_backup_modes_ignore_permissive_umask(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            codex_home = root / "codex"
            hooks_file = codex_home / "hooks.json"
            hooks_file.parent.mkdir(parents=True)
            hooks_file.write_text("{}\n", encoding="utf-8")
            old_umask = os.umask(0)
            try:
                with (
                    mock.patch.object(indicator_install, "CODEX_HOME", codex_home),
                    mock.patch.object(indicator_install, "HOOKS_FILE", hooks_file),
                    mock.patch.object(
                        indicator_install,
                        "CONFIG_FILE",
                        codex_home / "missing.toml",
                    ),
                    mock.patch.object(
                        indicator_install,
                        "LAUNCH_AGENT",
                        root / "missing-agent.plist",
                    ),
                    mock.patch.object(
                        indicator_install,
                        "MAGSAFE_LAUNCH_DAEMON",
                        root / "missing-daemon.plist",
                    ),
                    mock.patch.object(
                        indicator_install,
                        "CLAUDE_SETTINGS_FILE",
                        root / "missing-claude.json",
                    ),
                ):
                    backup = indicator_install.backup_user_files()
            finally:
                os.umask(old_umask)

            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
            self.assertEqual(
                stat.S_IMODE((backup / "hooks.json").stat().st_mode),
                0o600,
            )
            self.assertEqual(
                stat.S_IMODE((backup / "manifest.json").stat().st_mode),
                0o600,
            )

    def test_launch_agent_restarts_only_after_unsuccessful_exit(self) -> None:
        document = indicator_install.launch_agent_document("caps-lock")
        self.assertEqual(document["KeepAlive"], {"SuccessfulExit": False})
        self.assertFalse(document["RunAtLoad"])
        self.assertEqual(
            document["EnvironmentVariables"]["CODEX_CAPS_INDICATOR_OUTPUT"],
            "caps-lock",
        )

    def test_magsafe_state_capture_and_restore_are_transaction_scoped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "installed-helper"
            plist = root / "installed.plist"
            socket = root / "helper.sock"
            transaction_directory = root / "transaction"
            transaction_directory.mkdir()
            helper.write_bytes(b"old-helper")
            plist.write_bytes(b"old-plist")

            with (
                mock.patch.object(indicator_install, "MAGSAFE_HELPER", helper),
                mock.patch.object(
                    indicator_install,
                    "MAGSAFE_LAUNCH_DAEMON",
                    plist,
                ),
                mock.patch.object(indicator_install, "MAGSAFE_SOCKET", socket),
            ):
                captured = indicator_install.capture_magsafe_state(
                    transaction_directory
                )
                with mock.patch.object(
                    indicator_install,
                    "administrator_run",
                ) as administrator:
                    indicator_install.restore_magsafe_state(captured)

            self.assertEqual(captured["helper"].read_bytes(), b"old-helper")
            self.assertEqual(captured["plist"].read_bytes(), b"old-plist")
            command = administrator.call_args.args[0]
            self.assertIn(str(captured["helper"]), command)
            self.assertIn(str(captured["plist"]), command)


if __name__ == "__main__":
    unittest.main()
