import unittest
from pathlib import Path
import sys
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codex_desktop_host_launcher as launcher


class HostLauncherTests(unittest.TestCase):
    def test_choose_codex_window_prefers_largest_visible_codex_window(self):
        windows = [
            launcher.WindowSnapshot(1, 0, 0, 10, 10, "electron", ("electron", "Electron"), 2, False),
            launcher.WindowSnapshot(2, 10, 20, 900, 700, "", ("codex", "codex"), 2, True),
            launcher.WindowSnapshot(3, 10, 20, 1200, 900, "", ("codex", "codex"), 2, True),
            launcher.WindowSnapshot(4, 10, 20, 1400, 900, "Codex", ("codex", "codex"), 0, True),
        ]

        chosen = launcher.choose_codex_window(windows)

        self.assertEqual(chosen.window_id, 3)

    def test_titlebar_geometry_places_bar_above_window_when_possible(self):
        self.assertEqual(
            launcher.titlebar_geometry(window_x=338, window_y=656, window_width=1870, bar_height=32),
            (338, 624, 1870, 32),
        )

    def test_titlebar_geometry_clamps_to_top_of_screen(self):
        self.assertEqual(
            launcher.titlebar_geometry(window_x=10, window_y=8, window_width=800, bar_height=32),
            (10, 0, 800, 32),
        )

    def test_host_geometry_clamps_window_inside_screen(self):
        self.assertEqual(
            launcher.host_geometry(
                window_x=254,
                window_y=990,
                window_width=1870,
                window_height=1056,
                screen_width=2560,
                screen_height=1440,
            ),
            (254, 680, 1280, 760),
        )

    def test_host_geometry_limits_window_size_to_screen(self):
        self.assertEqual(
            launcher.host_geometry(
                window_x=0,
                window_y=0,
                window_width=5000,
                window_height=3000,
                screen_width=1920,
                screen_height=1080,
            ),
            (0, 0, 1280, 760),
        )

    def test_build_flatpak_command_preserves_forwarded_args(self):
        self.assertEqual(
            launcher.build_flatpak_command(["codex://example"]),
            ["flatpak", "run", "--user", "com.openai.CodexLinuxX64", "codex://example"],
        )

    def test_move_window_does_not_change_stacking_order(self):
        class FakeWindow:
            def __init__(self):
                self.configure_kwargs = None

            def configure(self, **kwargs):
                self.configure_kwargs = kwargs

        class FakeDisplay:
            def __init__(self, window):
                self.window = window
                self.synced = False

            def create_resource_object(self, _kind, _window_id):
                return self.window

            def sync(self):
                self.synced = True

        window = FakeWindow()
        controller = launcher.X11Controller.__new__(launcher.X11Controller)
        controller.display = FakeDisplay(window)

        controller.move_window(123, 40, 50)

        self.assertEqual(window.configure_kwargs, {"x": 40, "y": 50})
        self.assertTrue(controller.display.synced)

    def test_place_bar_does_not_periodically_lift_titlebar(self):
        class FakeRoot:
            def __init__(self):
                self.geometry_calls = []
                self.lift_calls = 0

            def geometry(self, value):
                self.geometry_calls.append(value)

            def lift(self):
                self.lift_calls += 1

        titlebar = launcher.CodexTitlebar.__new__(launcher.CodexTitlebar)
        titlebar.root = FakeRoot()
        snapshot = launcher.WindowSnapshot(1, 100, 200, 900, 700, "Codex", ("codex", "codex"), 2, True)

        titlebar.place_bar(snapshot)

        self.assertEqual(titlebar.root.geometry_calls, ["900x32+100+168"])
        self.assertEqual(titlebar.root.lift_calls, 0)

    def test_focus_codex_does_not_lift_titlebar(self):
        class FakeController:
            def __init__(self):
                self.raised = []

            def raise_window(self, window_id):
                self.raised.append(window_id)

        class FakeRoot:
            def __init__(self):
                self.lift_calls = 0

            def lift(self):
                self.lift_calls += 1

        titlebar = launcher.CodexTitlebar.__new__(launcher.CodexTitlebar)
        titlebar.controller = FakeController()
        titlebar.window_id = 123
        titlebar.root = FakeRoot()

        titlebar.focus_codex()

        self.assertEqual(titlebar.controller.raised, [123])
        self.assertEqual(titlebar.root.lift_calls, 0)

    def test_raise_window_sets_focus_without_changing_stacking_order(self):
        class FakeWindow:
            def __init__(self):
                self.configure_calls = 0
                self.focus_args = None

            def configure(self, **_kwargs):
                self.configure_calls += 1

            def set_input_focus(self, revert_to, time):
                self.focus_args = (revert_to, time)

        class FakeDisplay:
            def __init__(self, window):
                self.window = window
                self.synced = False

            def create_resource_object(self, _kind, _window_id):
                return self.window

            def sync(self):
                self.synced = True

        class FakeX:
            RevertToParent = "revert"
            CurrentTime = "time"

        window = FakeWindow()
        controller = launcher.X11Controller.__new__(launcher.X11Controller)
        controller.X = FakeX
        controller.display = FakeDisplay(window)

        controller.raise_window(123)

        self.assertEqual(window.configure_calls, 0)
        self.assertEqual(window.focus_args, ("revert", "time"))
        self.assertTrue(controller.display.synced)

    def test_reparent_window_embeds_codex_without_changing_stacking_order(self):
        class FakeWindow:
            def __init__(self):
                self.reparent_args = None
                self.configure_kwargs = None
                self.mapped = False

            def reparent(self, parent, x, y):
                self.reparent_args = (parent, x, y)

            def configure(self, **kwargs):
                self.configure_kwargs = kwargs

            def map(self):
                self.mapped = True

        class FakeDisplay:
            def __init__(self, child, parent):
                self.child = child
                self.parent = parent
                self.synced = 0

            def create_resource_object(self, _kind, _window_id):
                return self.child if _window_id == 123 else self.parent

            def sync(self):
                self.synced += 1

        child = FakeWindow()
        parent = object()
        controller = launcher.X11Controller.__new__(launcher.X11Controller)
        controller.display = FakeDisplay(child, parent)

        controller.reparent_window(123, 456, 900, 700)

        self.assertEqual(child.reparent_args, (parent, 0, 0))
        self.assertEqual(child.configure_kwargs, {"x": 0, "y": 0, "width": 900, "height": 700})
        self.assertTrue(child.mapped)
        self.assertGreaterEqual(controller.display.synced, 1)

    def test_resize_window_keeps_embedded_codex_filling_host(self):
        class FakeWindow:
            def __init__(self):
                self.configure_kwargs = None

            def configure(self, **kwargs):
                self.configure_kwargs = kwargs

        class FakeDisplay:
            def __init__(self, window):
                self.window = window
                self.synced = False

            def create_resource_object(self, _kind, _window_id):
                return self.window

            def sync(self):
                self.synced = True

        window = FakeWindow()
        controller = launcher.X11Controller.__new__(launcher.X11Controller)
        controller.display = FakeDisplay(window)

        controller.resize_window(123, 640, 480)

        self.assertEqual(window.configure_kwargs, {"x": 0, "y": 0, "width": 640, "height": 480})
        self.assertTrue(controller.display.synced)

    def test_main_reuses_existing_codex_window_without_launching_flatpak(self):
        snapshot = launcher.WindowSnapshot(123, 0, 0, 900, 700, "Codex", ("codex", "codex"), 2, True)

        class FakeController:
            def __init__(self):
                self.host_window = None
                self.closed = False

            def find_host_window(self):
                return snapshot

            def find_codex_window(self):
                raise AssertionError("should not inspect codex child when host window is present")

            def wait_for_codex_window(self, _timeout_seconds):
                raise AssertionError("should not wait when an existing window is present")

            def focus_window(self, window_id):
                self.focused = window_id

            def close(self):
                self.closed = True

        controller = FakeController()

        with mock.patch.object(launcher, "X11Controller", return_value=controller), mock.patch.object(
            launcher, "launch_codex"
        ) as launch_codex:
            result = launcher.main([])

        self.assertEqual(result, 0)
        launch_codex.assert_not_called()
        self.assertEqual(controller.focused, 123)
        self.assertTrue(controller.closed)

    def test_host_poll_keeps_window_when_flatpak_parent_exits_but_child_is_alive(self):
        snapshot = launcher.WindowSnapshot(123, 0, 0, 900, 700, "Codex", ("codex", "codex"), 2, True)

        class FakeController:
            def refresh_snapshot(self, window_id):
                self.refreshed = window_id
                return snapshot

        class FakeProcess:
            def poll(self):
                return 0

        class FakeRoot:
            def __init__(self):
                self.destroy_calls = 0
                self.after_calls = []

            def destroy(self):
                self.destroy_calls += 1

            def after(self, delay, callback):
                self.after_calls.append((delay, callback))

        host = launcher.CodexHostWindow.__new__(launcher.CodexHostWindow)
        host.controller = FakeController()
        host.window_id = 123
        host.process = FakeProcess()
        host.root = FakeRoot()

        host.poll()

        self.assertEqual(host.root.destroy_calls, 0)
        self.assertEqual(len(host.root.after_calls), 1)

    def test_host_poll_reparents_replacement_codex_window_when_child_is_recreated(self):
        replacement = launcher.WindowSnapshot(456, 0, 0, 900, 700, "Codex", ("codex", "codex"), 2, True)

        class FakeController:
            def __init__(self):
                self.reparented = []

            def refresh_snapshot(self, _window_id):
                return None

            def find_codex_window(self):
                return replacement

            def reparent_window(self, window_id, host_window_id, width, height):
                self.reparented.append((window_id, host_window_id, width, height))

        class FakeRoot:
            def __init__(self):
                self.destroy_calls = 0
                self.after_calls = []

            def destroy(self):
                self.destroy_calls += 1

            def after(self, delay, callback):
                self.after_calls.append((delay, callback))

            def winfo_width(self):
                return 640

            def winfo_height(self):
                return 480

        host = launcher.CodexHostWindow.__new__(launcher.CodexHostWindow)
        host.controller = FakeController()
        host.window_id = 123
        host.host_window_id = 999
        host.process = None
        host.root = FakeRoot()

        host.poll()

        self.assertEqual(host.window_id, 456)
        self.assertEqual(host.controller.reparented, [(456, 999, 640, 480)])
        self.assertEqual(host.root.destroy_calls, 0)
        self.assertEqual(len(host.root.after_calls), 1)

    def test_host_poll_waits_when_codex_window_is_temporarily_missing(self):
        class FakeController:
            def refresh_snapshot(self, _window_id):
                return None

            def find_codex_window(self):
                return None

        class FakeRoot:
            def __init__(self):
                self.destroy_calls = 0
                self.after_calls = []

            def destroy(self):
                self.destroy_calls += 1

            def after(self, delay, callback):
                self.after_calls.append((delay, callback))

        host = launcher.CodexHostWindow.__new__(launcher.CodexHostWindow)
        host.controller = FakeController()
        host.window_id = 123
        host.host_window_id = 999
        host.process = None
        host.root = FakeRoot()
        host.missing_window_polls = 0

        host.poll()

        self.assertEqual(host.missing_window_polls, 1)
        self.assertEqual(host.root.destroy_calls, 0)
        self.assertEqual(len(host.root.after_calls), 1)


if __name__ == "__main__":
    unittest.main()
