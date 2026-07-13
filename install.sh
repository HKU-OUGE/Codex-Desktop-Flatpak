#!/bin/sh
# POSIX installer: callable from bash, zsh, dash, or another POSIX shell.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ID="com.openai.CodexLinuxX64"
INSTALL_DIR=${CODEX_MANAGER_INSTALL_DIR:-"$HOME/.local/share/codex-flatpak-manager"}
CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
CONFIG_DIR="$CONFIG_HOME/codex-flatpak-manager"
BIN_DIR=${CODEX_MANAGER_BIN_DIR:-"$HOME/.local/bin"}
SYSTEMD_DIR="$CONFIG_HOME/systemd/user"
MANAGER="$INSTALL_DIR/codex_flatpak_manager.py"
UNIT="$SYSTEMD_DIR/codex-flatpak-manager.service"
AUTO_UNIT="$SYSTEMD_DIR/codex-flatpak-manager-auto-upgrade.service"
AUTO_TIMER="$SYSTEMD_DIR/codex-flatpak-manager-auto-upgrade.timer"
DESKTOP_ACTION="install"
ACTION_EXPLICIT=0
PERMISSION_MODE=""
CURRENT_PERMISSION_MODE="none"
CURRENT_PERMISSION_STATUS="not-installed"

if [ -n "${FLATPAK_ID:-}" ] && [ "${CODEX_INSTALL_ON_HOST:-0}" != "1" ]; then
  if ! command -v flatpak-spawn >/dev/null 2>&1; then
    printf '[ERROR] This installer is running inside Flatpak, but flatpak-spawn is unavailable.\n' >&2
    exit 1
  fi
  exec flatpak-spawn --host env CODEX_INSTALL_ON_HOST=1 "$ROOT/install.sh" "$@"
fi

cat <<'NOTICE'
=== Codex Desktop Flatpak 安装程序 ===
说明：本程序会在本机下载公开来源、构建并安装锁定版本的 Codex Desktop，随后可选安装本地管理面板。
免责声明：本项目不是 OpenAI 官方 Linux 安装包；使用者应自行确认来源、许可证和运行权限，并自行承担安装、升级及使用风险。
NOTICE

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

permission_label() {
  case "$1" in
    none) printf '%s' '无额外文件权限（保留应用默认 Documents 入口）' ;;
    home) printf '%s' 'Home 目录读写权限' ;;
    all) printf '%s' '所有文件只读权限' ;;
    host) printf '%s' 'Host 全部文件读写权限' ;;
    keep) printf '%s' '保留当前权限' ;;
    *) printf '%s' '未知权限模式' ;;
  esac
}

detect_current_permission_mode() {
  CURRENT_PERMISSION_MODE="none"
  CURRENT_PERMISSION_STATUS="not-installed"
  if ! command -v flatpak >/dev/null 2>&1 ||
    ! flatpak info --user "$APP_ID" >/dev/null 2>&1; then
    return
  fi

  CURRENT_PERMISSION_STATUS="known"
  filesystems="$(flatpak override --user --show "$APP_ID" 2>/dev/null |
    awk -F= '/^filesystems=/{print $2; exit}' | sed 's/;$//')"
  case "$filesystems" in
    "") CURRENT_PERMISSION_MODE="none" ;;
    home) CURRENT_PERMISSION_MODE="home" ;;
    host:ro) CURRENT_PERMISSION_MODE="all" ;;
    host) CURRENT_PERMISSION_MODE="host" ;;
    *)
      CURRENT_PERMISSION_MODE="none"
      CURRENT_PERMISSION_STATUS="unknown"
      warn "Could not map the current Flatpak filesystem permissions; defaulting to no extra filesystem access."
      ;;
  esac
}

permission_option() {
  mode="$1"
  number="$2"
  label="$(permission_label "$mode")"
  marker=""
  [ "$CURRENT_PERMISSION_MODE" = "$mode" ] && marker=" ← 当前"
  printf '  %s) %s%s\n' "$number" "$label" "$marker"
}

show_current_permissions() {
  if command -v flatpak >/dev/null 2>&1 && flatpak info --user "$APP_ID" >/dev/null 2>&1; then
    info "识别到当前权限类型：$(permission_label "$CURRENT_PERMISSION_MODE")"
    info "当前 Flatpak 文件权限："
    flatpak override --user --show "$APP_ID" 2>/dev/null || true
  else
    info "当前还没有已安装的 Codex Flatpak。"
  fi
}

