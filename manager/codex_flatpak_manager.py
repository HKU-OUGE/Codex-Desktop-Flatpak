#!/usr/bin/env python3
"""Small host-side manager for the Codex Desktop Flatpak repository.

The manager deliberately delegates building and upgrading to the repository's
existing shell scripts. It is an optional control plane, not a replacement for
the manual workflow.
"""

from __future__ import annotations

import argparse
import contextlib
import curses
import fcntl
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import textwrap
import urllib.parse
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Iterator


APP_ID = "com.openai.CodexLinuxX64"
MANAGER_VERSION = "0.1.0"
PROFILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
COMMIT_RE = re.compile(r"^[0-9a-fA-F]{8,64}$")


class ManagerError(RuntimeError):
    pass


def json_text(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


class CodexFlatpakManager:
    def __init__(self, repo: str | None = None):
        config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
        self.config_dir = config_home / "codex-flatpak-manager"
        self.state_dir = state_home / "codex-flatpak-manager"
        self.log_dir = self.state_dir / "logs"
        self.lock_path = self.state_dir / "manager.lock"
        self.token_path = self.config_dir / "token"
        self.repo = self._resolve_repo(repo)

        profile_root = os.environ.get(
            "CODEX_MANAGER_PROFILE_ROOT",
            str(Path.home() / ".var" / "app" / APP_ID / "profiles"),
        )
        self.profile_root = Path(profile_root).expanduser()

    def _resolve_repo(self, explicit: str | None) -> Path:
        candidates: list[str] = []
        if explicit:
            candidates.append(explicit)
        if os.environ.get("CODEX_MANAGER_REPO"):
            candidates.append(os.environ["CODEX_MANAGER_REPO"])
        repo_file = self.config_dir / "repo"
        try:
            configured = repo_file.read_text(encoding="utf-8").strip()
        except OSError:
            configured = ""
        if configured:
            candidates.append(configured)
        candidates.append(os.getcwd())

        for candidate in candidates:
            path = Path(candidate).expanduser().resolve()
            if (path / "upgrade-codex-desktop-flatpak.sh").is_file():
                return path
        raise ManagerError(
            "Could not find the Codex Flatpak repository. Use --repo PATH or run install.sh first."
        )

    def _require_command(self, name: str) -> None:
        if not any((Path(directory) / name).exists() for directory in os.environ.get("PATH", "").split(os.pathsep)):
            raise ManagerError(f"Required command is missing: {name}")

    def _capture(self, command: list[str]) -> tuple[int, str]:
        try:
            completed = subprocess.run(
                command,
                cwd=str(self.repo),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
        except OSError as exc:
            return 127, str(exc)
        return completed.returncode, completed.stdout.strip()

    def _log_path(self, label: str) -> Path:
        self.log_dir.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        return self.log_dir / f"{timestamp}-{label}.log"

    def _stream_command(
        self,
        command: list[str],
        *,
        env: dict[str, str] | None = None,
        label: str,
        on_line: Callable[[str], None] | None = None,
    ) -> tuple[int, Path]:
        log_path = self._log_path(label)
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"command={' '.join(command)}\n")
            log.flush()
            try:
                process = subprocess.Popen(
                    command,
                    cwd=str(self.repo),
                    env=merged_env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
            except OSError as exc:
                log.write(f"error={exc}\n")
                return 127, log_path
            assert process.stdout is not None
            for line in process.stdout:
                log.write(line)
                log.flush()
                if on_line:
                    on_line(line)
                else:
                    sys.stdout.write(line)
                    sys.stdout.flush()
            return process.wait(), log_path

    @contextlib.contextmanager
    def mutation_lock(self) -> Iterator[None]:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a+", encoding="utf-8") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ManagerError("Another manager operation is already running.") from exc
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def _flatpak(self) -> None:
        self._require_command("flatpak")

    def status(self) -> dict[str, Any]:
        commit_code, commit = self._capture(["flatpak", "info", "--user", "--show-commit", APP_ID])
        running_code, running = self._capture(
            ["flatpak", "ps", "--columns=instance,pid,application,commit"]
        )
        build_info = read_json(self.repo / "flatpak-sources" / "build-info.json", {})
        return {
            "manager_version": MANAGER_VERSION,
            "app_id": APP_ID,
            "repository": str(self.repo),
            "installed_commit": commit if commit_code == 0 else None,
            "running_instances": running if running_code == 0 else "",
            "build_info": {
                key: build_info.get(key)
                for key in ("codexAppVersion", "codexCliReleaseTag", "electronVersion", "appAsarSha256")
                if key in build_info
            },
        }

    def upgrade(
        self,
        *,
        no_restart: bool = False,
        no_build: bool = False,
        release_tag: str | None = None,
        force_download: bool = False,
        on_line: Callable[[str], None] | None = None,
    ) -> dict[str, Any]:
        self._flatpak()
        command = [str(self.repo / "upgrade-codex-desktop-flatpak.sh")]
        if no_restart:
            command.append("--no-restart")
        if no_build:
            command.append("--no-build")
        env: dict[str, str] = {}
        if release_tag:
            env["CODEX_RELEASE_TAG"] = release_tag
        if force_download:
            env["CODEX_FORCE_DOWNLOAD"] = "1"
        with self.mutation_lock():
            return_code, log_path = self._stream_command(
                command, env=env, label="upgrade", on_line=on_line
            )
        return {"ok": return_code == 0, "return_code": return_code, "log": str(log_path)}

    def rollback(self, commit: str, restart: bool = False) -> dict[str, Any]:
        if not COMMIT_RE.fullmatch(commit):
            raise ManagerError("Invalid Flatpak commit ID.")
        self._flatpak()
        with self.mutation_lock():
            code, output = self._capture(
                ["flatpak", "update", "--user", "-y", f"--commit={commit}", APP_ID]
            )
            if code != 0:
                raise ManagerError(output or "Flatpak rollback failed.")
            if restart:
                self._capture(["flatpak", "kill", APP_ID])
                subprocess.Popen(
                    ["flatpak", "run", "--user", "--env=CODEX_FLATPAK_RENDERER=gpu", APP_ID],
                    cwd=str(self.repo),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
        return {"ok": True, "commit": commit, "restarted": restart, "output": output}

    def permissions(self) -> str:
        self._flatpak()
        code, output = self._capture(["flatpak", "info", "--user", "--show-permissions", APP_ID])
        if code != 0:
            raise ManagerError(output or "Could not read Flatpak permissions.")
        return output

    @staticmethod
    def _filesystem_value(value: str) -> tuple[str, str]:
        mode = "rw"
        path_value = value
        if ":" in value:
            possible_path, possible_mode = value.rsplit(":", 1)
            if possible_mode in {"ro", "rw", "create"}:
                path_value, mode = possible_path, possible_mode
        path = Path(path_value).expanduser()
        if not path.is_absolute():
            raise ManagerError("Filesystem paths must be absolute or start with ~.")
        return str(path), mode

    def grant_filesystem(self, value: str) -> dict[str, Any]:
        path, mode = self._filesystem_value(value)
        with self.mutation_lock():
            code, output = self._capture(
                ["flatpak", "override", "--user", f"--filesystem={path}:{mode}", APP_ID]
            )
        if code != 0:
            raise ManagerError(output or "Could not grant filesystem permission.")
        return {"ok": True, "filesystem": path, "mode": mode, "output": output}

    def revoke_filesystem(self, value: str) -> dict[str, Any]:
        path, _mode = self._filesystem_value(value)
        with self.mutation_lock():
            code, output = self._capture(["flatpak", "override", "--user", f"--nofilesystem={path}", APP_ID])
        if code != 0:
            raise ManagerError(output or "Could not revoke filesystem permission.")
        return {"ok": True, "filesystem": path, "output": output}

    def _profile_path(self, name: str) -> Path:
        if not PROFILE_NAME_RE.fullmatch(name):
            raise ManagerError("Profile names must use letters, numbers, dot, underscore, or hyphen.")
        return self.profile_root / name

    def create_profile(self, name: str) -> dict[str, Any]:
        path = self._profile_path(name)
        for child in ("config", "data", "cache"):
            (path / child).mkdir(parents=True, exist_ok=True)
        return {"name": name, "path": str(path), "experimental": True}

    def list_profiles(self) -> list[dict[str, Any]]:
        if not self.profile_root.exists():
            return []
        return [
            {"name": child.name, "path": str(child), "experimental": True}
            for child in sorted(self.profile_root.iterdir())
            if child.is_dir() and PROFILE_NAME_RE.fullmatch(child.name)
        ]

    def launch_profile(self, name: str, foreground: bool = False) -> dict[str, Any]:
        profile = self.create_profile(name)
        path = Path(profile["path"])
        command = [
            "flatpak",
            "run",
            "--user",
            "--env=CODEX_FLATPAK_RENDERER=gpu",
            f"--env=XDG_CONFIG_HOME={path / 'config'}",
            f"--env=XDG_DATA_HOME={path / 'data'}",
            f"--env=XDG_CACHE_HOME={path / 'cache'}",
            f"--env=CODEX_MANAGER_PROFILE={name}",
            APP_ID,
        ]
        if foreground:
            return_code = subprocess.call(command, cwd=str(self.repo))
            return {"ok": return_code == 0, "return_code": return_code, "profile": name}
        process = subprocess.Popen(command, cwd=str(self.repo))
        return {"ok": True, "profile": name, "pid": process.pid, "experimental": True}

    def token(self) -> str:
        self.config_dir.mkdir(parents=True, exist_ok=True)
        try:
            token = self.token_path.read_text(encoding="utf-8").strip()
        except OSError:
            token = ""
        if not token:
            token = secrets.token_urlsafe(32)
            self.token_path.write_text(token + "\n", encoding="utf-8")
            self.token_path.chmod(0o600)
        return token

    def recent_logs(self, limit: int = 120) -> str:
        if not self.log_dir.exists():
            return ""
        paths = sorted(self.log_dir.glob("*.log"))
        if not paths:
            return ""
        try:
            lines = paths[-1].read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return ""
        return "\n".join(lines[-limit:])


def _short_commit(commit: str | None) -> str:
    return commit[:12] if commit else "未安装"


def plain_panel(manager: CodexFlatpakManager) -> int:
    """Print a terminal-friendly tree without requiring an interactive TTY."""
    status = manager.status()
    running = [line for line in status.get("running_instances", "").splitlines() if line.strip()]
    build_info = status.get("build_info", {})
    print("Codex Flatpak Manager")
    print("├─ 状态")
    print(f"│  ├─ 安装 commit: {_short_commit(status.get('installed_commit'))}")
    print(f"│  ├─ Desktop 版本: {build_info.get('codexAppVersion', '未知')}")
    print(f"│  ├─ CLI release: {build_info.get('codexCliReleaseTag', '未知')}")
    print(f"│  └─ 运行实例: {len(running)}")
    print("├─ 升级")
    print("│  ├─ 手动: codex-flatpak-manager upgrade --no-restart")
    print("│  └─ 自动: 已禁用（按版本手动执行升级流程）")
    print("├─ 权限")
    print("│  └─ codex-flatpak-manager permissions list")
    print("├─ Profile 多开（实验性）")
    print("│  ├─ 创建: codex-flatpak-manager profile create work")
    print("│  └─ 启动: codex-flatpak-manager profile launch work")
    print("└─ 网页面板")
    print("   └─ codex-flatpak-manager serve --open")
    return 0


def _tui_add(stdscr: Any, y: int, x: int, text: str, width: int, attr: int = 0) -> int:
    height, _screen_width = stdscr.getmaxyx()
    if y >= height or width <= 0:
        return y
    for line in textwrap.wrap(str(text), max(1, width - 1)) or [""]:
        if y >= height:
            break
        try:
            stdscr.addnstr(y, x, line, max(1, width - 1), attr)
        except curses.error:
            pass
        y += 1
    return y


def _tui_menu(path: tuple[str, ...] = ()) -> list[dict[str, Any]]:
    roots = [
        {
            "key": "status",
            "label": "状态总览",
            "children": [
                {"key": "status-refresh", "label": "刷新状态", "action": "status-refresh"},
                {"key": "status-running", "label": "查看运行实例", "action": "status-running"},
            ],
        },
        {
            "key": "upgrade",
            "label": "升级与回滚",
            "children": [
                {"key": "upgrade-no-restart", "label": "升级（不重启）", "action": "upgrade-no-restart"},
                {"key": "upgrade-restart", "label": "升级（允许重启）", "action": "upgrade-restart"},
                {"key": "upgrade-rollback", "label": "回滚到 commit", "action": "upgrade-rollback"},
            ],
        },
        {
            "key": "permissions",
            "label": "权限管理",
            "children": [
                {"key": "permissions-list", "label": "查看当前权限", "action": "permissions-list"},
                {"key": "permissions-grant", "label": "授权目录", "action": "permissions-grant"},
                {"key": "permissions-revoke", "label": "撤销目录", "action": "permissions-revoke"},
            ],
        },
        {
            "key": "profiles",
            "label": "Profile 多开",
            "children": [
                {"key": "profiles-list", "label": "查看 Profile", "action": "profiles-list"},
                {"key": "profiles-create", "label": "创建 Profile", "action": "profiles-create"},
                {"key": "profiles-launch", "label": "启动 Profile", "action": "profiles-launch"},
            ],
        },
        {
            "key": "logs",
            "label": "最近日志",
            "children": [{"key": "logs-refresh", "label": "刷新日志", "action": "logs-refresh"}],
        },
    ]
    if not path:
        return [{**root, "depth": 0} for root in roots]

    parent = next((root for root in roots if root["key"] == path[-1]), None)
    if parent is None:
        return []
    return [{**child, "depth": 0, "parent": parent["key"]} for child in parent["children"]]


def _tui_prompt(stdscr: Any, prompt: str) -> str:
    height, width = stdscr.getmaxyx()
    curses.echo()
    try:
        curses.curs_set(1)
    except curses.error:
        pass
    try:
        stdscr.move(max(0, height - 1), 0)
        stdscr.clrtoeol()
        stdscr.addnstr(height - 1, 0, prompt, max(1, width - 1))
        stdscr.refresh()
        value = stdscr.getstr(height - 1, min(len(prompt), max(0, width - 2)), max(1, width - len(prompt) - 2))
        decoded = value.decode("utf-8", errors="replace").strip()
        return "" if decoded == "\x1b" else decoded
    finally:
        curses.noecho()
        try:
            curses.curs_set(0)
        except curses.error:
            pass


def _tui_execute_action(stdscr: Any, manager: CodexFlatpakManager, action: str) -> str:
    try:
        if action == "status-refresh":
            manager.status()
            return "状态已刷新"
        if action == "status-running":
            running = manager.status().get("running_instances", "")
            return f"运行实例：{len([line for line in running.splitlines() if line.strip()])} 个"
        if action == "upgrade-no-restart":
            result = manager.upgrade(no_restart=True, on_line=lambda _line: None)
            return f"升级（不重启）{'成功' if result['ok'] else '失败'}，日志：{result['log']}"
        if action == "upgrade-restart":
            result = manager.upgrade(no_restart=False, on_line=lambda _line: None)
            return f"升级（允许重启）{'成功' if result['ok'] else '失败'}，日志：{result['log']}"
        if action == "upgrade-rollback":
            commit = _tui_prompt(stdscr, "输入目标 commit（Esc 取消）：")
            if not commit:
                return "已取消回滚"
            result = manager.rollback(commit, restart=False)
            return f"已回滚到 {result['commit']}"
        if action == "permissions-list":
            manager.permissions()
            return "权限已刷新"
        if action in {"permissions-grant", "permissions-revoke"}:
            value = _tui_prompt(stdscr, "输入目录（可带 :ro，Esc 取消）：")
            if not value:
                return "已取消权限操作"
            if action == "permissions-grant":
                manager.grant_filesystem(value)
                return f"已授权：{value}"
            manager.revoke_filesystem(value)
            return f"已撤销：{value}"
        if action == "profiles-list":
            return f"当前 Profile：{len(manager.list_profiles())} 个"
        if action == "profiles-create":
            name = _tui_prompt(stdscr, "输入 Profile 名称（Esc 取消）：")
            if not name:
                return "已取消创建"
            manager.create_profile(name)
            return f"已创建 Profile：{name}"
        if action == "profiles-launch":
            name = _tui_prompt(stdscr, "输入要启动的 Profile 名称（Esc 取消）：")
            if not name:
                return "已取消启动"
            result = manager.launch_profile(name)
            return f"已启动 Profile：{name}，PID {result.get('pid', '—')}"
        if action == "logs-refresh":
            manager.recent_logs()
            return "日志已刷新"
    except ManagerError as exc:
        return f"操作失败：{exc}"
    return "未执行操作"


def _run_tree_panel(stdscr: Any, manager: CodexFlatpakManager, refresh_seconds: float) -> None:
    curses.curs_set(0)
    stdscr.timeout(500)
    path: list[str] = []
    selected_id = "status"
    state: dict[str, Any] = {}
    message = "Enter 进入/执行；←/Backspace 返回上级；u/U 快捷升级；r 刷新；q 退出"
    last_refresh = 0.0
    scroll = 0

    while True:
        now = time.monotonic()
        if now - last_refresh >= refresh_seconds or not state:
            try:
                state = {
                    "status": manager.status(),
                    "permissions": manager.permissions(),
                    "profiles": manager.list_profiles(),
                    "logs": manager.recent_logs(80),
                }
                last_refresh = now
            except ManagerError as exc:
                state = {"status": {}, "permissions": "", "profiles": [], "logs": ""}
                message = f"读取失败: {exc}"

        nodes = _tui_menu(tuple(path))
        ids = [node["key"] for node in nodes]
        if selected_id not in ids:
            selected_id = ids[0]
        selected = ids.index(selected_id)

        stdscr.erase()
        height, width = stdscr.getmaxyx()
        if width < 78 or height < 12:
            _tui_add(stdscr, 0, 0, "终端窗口太小，请至少使用 78x12；按 q 退出。", width)
            stdscr.refresh()
            key = stdscr.getch()
            if key in (ord("q"), ord("Q")):
                return
            continue

        title_attr = curses.A_BOLD
        stdscr.addnstr(0, 0, " CODEX FLATPAK MANAGER ", width - 1, title_attr)
        breadcrumb = "根目录" if not path else "根目录 / " + " / ".join(path)
        stdscr.addnstr(1, 0, f" 本地控制台 · {breadcrumb} · 手动链路保持不变 ", width - 1, curses.A_DIM)
        divider = min(34, max(26, width // 3))
        for row in range(3, height - 2):
            try:
                stdscr.addch(row, divider, "│")
            except curses.error:
                pass

        visible_rows = max(1, height - 7)
        if selected < scroll:
            scroll = selected
        if selected >= scroll + visible_rows:
            scroll = selected - visible_rows + 1
        shown = nodes[scroll : scroll + visible_rows]
        for row, node in enumerate(shown, start=4):
            index = scroll + row - 4
            prefix = "  " * node["depth"] + ("└─ " if node["depth"] else "├─ ")
            label = prefix + node["label"]
            attr = curses.A_REVERSE if index == selected else curses.A_NORMAL
            stdscr.addnstr(row, 2, label, divider - 4, attr)

        current = nodes[selected]
        key_name = current["key"]
        right_x = divider + 3
        right_width = width - right_x - 2
        stdscr.addnstr(3, right_x, current["label"], right_width, title_attr)
        right_y = 5
        status = state.get("status", {})
        if key_name.startswith("status"):
            build_info = status.get("build_info", {})
            running = [line for line in status.get("running_instances", "").splitlines() if line.strip()]
            for line in (
                f"仓库: {status.get('repository', '未知')}",
                f"应用: {status.get('app_id', APP_ID)}",
                f"Commit: {_short_commit(status.get('installed_commit'))}",
                f"Desktop: {build_info.get('codexAppVersion', '未知')}",
                f"CLI: {build_info.get('codexCliReleaseTag', '未知')}",
                f"Electron: {build_info.get('electronVersion', '未知')}",
                f"运行实例: {len(running)}",
            ):
                right_y = _tui_add(stdscr, right_y, right_x, line, right_width)
        elif key_name.startswith("upgrade"):
            right_y = _tui_add(stdscr, right_y, right_x, "Enter 执行当前子功能。回滚会要求输入目标 commit。", right_width)
            right_y = _tui_add(stdscr, right_y, right_x, "自动升级：已禁用；不同版本请手动执行对应流程", right_width)
        elif key_name.startswith("permissions"):
            right_y = _tui_add(stdscr, right_y, right_x, state.get("permissions", "暂无权限信息"), right_width)
        elif key_name.startswith("profiles"):
            profiles = state.get("profiles", [])
            right_y = _tui_add(stdscr, right_y, right_x, "Profile 数据隔离入口（实验性）", right_width, title_attr)
            for profile in profiles or [{"name": "暂无 Profile", "path": ""}]:
                right_y = _tui_add(stdscr, right_y, right_x, f"• {profile['name']}  {profile['path']}", right_width)
        else:
            right_y = _tui_add(stdscr, right_y, right_x, state.get("logs", "暂无日志"), right_width)
        if current.get("children") is not None:
            _tui_add(stdscr, right_y + 1, right_x, "按 Enter 进入下一级菜单", right_width, curses.A_BOLD)

        stdscr.addnstr(height - 2, 1, message, width - 2, curses.A_DIM)
        stdscr.refresh()
        key = stdscr.getch()
        if key in (ord("q"), ord("Q")):
            return
        if key in (curses.KEY_UP, ord("k")):
            selected_id = nodes[(selected - 1) % len(nodes)]["key"]
        elif key in (curses.KEY_DOWN, ord("j")):
            selected_id = nodes[(selected + 1) % len(nodes)]["key"]
        elif key in (curses.KEY_RIGHT, ord("l")) and current.get("children") is not None:
            path.append(current["key"])
            child_nodes = _tui_menu(tuple(path))
            selected_id = child_nodes[0]["key"] if child_nodes else current["key"]
            scroll = 0
            message = f"已进入：{current['label']}"
        elif key in (curses.KEY_LEFT, curses.KEY_BACKSPACE, 27, ord("h")):
            if path:
                previous = path.pop()
                selected_id = previous
                scroll = 0
                message = "已返回上级菜单"
            else:
                message = "当前已经是根菜单"
        elif key in (ord("r"), ord("R")):
            last_refresh = 0.0
            message = "正在刷新…"
        elif key == ord("u"):
            message = _tui_execute_action(stdscr, manager, "upgrade-no-restart")
            last_refresh = 0.0
        elif key == ord("U"):
            message = _tui_execute_action(stdscr, manager, "upgrade-restart")
            last_refresh = 0.0
        elif key in (curses.KEY_ENTER, 10, 13):
            if current.get("children") is not None:
                path.append(current["key"])
                child_nodes = _tui_menu(tuple(path))
                selected_id = child_nodes[0]["key"] if child_nodes else current["key"]
                scroll = 0
                message = f"已进入：{current['label']}"
            else:
                message = _tui_execute_action(stdscr, manager, current["action"])
                last_refresh = 0.0


def tree_panel(manager: CodexFlatpakManager, plain: bool, refresh_seconds: float) -> int:
    if plain or not sys.stdin.isatty() or not sys.stdout.isatty():
        return plain_panel(manager)
    try:
        curses.wrapper(_run_tree_panel, manager, refresh_seconds)
    except curses.error as exc:
        print(f"[WARN] curses panel unavailable: {exc}", file=sys.stderr)
        return plain_panel(manager)
    return 0


HTML = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Codex Flatpak · 本地控制台</title>
<style>
:root{color-scheme:dark;--bg:#0b1118;--panel:#121c27;--panel2:#172433;--line:#263747;--text:#eef5f7;--muted:#8ea3ad;--accent:#5de1c0;--blue:#8db5ff;--warn:#f4c56b;--danger:#ff8e9e;--radius:18px}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 80% -10%,#18333b 0,#0b1118 42%);color:var(--text);font:14px/1.55 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}button,input{font:inherit}button{border:1px solid var(--line);background:#1d2b38;color:var(--text);border-radius:10px;padding:9px 13px;cursor:pointer;transition:.18s ease}button:hover{border-color:var(--accent);transform:translateY(-1px)}button.primary{background:var(--accent);color:#06231f;border-color:var(--accent);font-weight:700}button.warn{border-color:#806839;color:var(--warn)}input{width:100%;background:#0c151e;border:1px solid var(--line);color:var(--text);border-radius:10px;padding:10px 12px;outline:none}input:focus{border-color:var(--accent)}.shell{display:grid;grid-template-columns:248px minmax(0,1fr);min-height:100vh}.rail{border-right:1px solid var(--line);padding:26px 18px;background:rgba(7,13,19,.74);position:sticky;top:0;height:100vh}.brand{display:flex;gap:11px;align-items:center;margin:0 8px 38px}.brand-mark{width:34px;height:34px;border-radius:11px;background:linear-gradient(135deg,var(--accent),#83a9ff);display:grid;place-items:center;color:#07131a;font-weight:900}.brand strong{display:block}.brand small{color:var(--muted)}.nav{display:grid;gap:7px}.nav a{padding:11px 12px;border-radius:10px;color:var(--muted);text-decoration:none}.nav a.active,.nav a:hover{background:#182a35;color:var(--text)}.rail-note{position:absolute;bottom:26px;left:26px;right:20px;color:var(--muted);font-size:12px}.main{padding:28px clamp(20px,4vw,54px) 50px;max-width:1450px;width:100%}.topbar{display:flex;justify-content:space-between;align-items:center;gap:20px;margin-bottom:28px}.eyebrow{color:var(--accent);font-size:12px;letter-spacing:.12em;text-transform:uppercase}.topbar h1{font-size:29px;line-height:1.15;margin:5px 0 0;letter-spacing:-.03em}.connection{display:flex;align-items:center;gap:8px;color:var(--muted);white-space:nowrap}.dot{width:8px;height:8px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 5px rgba(93,225,192,.12)}.hero{display:flex;justify-content:space-between;gap:28px;align-items:flex-end;border-bottom:1px solid var(--line);padding-bottom:25px;margin-bottom:22px}.hero p{color:var(--muted);max-width:660px;margin:10px 0 0}.hero-actions{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:13px;margin-bottom:22px}.metric{background:linear-gradient(145deg,rgba(23,36,51,.92),rgba(16,27,38,.92));border:1px solid var(--line);border-radius:var(--radius);padding:17px 18px;min-height:112px}.metric-label{color:var(--muted);font-size:12px;margin-bottom:15px}.metric-value{font-size:22px;letter-spacing:-.03em;font-weight:700;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.metric-sub{font-size:12px;color:var(--muted);margin-top:7px}.layout{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(300px,.85fr);gap:16px}.panel{background:rgba(18,28,39,.86);border:1px solid var(--line);border-radius:var(--radius);padding:19px;margin-bottom:16px}.panel-head{display:flex;justify-content:space-between;align-items:flex-start;gap:15px;margin-bottom:16px}.panel h2{font-size:16px;margin:0}.panel p{color:var(--muted);margin:5px 0 0;font-size:12px}.actions{display:flex;gap:8px;flex-wrap:wrap}.status-table{display:grid;grid-template-columns:145px 1fr;gap:9px 16px;color:var(--muted);font-size:13px}.status-table b{color:var(--text);font-weight:600;overflow-wrap:anywhere}.permission-box{min-height:175px;background:#0a121a;border:1px solid #1c2a37;border-radius:12px;color:#b9d0d4;font:12px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;padding:13px;white-space:pre-wrap;overflow:auto}.form-row{display:grid;grid-template-columns:1fr auto;gap:8px;margin:15px 0}.profile-list{display:grid;gap:8px}.profile{display:flex;justify-content:space-between;gap:12px;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:#101b26}.profile small{color:var(--muted);display:block;overflow:hidden;text-overflow:ellipsis}.log{min-height:240px;max-height:430px}.toast{position:fixed;right:22px;bottom:22px;background:#e9fff8;color:#07221c;border-radius:10px;padding:12px 15px;box-shadow:0 15px 40px #0008;transform:translateY(20px);opacity:0;pointer-events:none;transition:.2s}.toast.show{transform:none;opacity:1}.muted{color:var(--muted)}@media(max-width:900px){.shell{display:block}.rail{height:auto;position:static;border-right:0;border-bottom:1px solid var(--line);padding:15px}.brand{margin-bottom:13px}.nav{display:flex;overflow:auto}.rail-note{display:none}.main{padding:23px 15px 40px}.hero{display:block}.hero-actions{justify-content:flex-start;margin-top:18px}.layout{grid-template-columns:1fr}}@media(max-width:600px){.grid{grid-template-columns:1fr}.topbar{align-items:flex-start}.connection{font-size:12px}.status-table{grid-template-columns:105px 1fr}.topbar h1{font-size:24px}}
</style></head><body>
<div class="shell"><aside class="rail"><div class="brand"><div class="brand-mark">C</div><div><strong>Codex Flatpak</strong><small>Local Manager</small></div></div><nav class="nav"><a class="active" href="#overview">总览</a><a href="#operations">升级</a><a href="#permissions">权限</a><a href="#profiles">Profiles</a><a href="#logs">日志</a></nav><div class="rail-note">仅本机回环访问<br>手动链路仍然保留</div></aside>
<main class="main"><div class="topbar"><div><div class="eyebrow">LOCAL CONTROL PLANE</div><h1>Codex Desktop 控制台</h1></div><div class="connection"><span class="dot"></span><span>Loopback service · <span id="last-refresh">—</span></span></div></div>
<section class="hero" id="overview"><div><h2>清晰地管理构建、权限和运行 profile</h2><p>所有升级操作仍然委托给仓库现有脚本。你可以从这里查看状态、手动触发升级，或回到终端使用同一套命令。</p></div><div class="hero-actions"><button onclick="refreshAll()">刷新状态</button><button class="primary" onclick="upgrade(true)">升级 · 不重启</button><button class="warn" onclick="upgrade(false)">升级 · 允许重启</button></div></section>
<section class="grid"><div class="metric"><div class="metric-label">INSTALLED COMMIT</div><div class="metric-value" id="commit">加载中</div><div class="metric-sub" id="repo">—</div></div><div class="metric"><div class="metric-label">CODEX CLI RELEASE</div><div class="metric-value" id="release">—</div><div class="metric-sub" id="electron">Electron —</div></div><div class="metric"><div class="metric-label">RUNNING INSTANCES</div><div class="metric-value" id="instances">—</div><div class="metric-sub">user Flatpak session</div></div></section>
<div class="layout"><div><section class="panel" id="operations"><div class="panel-head"><div><h2>状态详情</h2><p>当前安装、仓库和运行信息</p></div><span class="muted" id="manager-version">Manager —</span></div><div class="status-table" id="status-table"></div></section>
<section class="panel" id="permissions"><div class="panel-head"><div><h2>权限管理</h2><p>Flatpak 用户级权限，修改后对应用生效</p></div></div><div class="form-row"><input id="fs" placeholder="例如 /home/user/project 或 /path:ro"><button onclick="changePermission('grant')">授权</button></div><div class="actions"><button onclick="changePermission('revoke')">撤销当前路径</button><button onclick="loadPermissions()">重新读取</button></div><pre class="permission-box" id="permissions-box">加载中…</pre></section></div>
<div><section class="panel" id="profiles"><div class="panel-head"><div><h2>Profile 多开</h2><p>独立 XDG 数据目录，当前为实验性入口</p></div></div><div class="form-row"><input id="profile" value="work" pattern="[A-Za-z0-9._-]+"><button onclick="createProfile()">创建</button></div><div class="profile-list" id="profile-list"></div><div class="actions" style="margin-top:13px"><button onclick="launchProfile()">启动当前 Profile</button></div></section>
<section class="panel" id="logs"><div class="panel-head"><div><h2>最近操作日志</h2><p>用于确认升级、回滚和权限动作</p></div><button onclick="loadLogs()">刷新日志</button></div><pre class="permission-box log" id="logs-box">加载中…</pre></section></div></div></main></div><div class="toast" id="toast"></div>
<script>
const TOKEN=__TOKEN__;const query='?token='+encodeURIComponent(TOKEN);const $=id=>document.getElementById(id);
async function api(path,options){const opts=Object.assign({headers:{'Content-Type':'application/json'}},options||{});const response=await fetch(path+query,opts);const text=await response.text();if(!response.ok)throw Error(text||response.statusText);return text?JSON.parse(text):{};}
function toast(message){$('toast').textContent=message;$('toast').classList.add('show');setTimeout(()=>$('toast').classList.remove('show'),3600)}
function esc(value){return String(value??'—').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function renderStatus(data){const info=data.build_info||{};const running=(data.running_instances||'').split('\n').filter(Boolean);$('commit').textContent=data.installed_commit?data.installed_commit.slice(0,12):'未安装';$('repo').textContent=data.repository||'—';$('release').textContent=info.codexCliReleaseTag||'未知';$('electron').textContent='Electron '+(info.electronVersion||'未知');$('instances').textContent=running.length;$('manager-version').textContent='Manager '+(data.manager_version||'—');$('status-table').innerHTML=[['应用 ID',data.app_id],['完整 commit',data.installed_commit||'未安装'],['仓库路径',data.repository],['运行实例',running.length?running.join('\n'):'暂无']].map(row=>'<div>'+esc(row[0])+'</div><b>'+esc(row[1])+'</b>').join('');$('last-refresh').textContent=new Date().toLocaleTimeString();}
async function refreshStatus(){renderStatus(await api('/api/status'))}
async function loadPermissions(){$('permissions-box').textContent=(await api('/api/permissions')).permissions||'暂无权限信息'}
async function loadProfiles(){const data=await api('/api/profiles');$('profile-list').innerHTML=data.profiles.length?data.profiles.map(p=>'<div class="profile"><div><b>'+esc(p.name)+'</b><small>'+esc(p.path)+'</small></div><span class="muted">实验性</span></div>').join(''):'<div class="muted">暂无 Profile</div>'}
async function loadLogs(){$('logs-box').textContent=(await api('/api/logs')).logs||'暂无日志'}
async function refreshAll(){try{await Promise.all([refreshStatus(),loadPermissions(),loadProfiles(),loadLogs()]);toast('状态已刷新')}catch(error){toast('读取失败：'+error.message)}}
async function upgrade(noRestart){try{toast('升级任务已提交，正在等待现有脚本完成…');const result=await api('/api/upgrade',{method:'POST',body:JSON.stringify({no_restart:noRestart})});toast(result.ok?'升级成功':'升级失败，请查看日志');await refreshAll()}catch(error){toast('升级失败：'+error.message)}}
async function changePermission(action){try{const value=$('fs').value;if(!value)throw Error('请先输入目录');await api('/api/permissions/'+action,{method:'POST',body:JSON.stringify({filesystem:value})});toast(action==='grant'?'目录权限已授权':'目录权限已撤销');await loadPermissions()}catch(error){toast('权限操作失败：'+error.message)}}
async function createProfile(){try{await api('/api/profiles/create',{method:'POST',body:JSON.stringify({name:$('profile').value})});toast('Profile 已创建');await loadProfiles()}catch(error){toast('创建失败：'+error.message)}}
async function launchProfile(){try{const result=await api('/api/profiles/launch',{method:'POST',body:JSON.stringify({name:$('profile').value})});toast('Profile 已启动，PID '+(result.pid||'—'));await loadProfiles()}catch(error){toast('启动失败：'+error.message)}}
refreshAll();setInterval(refreshStatus,15000);
</script></body></html>"""


class ManagerHTTPServer(ThreadingHTTPServer):
    manager: CodexFlatpakManager
    token: str


class ManagerHandler(BaseHTTPRequestHandler):
    server: ManagerHTTPServer

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _authorized(self) -> bool:
        parsed = urllib.parse.urlsplit(self.path)
        query_token = urllib.parse.parse_qs(parsed.query).get("token", [""])[0]
        supplied = self.headers.get("X-Codex-Manager-Token", query_token)
        return bool(supplied) and hmac.compare_digest(supplied, self.server.token)

    def _reply(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _error(self, message: str, status: HTTPStatus = HTTPStatus.BAD_REQUEST) -> None:
        self._reply({"ok": False, "error": message}, status)

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        value = json.loads(raw.decode("utf-8"))
        if not isinstance(value, dict):
            raise ManagerError("JSON body must be an object.")
        return value

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._error("Unauthorized", HTTPStatus.UNAUTHORIZED)
            return
        path = urllib.parse.urlsplit(self.path).path
        manager = self.server.manager
        try:
            if path in {"/", "/index.html"}:
                token_json = json.dumps(self.server.token)
                data = HTML.replace("__TOKEN__", token_json).encode("utf-8")
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif path == "/api/status":
                self._reply(manager.status())
            elif path == "/api/permissions":
                self._reply({"permissions": manager.permissions()})
            elif path == "/api/profiles":
                self._reply({"profiles": manager.list_profiles()})
            elif path == "/api/logs":
                self._reply({"logs": manager.recent_logs()})
            else:
                self._error("Not found", HTTPStatus.NOT_FOUND)
        except ManagerError as exc:
            self._error(str(exc))

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._error("Unauthorized", HTTPStatus.UNAUTHORIZED)
            return
        path = urllib.parse.urlsplit(self.path).path
        manager = self.server.manager
        try:
            body = self._body()
            if path == "/api/upgrade":
                result = manager.upgrade(
                    no_restart=bool(body.get("no_restart", False)),
                    no_build=bool(body.get("no_build", False)),
                    release_tag=str(body["release_tag"]) if body.get("release_tag") else None,
                    force_download=bool(body.get("force_download", False)),
                    on_line=lambda _line: None,
                )
            elif path == "/api/permissions/grant":
                result = manager.grant_filesystem(str(body.get("filesystem", "")))
            elif path == "/api/permissions/revoke":
                result = manager.revoke_filesystem(str(body.get("filesystem", "")))
            elif path == "/api/profiles/create":
                result = manager.create_profile(str(body.get("name", "")))
            elif path == "/api/profiles/launch":
                result = manager.launch_profile(str(body.get("name", "")))
            else:
                self._error("Not found", HTTPStatus.NOT_FOUND)
                return
            self._reply(result)
        except (ManagerError, ValueError, json.JSONDecodeError) as exc:
            self._error(str(exc))


def serve(manager: CodexFlatpakManager, host: str, port: int, open_browser: bool) -> int:
    token = manager.token()
    server = ManagerHTTPServer((host, port), ManagerHandler)
    server.manager = manager
    server.token = token
    url = f"http://{host}:{port}/?token={urllib.parse.quote(token)}"
    print(f"Codex Flatpak Manager listening at {url}")
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()
    return 0


def add_common_repo(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repo", help="Codex Flatpak repository path")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage the Codex Desktop Flatpak repository.")
    parser.add_argument("--repo", help="Codex Flatpak repository path")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="Show installed commit and running instances")
    status.add_argument("--json", action="store_true")

    upgrade = sub.add_parser("upgrade", help="Call the existing repository upgrade script")
    upgrade.add_argument("--no-restart", action="store_true")
    upgrade.add_argument("--no-build", action="store_true")
    upgrade.add_argument("--release-tag")
    upgrade.add_argument("--force-download", action="store_true")

    rollback = sub.add_parser("rollback", help="Switch to a known Flatpak commit")
    rollback.add_argument("commit")
    rollback.add_argument("--restart", action="store_true")

    permissions = sub.add_parser("permissions", help="Manage user Flatpak filesystem overrides")
    permissions_sub = permissions.add_subparsers(dest="permissions_command", required=True)
    permissions_list = permissions_sub.add_parser("list")
    permissions_list.add_argument("--json", action="store_true")
    grant = permissions_sub.add_parser("grant")
    grant.add_argument("--filesystem", required=True)
    revoke = permissions_sub.add_parser("revoke")
    revoke.add_argument("--filesystem", required=True)

    profiles = sub.add_parser("profile", help="Manage experimental isolated data profiles")
    profiles_sub = profiles.add_subparsers(dest="profile_command", required=True)
    profile_create = profiles_sub.add_parser("create")
    profile_create.add_argument("name")
    profile_list = profiles_sub.add_parser("list")
    profile_list.add_argument("--json", action="store_true")
    profile_launch = profiles_sub.add_parser("launch")
    profile_launch.add_argument("name")
    profile_launch.add_argument("--foreground", action="store_true")

    panel = sub.add_parser("panel", help="Run the terminal tree panel")
    panel.add_argument("--plain", action="store_true", help="Print a non-interactive tree snapshot")
    panel.add_argument("--refresh", type=float, default=3.0, help="Refresh interval in seconds")

    serve_parser = sub.add_parser("serve", help="Run the loopback web panel")
    serve_parser.add_argument("--host", default="127.0.0.1")
    serve_parser.add_argument("--port", type=int, default=8787)
    serve_parser.add_argument("--open", action="store_true", dest="open_browser")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        manager = CodexFlatpakManager(args.repo)
        if args.command == "status":
            result = manager.status()
            print(json_text(result) if args.json else json_text(result))
            return 0
        if args.command == "upgrade":
            result = manager.upgrade(
                no_restart=args.no_restart,
                no_build=args.no_build,
                release_tag=args.release_tag,
                force_download=args.force_download,
            )
            return int(not result["ok"])
        if args.command == "rollback":
            print(json_text(manager.rollback(args.commit, args.restart)))
            return 0
        if args.command == "permissions":
            if args.permissions_command == "list":
                raw = manager.permissions()
                print(json_text({"permissions": raw}) if args.json else raw)
                return 0
            if args.permissions_command == "grant":
                print(json_text(manager.grant_filesystem(args.filesystem)))
                return 0
            print(json_text(manager.revoke_filesystem(args.filesystem)))
            return 0
        if args.command == "profile":
            if args.profile_command == "create":
                print(json_text(manager.create_profile(args.name)))
            elif args.profile_command == "list":
                result = manager.list_profiles()
                print(json_text({"profiles": result}) if args.json else json_text(result))
            else:
                print(json_text(manager.launch_profile(args.name, args.foreground)))
            return 0
        if args.command == "panel":
            return tree_panel(manager, args.plain, max(0.5, args.refresh))
        return serve(manager, args.host, args.port, args.open_browser)
    except ManagerError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
