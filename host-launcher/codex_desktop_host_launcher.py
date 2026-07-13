#!/usr/bin/env python3
"use strict";

from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

APP_ID = "com.openai.CodexLinuxX64"
BAR_HEIGHT = 32
POLL_SECONDS = 0.25
WINDOW_WAIT_SECONDS = 60
MISSING_WINDOW_POLL_LIMIT = 120
HOST_WINDOW_CLASS = "CodexHost"
HOST_WINDOW_TITLE = "Codex"
MIN_HOST_WIDTH = 800
MIN_HOST_HEIGHT = 500
DEFAULT_HOST_WIDTH = 1280
DEFAULT_HOST_HEIGHT = 760
SCREEN_WIDTH_MARGIN = 80
SCREEN_HEIGHT_MARGIN = 120


@dataclass(frozen=True)
class WindowSnapshot:
    window_id: int
    x: int
    y: int
    width: int
    height: int
    title: str
    wm_class: tuple[str, ...]
    map_state: int
    override_redirect: bool


def is_codex_window(window: WindowSnapshot) -> bool:
    classes = {part.lower() for part in window.wm_class}
    title = window.title.strip().lower()
    return (
        window.map_state == 2
        and window.width >= 400
        and window.height >= 400
        and "codex" in classes
        and title in ("", "codex")
    )


def choose_codex_window(windows: Iterable[WindowSnapshot]) -> WindowSnapshot | None:
    candidates = [window for window in windows if is_codex_window(window)]
    if not candidates:
        return None
    return max(candidates, key=lambda window: (window.width * window.height, window.window_id))


def is_host_window(window: WindowSnapshot) -> bool:
    classes = {part.lower() for part in window.wm_class}
    return (
        window.map_state == 2
        and window.title.strip().lower() == HOST_WINDOW_TITLE.lower()
        and HOST_WINDOW_CLASS.lower() in classes
    )


def choose_host_window(windows: Iterable[WindowSnapshot]) -> WindowSnapshot | None:
    candidates = [window for window in windows if is_host_window(window)]
    if not candidates:
        return None
    return max(candidates, key=lambda window: window.window_id)


def titlebar_geometry(
    *, window_x: int, window_y: int, window_width: int, bar_height: int = BAR_HEIGHT
) -> tuple[int, int, int, int]:
    return (window_x, max(0, window_y - bar_height), window_width, bar_height)


def host_geometry(
    *,
    window_x: int,
    window_y: int,
    window_width: int,
    window_height: int,
    screen_width: int,
    screen_height: int,
) -> tuple[int, int, int, int]:
    max_width = max(MIN_HOST_WIDTH, int(screen_width) - SCREEN_WIDTH_MARGIN)
    max_height = max(MIN_HOST_HEIGHT, int(screen_height) - SCREEN_HEIGHT_MARGIN)
    requested_width = min(int(window_width), DEFAULT_HOST_WIDTH)
    requested_height = min(int(window_height), DEFAULT_HOST_HEIGHT)
    width = min(max(MIN_HOST_WIDTH, requested_width), max_width)
    height = min(max(MIN_HOST_HEIGHT, requested_height), max_height)
    x = max(0, min(int(window_x), int(screen_width) - width))
    y = max(0, min(int(window_y), int(screen_height) - height))
    return (x, y, width, height)


def build_flatpak_command(args: Sequence[str]) -> list[str]:
    return ["flatpak", "run", "--user", APP_ID, *args]


def cache_log_path() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    path = base / "codex-desktop-host-launcher"
    path.mkdir(parents=True, exist_ok=True)
    return path / "launcher.log"