choose_install_action() {
  if [ "$INSTALL_DESKTOP" = "0" ]; then
    DESKTOP_ACTION="skip"
    return
  fi
  if [ "$ACTION_EXPLICIT" = "1" ]; then
    return
  fi
  if [ "${CODEX_FORCE_REINSTALL:-0}" = "1" ]; then
    DESKTOP_ACTION="install"
    return
  fi
  if ! command -v flatpak >/dev/null 2>&1 ||
    ! flatpak info --user "$APP_ID" >/dev/null 2>&1; then
    DESKTOP_ACTION="install"
    return
  fi
  if [ "${CODEX_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    DESKTOP_ACTION="permissions"
    info "Detected an existing Codex installation; non-interactive mode will update permissions only."
    return
  fi

  show_current_permissions
  printf '%s\n' '检测到 Codex Desktop 已安装，请选择：'
  printf '%s' '  1) 重新下载、构建并安装 Desktop  2) 不重新安装，只更新权限  3) 取消 [2]: '
  IFS= read -r reply || reply=""
  case "$reply" in
    1) DESKTOP_ACTION="install" ;;
    2|"") DESKTOP_ACTION="permissions" ;;
    3) info "已取消。"; exit 0 ;;
    *) printf '[ERROR] 无效选择：%s\n' "$reply" >&2; exit 2 ;;
  esac
}

choose_permission_mode() {
  if [ "$INSTALL_DESKTOP" = "0" ]; then
    PERMISSION_MODE="keep"
    return
  fi
  if [ -n "${CODEX_PERMISSION_MODE:-}" ]; then
    PERMISSION_MODE="$CODEX_PERMISSION_MODE"
  elif [ "${CODEX_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if [ "$DESKTOP_ACTION" = "install" ]; then
      PERMISSION_MODE="$CURRENT_PERMISSION_MODE"
    else
      PERMISSION_MODE="$CURRENT_PERMISSION_MODE"
    fi
    info "Non-interactive mode: $(permission_label "$PERMISSION_MODE")"
    return
  else
    printf '\n%s\n' '请选择 Codex Desktop 的文件访问权限：'
    permission_option none 1
    permission_option home 2
    permission_option all 3
    permission_option host 4
    if [ "$DESKTOP_ACTION" = "permissions" ]; then
      printf '%s\n' '  5) 保留当前原始配置（不建议用于未知配置）'
    fi
    case "$CURRENT_PERMISSION_MODE" in
      none) default_choice=1 ;;
      home) default_choice=2 ;;
      all) default_choice=3 ;;
      host) default_choice=4 ;;
      *) default_choice=1 ;;
    esac
    printf '选择 [%s]: ' "$default_choice"
    IFS= read -r reply || reply=""
    [ -n "$reply" ] || reply="$default_choice"
    case "$reply" in
      1|"") PERMISSION_MODE="none" ;;
      2) PERMISSION_MODE="home" ;;
      3) PERMISSION_MODE="all" ;;
      4) PERMISSION_MODE="host" ;;
      5) [ "$DESKTOP_ACTION" = "permissions" ] || {
           printf '[ERROR] 无效选择：%s\n' "$reply" >&2; exit 2;
         }
         PERMISSION_MODE="keep" ;;
      *) printf '[ERROR] 无效选择：%s\n' "$reply" >&2; exit 2 ;;
    esac
  fi
  case "$PERMISSION_MODE" in
    none|home|all|host|keep) ;;
    *) printf '[ERROR] CODEX_PERMISSION_MODE 必须是 none、home、all、host 或 keep。\n' >&2; exit 2 ;;
  esac
  info "Selected file permission: $(permission_label "$PERMISSION_MODE")"
}

apply_permissions() {
  mode="$1"
  [ "$mode" = "keep" ] && {
    info "Keeping current Flatpak file permissions"
    return
  }
  flatpak override --user \
    --nofilesystem=host \
    --nofilesystem=home \
    --nofilesystem=xdg-documents \
    "$APP_ID"
  case "$mode" in
    none) ;;
    home) flatpak override --user --filesystem=home "$APP_ID" ;;
    all) flatpak override --user --filesystem=host:ro "$APP_ID" ;;
    host) flatpak override --user --filesystem=host "$APP_ID" ;;
  esac
  info "Applied file permission: $(permission_label "$mode")"
  flatpak override --user --show "$APP_ID" 2>/dev/null || true
}

