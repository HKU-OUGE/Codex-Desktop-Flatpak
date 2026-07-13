#!/bin/sh
# POSIX installer: callable from bash, zsh, dash, or another POSIX shell.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR=${CODEX_MANAGER_INSTALL_DIR:-"$HOME/.local/share/codex-flatpak-manager"}
CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
CONFIG_DIR="$CONFIG_HOME/codex-flatpak-manager"
BIN_DIR=${CODEX_MANAGER_BIN_DIR:-"$HOME/.local/bin"}
SYSTEMD_DIR="$CONFIG_HOME/systemd/user"
MANAGER="$INSTALL_DIR/codex_flatpak_manager.py"
UNIT="$SYSTEMD_DIR/codex-flatpak-manager.service"
AUTO_UNIT="$SYSTEMD_DIR/codex-flatpak-manager-auto-upgrade.service"
AUTO_TIMER="$SYSTEMD_DIR/codex-flatpak-manager-auto-upgrade.timer"

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
Usage: ./install.sh [--enable] [--disable] [--manager-only]

Download and build the repository's pinned Codex Desktop version, then install the optional manager.
The existing manual build and upgrade scripts are not replaced.

  --enable   Enable and start the optional loopback web service.
  --disable  Disable the optional web service if it is already enabled.
  --manager-only  Install only the manager; do not build or install Desktop.
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
    --enable-auto) warn "--enable-auto is deprecated and ignored; automatic upgrades are disabled" ;;
    --disable-auto) : ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[ERROR] Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$INSTALL_DESKTOP" = "1" ]; then
  install_current_desktop
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