class X11Controller:
    def __init__(self):
        from Xlib import X, display

        self.X = X
        self.display = display.Display()
        self.root = self.display.screen().root

    def close(self) -> None:
        self.display.close()

    def list_windows(self) -> list[WindowSnapshot]:
        snapshots: list[WindowSnapshot] = []

        def walk(window, parent_x: int = 0, parent_y: int = 0) -> None:
            try:
                children = window.query_tree().children
            except Exception:
                return

            for child in children:
                snapshot = self._snapshot(child, parent_x, parent_y)
                if snapshot is not None:
                    snapshots.append(snapshot)
                    walk(child, snapshot.x, snapshot.y)
                else:
                    walk(child, parent_x, parent_y)

        walk(self.root)
        return snapshots

    def find_codex_window(self) -> WindowSnapshot | None:
        return choose_codex_window(self.list_windows())

    def find_host_window(self) -> WindowSnapshot | None:
        return choose_host_window(self.list_windows())

    def wait_for_codex_window(self, timeout_seconds: float) -> WindowSnapshot | None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            snapshot = self.find_codex_window()
            if snapshot is not None:
                return snapshot
            time.sleep(POLL_SECONDS)
        return None

    def refresh_snapshot(self, window_id: int) -> WindowSnapshot | None:
        window = self.display.create_resource_object("window", window_id)
        return self._snapshot(window, 0, 0)

    def move_window(self, window_id: int, x: int, y: int) -> None:
        window = self.display.create_resource_object("window", window_id)
        window.configure(x=int(x), y=int(y))
        self.display.sync()

    def resize_window(self, window_id: int, width: int, height: int) -> None:
        window = self.display.create_resource_object("window", window_id)
        window.configure(x=0, y=0, width=max(1, int(width)), height=max(1, int(height)))
        self.display.sync()

    def reparent_window(self, window_id: int, parent_window_id: int, width: int, height: int) -> None:
        window = self.display.create_resource_object("window", window_id)
        parent = self.display.create_resource_object("window", parent_window_id)
        window.reparent(parent, 0, 0)
        window.configure(x=0, y=0, width=max(1, int(width)), height=max(1, int(height)))
        window.map()
        self.display.sync()

    def raise_window(self, window_id: int) -> None:
        self.focus_window(window_id)

    def focus_window(self, window_id: int) -> None:
        window = self.display.create_resource_object("window", window_id)
        self._request_window_activation(window)
        try:
            window.set_input_focus(self.X.RevertToParent, self.X.CurrentTime)
        except Exception:
            pass
        self.display.sync()

    def _request_window_activation(self, window) -> None:
        try:
            from Xlib.protocol import event

            active_atom = self.display.intern_atom("_NET_ACTIVE_WINDOW")
            message = event.ClientMessage(
                window=window,
                client_type=active_atom,
                data=(32, [1, self.X.CurrentTime, 0, 0, 0]),
            )
            self.root.send_event(
                message,
                event_mask=self.X.SubstructureRedirectMask | self.X.SubstructureNotifyMask,
            )
        except Exception:
            pass

    def _snapshot(self, window, parent_x: int, parent_y: int) -> WindowSnapshot | None:
        try:
            attrs = window.get_attributes()
            geom = window.get_geometry()
            wm_class = window.get_wm_class() or ()
            title = window.get_wm_name() or ""
        except Exception:
            return None

        return WindowSnapshot(
            window_id=window.id,
            x=int(parent_x + geom.x),
            y=int(parent_y + geom.y),
            width=int(geom.width),
            height=int(geom.height),
            title=str(title),
            wm_class=tuple(str(part) for part in wm_class),
            map_state=int(attrs.map_state),
            override_redirect=bool(attrs.override_redirect),
        )