print_web_url_when_ready() {
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    if [ -s "$CONFIG_DIR/token" ]; then
      info "Web panel: http://127.0.0.1:8787/?token=$(cat "$CONFIG_DIR/token")"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.25
  done
  warn "Web service started but its access token is not available yet"
  return 1
}

build_info_value() {
  key="$1"
  python3 - "$ROOT/flatpak-sources/build-info.json" "$key" <<'PY'
import json
import sys
from pathlib import Path

path, key = sys.argv[1:]
try:
    value = json.loads(Path(path).read_text(encoding="utf-8")).get(key, "")
except (OSError, json.JSONDecodeError):
    value = ""
print(value)
PY
}

install_current_desktop() {
  missing_tools=""
  for tool in 7z curl file flatpak flatpak-builder node npm python3 sha256sum tar unzip; do
    command -v "$tool" >/dev/null 2>&1 || missing_tools="$missing_tools $tool"
  done
  if [ -n "$missing_tools" ]; then
    printf '[ERROR] Missing build tools:%s\n' "$missing_tools" >&2
    printf '[ERROR] Install them with: sudo apt install flatpak flatpak-builder p7zip-full curl file nodejs npm python3 python3-pil unzip tar\n' >&2
    exit 1
  fi
  if ! flatpak info --user org.freedesktop.Sdk//24.08 >/dev/null 2>&1; then
    info "Flatpak SDK 24.08 is missing; adding Flathub if necessary"
    flatpak --user remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
    info "Installing Flatpak SDK 24.08 for the local build"
    flatpak --user install -y flathub org.freedesktop.Sdk//24.08
  fi
  for required in \
    "$ROOT/com.openai.CodexLinuxX64.yml" \
    "$ROOT/build-x86_64-flatpak.sh"; do
    [ -e "$required" ] || {
      printf '[ERROR] Required build file is missing: %s\n' "$required" >&2
      exit 1
    }
  done

  info "Downloading and building the pinned Codex Desktop version"
  "$ROOT/build-x86_64-flatpak.sh"

  app_version=$(build_info_value codexAppVersion)
  cli_tag=$(build_info_value codexCliReleaseTag)
  [ -n "$app_version" ] || app_version="锁定版本"
  [ -n "$cli_tag" ] || cli_tag="未知 CLI release"
  info "Installed pinned Codex Desktop: app=$app_version, cli=$cli_tag"

  if [ -x "$ROOT/install-codex-desktop-integration.sh" ]; then
    CODEX_INTEGRATION_SKIP_RESTART=1 "$ROOT/install-codex-desktop-integration.sh"
  fi

  installed_commit=$(flatpak info --user --show-commit com.openai.CodexLinuxX64 2>/dev/null || true)
  [ -n "$installed_commit" ] || {
    printf '[ERROR] Codex Desktop was not installed successfully.\n' >&2
    exit 1
  }
  installed_cli=$(flatpak run --user --command=sh com.openai.CodexLinuxX64 -lc \
    '/app/lib/codex/resources/codex --version' 2>/dev/null || true)
  info "Installed Codex Desktop commit: $installed_commit"
  [ -n "$installed_cli" ] && info "Installed Codex CLI: $installed_cli"
}

disable_auto_upgrade() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now codex-flatpak-manager-auto-upgrade.timer >/dev/null 2>&1 || true
    systemctl --user stop codex-flatpak-manager-auto-upgrade.service >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f "$AUTO_UNIT" "$AUTO_TIMER"
  info "Automatic upgrades are disabled and their user timer was removed"
}

usage() {
  cat <<EOF
Usage: ./install.sh [--enable] [--disable] [--manager-only] [--reinstall] [--permissions-only]

Download and build the repository's pinned Codex Desktop version, then install the optional manager.
The existing manual build and upgrade scripts are not replaced.

  --enable   Enable and start the optional loopback web service.
  --disable  Disable the optional web service if it is already enabled.
  --manager-only  Install only the manager; do not build or install Desktop.
  --reinstall  Rebuild and reinstall Desktop without asking when it is already installed.
  --permissions-only  Skip Desktop installation and update only the selected permissions.
  --permission=MODE  Use none, home, all, host, or keep without prompting.
  --enable-auto   Deprecated compatibility option; automatic upgrades stay disabled.
  --disable-auto  Keep automatic upgrades disabled (the default).
EOF
}

