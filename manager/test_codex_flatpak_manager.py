#!/usr/bin/env python3
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codex_flatpak_manager as manager


class ManagerTests(unittest.TestCase):
    def test_filesystem_value_supports_read_only_mode(self):
        self.assertEqual(manager.CodexFlatpakManager._filesystem_value("~/Projects:ro")[1], "ro")

    def test_filesystem_value_rejects_relative_paths(self):
        with self.assertRaises(manager.ManagerError):
            manager.CodexFlatpakManager._filesystem_value("relative/path")

    def test_profile_names_are_restricted(self):
        self.assertTrue(manager.PROFILE_NAME_RE.fullmatch("work-1"))
        self.assertFalse(manager.PROFILE_NAME_RE.fullmatch("../outside"))
        self.assertFalse(manager.PROFILE_NAME_RE.fullmatch("中文"))

    def test_tui_menu_contains_second_level_actions(self):
        nodes = manager._tui_menu(("permissions",))
        keys = [node["key"] for node in nodes]
        self.assertIn("permissions-grant", keys)
        self.assertEqual(next(node for node in nodes if node["key"] == "permissions-grant")["depth"], 0)
        self.assertIn("profiles-launch", [node["key"] for node in manager._tui_menu(("profiles",))])

    def test_tui_menu_is_collapsed_by_default(self):
        nodes = manager._tui_menu()
        self.assertEqual([node["key"] for node in nodes], ["status", "upgrade", "permissions", "profiles", "logs"])

    def test_profile_creation_is_isolated_and_listable(self):
        with tempfile.TemporaryDirectory() as temp:
            old_root = os.environ.get("CODEX_MANAGER_PROFILE_ROOT")
            os.environ["CODEX_MANAGER_PROFILE_ROOT"] = str(Path(temp) / "profiles")
            try:
                repo = Path(temp) / "repo"
                repo.mkdir()
                (repo / "upgrade-codex-desktop-flatpak.sh").write_text("#!/bin/sh\n", encoding="utf-8")
                instance = manager.CodexFlatpakManager(str(repo))
                created = instance.create_profile("work")
                self.assertTrue(Path(created["path"], "config").is_dir())
                self.assertEqual(instance.list_profiles()[0]["name"], "work")
            finally:
                if old_root is None:
                    os.environ.pop("CODEX_MANAGER_PROFILE_ROOT", None)
                else:
                    os.environ["CODEX_MANAGER_PROFILE_ROOT"] = old_root


if __name__ == "__main__":
    unittest.main()