class CodexTitlebar:
    def __init__(
        self, controller: X11Controller, initial_window: WindowSnapshot, process: subprocess.Popen
    ):
        import tkinter as tk

        self.tk = tk
        self.controller = controller
        self.window_id = initial_window.window_id
        self.process = process
        self.missing_window_polls = 0
        self.drag_origin: tuple[int, int, int, int] | None = None

        self.root = tk.Tk()
        self.root.title("Codex Drag Bar")
        self.root.overrideredirect(True)
        self.root.configure(background="#202124")

        self.frame = tk.Frame(self.root, background="#202124", height=BAR_HEIGHT)
        self.frame.pack(fill=tk.BOTH, expand=True)

        self.title = tk.Label(
            self.frame,
            text="Codex",
            anchor="w",
            padx=12,
            background="#202124",
            foreground="#f1f3f4",
            font=("Sans", 10, "bold"),
        )
        self.title.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self.close_button = tk.Button(
            self.frame,
            text="x",
            command=self.close_codex,
            background="#202124",
            foreground="#f1f3f4",
            activebackground="#5f1f1f",
            activeforeground="#ffffff",
            relief=tk.FLAT,
            bd=0,
            padx=12,
            pady=0,
        )
        self.close_button.pack(side=tk.RIGHT, fill=tk.Y)

        for widget in (self.frame, self.title):
            widget.bind("<ButtonPress-1>", self.start_drag)
            widget.bind("<B1-Motion>", self.drag)
            widget.bind("<ButtonRelease-1>", self.end_drag)
            widget.bind("<Button-1>", self.focus_codex, add="+")

        self.root.after(0, self.poll)

    def run(self) -> None:
        self.root.mainloop()

    def poll(self) -> None:
        snapshot = self.controller.refresh_snapshot(self.window_id)
        if snapshot is None or snapshot.map_state != 2:
            replacement = self.controller.find_codex_window()
            if replacement is None:
                if self.process.poll() is not None:
                    self.root.destroy()
                    return
                self.root.after(int(POLL_SECONDS * 1000), self.poll)
                return
            self.window_id = replacement.window_id
            snapshot = replacement

        self.place_bar(snapshot)
        self.root.after(int(POLL_SECONDS * 1000), self.poll)

    def place_bar(self, snapshot: WindowSnapshot) -> None:
        x, y, width, height = titlebar_geometry(
            window_x=snapshot.x, window_y=snapshot.y, window_width=snapshot.width
        )
        self.root.geometry(f"{width}x{height}+{x}+{y}")

    def focus_codex(self, _event=None) -> None:
        try:
            self.controller.raise_window(self.window_id)
        except Exception:
            pass

    def start_drag(self, event) -> None:
        snapshot = self.controller.refresh_snapshot(self.window_id)
        if snapshot is None:
            return
        self.drag_origin = (event.x_root, event.y_root, snapshot.x, snapshot.y)
        self.focus_codex()

    def drag(self, event) -> None:
        if self.drag_origin is None:
            return
        start_x_root, start_y_root, start_window_x, start_window_y = self.drag_origin
        next_x = start_window_x + event.x_root - start_x_root
        next_y = max(BAR_HEIGHT, start_window_y + event.y_root - start_y_root)
        try:
            self.controller.move_window(self.window_id, next_x, next_y)
        except Exception:
            return
        self.root.geometry(f"+{next_x}+{max(0, next_y - BAR_HEIGHT)}")

    def end_drag(self, _event=None) -> None:
        self.drag_origin = None

    def close_codex(self) -> None:
        subprocess.run(["flatpak", "kill", APP_ID], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.root.destroy()


class CodexHostWindow:
    def __init__(
        self, controller: X11Controller, initial_window: WindowSnapshot, process: subprocess.Popen | None
    ):
        import tkinter as tk

        self.controller = controller
        self.window_id = initial_window.window_id
        self.process = process

        self.root = tk.Tk(className=HOST_WINDOW_CLASS)
        self.root.title(HOST_WINDOW_TITLE)
        self.root.configure(background="#111111")
        self.root.minsize(MIN_HOST_WIDTH, MIN_HOST_HEIGHT)
        _x, _y, width, height = host_geometry(
            window_x=initial_window.x,
            window_y=initial_window.y,
            window_width=initial_window.width,
            window_height=initial_window.height,
            screen_width=self.root.winfo_screenwidth(),
            screen_height=self.root.winfo_screenheight(),
        )
        self.root.geometry(f"{width}x{height}")
        self.root.protocol("WM_DELETE_WINDOW", self.close_codex)
        self.root.update_idletasks()

        self.host_window_id = int(self.root.winfo_id())
        self.controller.reparent_window(
            self.window_id,
            self.host_window_id,
            max(MIN_HOST_WIDTH, self.root.winfo_width()),
            max(MIN_HOST_HEIGHT, self.root.winfo_height()),
        )

        self.root.bind("<Configure>", self.resize_codex)
        self.root.bind("<FocusIn>", self.focus_codex)
        self.root.after(100, self.focus_codex)
        self.root.after(int(POLL_SECONDS * 1000), self.poll)

    def run(self) -> None:
        self.root.mainloop()

    def resize_codex(self, event) -> None:
        if event.widget is not self.root:
            return
        try:
            self.controller.resize_window(self.window_id, event.width, event.height)
        except Exception:
            pass

    def focus_codex(self, _event=None) -> None:
        try:
            self.controller.focus_window(self.window_id)
        except Exception:
            pass

    def poll(self) -> None:
        snapshot = self.controller.refresh_snapshot(self.window_id)
        if snapshot is None:
            replacement = self.controller.find_codex_window()
            if replacement is None:
                self.missing_window_polls += 1
                if self.missing_window_polls >= MISSING_WINDOW_POLL_LIMIT:
                    self.root.destroy()
                    return
                self.root.after(int(POLL_SECONDS * 1000), self.poll)
                return
            self.missing_window_polls = 0
            self.window_id = replacement.window_id
            try:
                self.controller.reparent_window(
                    self.window_id,
                    self.host_window_id,
                    max(1, self.root.winfo_width()),
                    max(1, self.root.winfo_height()),
                )
            except Exception:
                self.root.destroy()
                return
        else:
            self.missing_window_polls = 0
        self.root.after(int(POLL_SECONDS * 1000), self.poll)

    def close_codex(self) -> None:
        subprocess.run(["flatpak", "kill", APP_ID], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.root.destroy()


def launch_codex(args: Sequence[str]) -> subprocess.Popen:
    log_file = cache_log_path().open("w", encoding="utf-8")
    print("starting flatpak", file=log_file, flush=True)
    return subprocess.Popen(
        build_flatpak_command(args),
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )


def main(argv: Sequence[str]) -> int:
    if os.environ.get("XDG_SESSION_TYPE") == "wayland" and not os.environ.get("DISPLAY"):
        return subprocess.call(build_flatpak_command(argv))

    controller = X11Controller()
    try:
        host_window = controller.find_host_window()
        if host_window is not None:
            controller.focus_window(host_window.window_id)
            return 0

        process = None
        snapshot = controller.find_codex_window()
        if snapshot is None:
            process = launch_codex(argv)
            snapshot = controller.wait_for_codex_window(WINDOW_WAIT_SECONDS)
        if snapshot is None:
            return process.wait() if process is not None else 1
        CodexHostWindow(controller, snapshot, process).run()
        return 0
    finally:
        controller.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