ENABLE=0
DISABLE=0
INSTALL_DESKTOP=1
for arg in "$@"; do
  case "$arg" in
    --enable) ENABLE=1 ;;
    --disable) DISABLE=1 ;;
    --manager-only) INSTALL_DESKTOP=0 ;;
    --reinstall) DESKTOP_ACTION="install"; ACTION_EXPLICIT=1 ;;
    --permissions-only) DESKTOP_ACTION="permissions"; ACTION_EXPLICIT=1 ;;
    --permission=*) PERMISSION_MODE=${arg#*=} ;;
    --enable-auto) warn "--enable-auto is deprecated and ignored; automatic upgrades are disabled" ;;
    --disable-auto) : ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[ERROR] Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$DESKTOP_ACTION" = "permissions" ] && [ "$INSTALL_DESKTOP" = "0" ]; then
  printf '[ERROR] --permissions-only cannot be combined with --manager-only.\n' >&2
  exit 2
fi

detect_current_permission_mode
choose_install_action
choose_permission_mode

if [ "$DESKTOP_ACTION" = "install" ]; then
  install_current_desktop
elif [ "$DESKTOP_ACTION" = "permissions" ]; then
  command -v flatpak >/dev/null 2>&1 || {
    printf '[ERROR] Missing flatpak; cannot update permissions.\n' >&2
    exit 1
  }
  flatpak info --user "$APP_ID" >/dev/null 2>&1 || {
    printf '[ERROR] $APP_ID is not installed; run ./install.sh first.\n' >&2
    exit 1
  }
  apply_permissions "$PERMISSION_MODE"
fi

if [ "$DESKTOP_ACTION" = "install" ]; then
  apply_permissions "$PERMISSION_MODE"
fi

if [ ! -f "$ROOT/manager/codex_flatpak_manager.py" ]; then
  printf '[ERROR] Manager source is missing under %s.\n' "$ROOT/manager" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$BIN_DIR"
cp "$ROOT/manager/codex_flatpak_manager.py" "$MANAGER"
chmod 755 "$MANAGER"
printf '%s\n' "$ROOT" >"$CONFIG_DIR/repo"
chmod 644 "$CONFIG_DIR/repo"

cat >"$BIN_DIR/codex-flatpak-manager" <<EOF
#!/bin/sh
exec /usr/bin/env python3 "$MANAGER" "\$@"
EOF
chmod 755 "$BIN_DIR/codex-flatpak-manager"

mkdir -p "$SYSTEMD_DIR"
cat >"$UNIT" <<'EOF'
[Unit]
Description=Codex Flatpak Manager local web panel
After=graphical-session.target

[Service]
Type=simple
EOF
cat >>"$UNIT" <<EOF
ExecStart=/usr/bin/env python3 "$MANAGER" serve --host 127.0.0.1 --port 8787
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || warn "Could not reload the user systemd manager"
  if [ "$DISABLE" = "1" ]; then
    systemctl --user disable --now codex-flatpak-manager.service || true
    info "Disabled optional manager web service"
  elif [ "$ENABLE" = "1" ]; then
    if systemctl --user is-active --quiet codex-flatpak-manager.service; then
      systemctl --user restart codex-flatpak-manager.service ||
        warn "Could not restart the optional manager web service"
    else
      systemctl --user enable --now codex-flatpak-manager.service ||
        warn "Could not enable the optional manager web service"
    fi
    print_web_url_when_ready || true
  fi
else
  warn "systemctl is unavailable; CLI was installed but the optional web service was not enabled"
fi

disable_auto_upgrade

info "Installed CLI: $BIN_DIR/codex-flatpak-manager"
info "Repository configured: $ROOT"
if [ "$ENABLE" = "0" ]; then
  info "Web service is opt-in. Start it with: codex-flatpak-manager serve --open"
fi
info "Automatic upgrades are disabled; use the manual upgrade command when the version-specific flow is ready"
