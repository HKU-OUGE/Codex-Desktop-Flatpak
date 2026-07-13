#!/bin/sh
set -eu

APP_ID="com.openai.CodexLinuxX64"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CODEX_LANG="${CODEX_LANG:-auto}"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

detect_language() {
  case "$CODEX_LANG" in
    zh|zh_*) CODEX_LANG="zh" ;;
    en|en_*) CODEX_LANG="en" ;;
    auto|"")
      locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
      case "$locale_name" in
        zh*|*_CN*|*_TW*|*_HK*|*_MO*) CODEX_LANG="zh" ;;
        *) CODEX_LANG="en" ;;
      esac
      ;;
    *)
      warn "Unsupported CODEX_LANG=$CODEX_LANG; falling back to automatic detection."
      CODEX_LANG="auto"
      detect_language
      ;;
  esac
}

print_notice() {
  if [ "$CODEX_LANG" = "zh" ]; then
    cat <<'NOTICE'
=== Codex Desktop 桌面集成程序 ===
说明：根据系统语言显示提示；本程序只安装桌面入口、图标和窗口修复，并检测停用旧的焦点辅助服务。
免责声明：本项目不是 OpenAI 官方 Linux 安装包；桌面集成和窗口修复的影响由使用者自行确认并承担。
NOTICE
  else
    cat <<'NOTICE'
=== Codex Desktop desktop integration ===
Notice: Messages follow the system language. This script installs the desktop entry, icons, and window patch, and disables the legacy focus helper when found.
Disclaimer: This is not an official OpenAI Linux package. Review and accept the effects of desktop integration and window management yourself.
NOTICE
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

find_node() {
  if command -v node >/dev/null 2>&1; then
    command -v node
    return
  fi
  if command -v nodejs >/dev/null 2>&1; then
    command -v nodejs
    return
  fi
  die "Missing node/nodejs. Install Node.js, then rerun this script."
}

install_desktop_launcher() {
  desktop_dir="$HOME/.local/share/applications"
  icon_dir="$HOME/.local/share/icons/hicolor"
  desktop_file="$desktop_dir/$APP_ID.desktop"
  icon_256="$ROOT/flatpak-sources/icon-256.png"
  icon_512="$ROOT/flatpak-sources/icon-512.png"

  mkdir -p "$desktop_dir" "$icon_dir/256x256/apps" "$icon_dir/512x512/apps"

  if [ ! -s "$icon_256" ] || [ ! -s "$icon_512" ]; then
    info "Build sources are absent; copying icons from the installed Flatpak"
    icon_256="$desktop_dir/$APP_ID-icon-256.png"
    icon_512="$desktop_dir/$APP_ID-icon-512.png"
    flatpak run --user --command=sh "$APP_ID" -lc \
      'cat /app/share/icons/hicolor/256x256/apps/com.openai.CodexLinuxX64.png' >"$icon_256"
    flatpak run --user --command=sh "$APP_ID" -lc \
      'cat /app/share/icons/hicolor/512x512/apps/com.openai.CodexLinuxX64.png' >"$icon_512"
  fi
  [ -s "$icon_256" ] || die "Could not find the 256px Codex icon"
  [ -s "$icon_512" ] || die "Could not find the 512px Codex icon"
  install -m 644 "$icon_256" "$icon_dir/256x256/apps/$APP_ID.png"
  install -m 644 "$icon_512" "$icon_dir/512x512/apps/$APP_ID.png"

  cat >"$desktop_file" <<EOF
[Desktop Entry]
Name=Codex Linux x86_64
Comment=Unofficial local Flatpak build of the Codex desktop app
Exec=flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu com.openai.CodexLinuxX64 %U
Icon=$APP_ID
Type=Application
Categories=Development;
MimeType=x-scheme-handler/codex;
StartupWMClass=codex
X-Flatpak=$APP_ID
EOF
  chmod 755 "$desktop_file"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -f "$icon_dir" >/dev/null 2>&1 || true
  fi

  info "Installed desktop launcher: $desktop_file"
}

disable_legacy_focus_helper() {
  legacy_unit="codex-x11-focus-helper.service"
  legacy_unit_file="$HOME/.config/systemd/user/$legacy_unit"
  detected=0

  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  systemctl --user daemon-reload || warn "systemctl --user daemon-reload failed while checking legacy focus helper"

  if [ -f "$legacy_unit_file" ] ||
    systemctl --user list-unit-files --no-legend "$legacy_unit" 2>/dev/null | grep -Fq "$legacy_unit" ||
    systemctl --user is-active --quiet "$legacy_unit"; then
    detected=1
  fi

  if [ "$detected" -eq 0 ]; then
    return
  fi

  if systemctl --user disable --now "$legacy_unit"; then
    info "Disabled legacy Codex X11 focus helper: $legacy_unit"
  else
    warn "Could not disable legacy Codex X11 focus helper: $legacy_unit"
  fi
  systemctl --user daemon-reload || warn "systemctl --user daemon-reload failed after disabling legacy focus helper"
}

install_window_patch_automation() {
  node_bin=$1

  mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
  cat >"$HOME/.local/bin/codex-desktop-window-patch" <<EOF
#!/bin/sh
set -eu

APP_ID="$APP_ID"
PATCH_ROOT="$ROOT"
NODE_BIN="$node_bin"
LOG_DIR="\${XDG_STATE_HOME:-\$HOME/.local/state}/codex-desktop"
LOG_FILE="\$LOG_DIR/window-patch.log"

mkdir -p "\$LOG_DIR"
{
  printf '\\n[%s] codex-desktop-window-patch\\n' "\$(date -Is)"
  if ! command -v flatpak >/dev/null 2>&1; then
    echo "flatpak not found; skipping"
    exit 0
  fi
  if ! flatpak info --user "\$APP_ID" >/dev/null 2>&1; then
    echo "\$APP_ID is not installed for this user; skipping"
    exit 0
  fi
  cd "\$PATCH_ROOT"
  "\$NODE_BIN" "\$PATCH_ROOT/scripts/patch-codex-linux-titlebar.cjs" apply
  "\$NODE_BIN" "\$PATCH_ROOT/scripts/patch-codex-linux-titlebar.cjs" status
} >>"\$LOG_FILE" 2>&1
EOF
  chmod 755 "$HOME/.local/bin/codex-desktop-window-patch"

  cat >"$HOME/.config/systemd/user/codex-desktop-window-patch.service" <<'EOF'
[Unit]
Description=Ensure Codex Desktop X11 window patch is applied
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/codex-desktop-window-patch
EOF

  cat >"$HOME/.config/systemd/user/codex-desktop-window-patch.path" <<EOF
[Unit]
Description=Watch Codex Desktop Flatpak deployment for window patch reapply

[Path]
PathModified=%h/.local/share/flatpak/app/com.openai.CodexLinuxX64/x86_64/master
Unit=codex-desktop-window-patch.service

[Install]
WantedBy=paths.target
EOF

  cat >"$HOME/.config/systemd/user/codex-desktop-window-patch.timer" <<'EOF'
[Unit]
Description=Periodically ensure Codex Desktop X11 window patch is applied

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable; installed window patch files but did not enable automation."
    return
  fi

  systemctl --user daemon-reload || warn "systemctl --user daemon-reload failed"
  systemctl --user enable --now codex-desktop-window-patch.path codex-desktop-window-patch.timer ||
    warn "Could not enable Codex window patch automation"
}

main() {
  detect_language
  print_notice
  require_cmd flatpak

  node_bin="$(find_node)"

  flatpak info --user "$APP_ID" >/dev/null 2>&1 ||
    die "$APP_ID is not installed. Run flatpak-builder --user --install first."

  info "Applying X11 window management patch"
  "$node_bin" "$ROOT/scripts/patch-codex-linux-titlebar.cjs" apply
  "$node_bin" "$ROOT/scripts/patch-codex-linux-titlebar.cjs" status

  install_desktop_launcher
  disable_legacy_focus_helper
  install_window_patch_automation "$node_bin"

  if [ "${CODEX_INTEGRATION_SKIP_RESTART:-0}" = "1" ]; then
    info "Done. Existing Codex instance was left running because CODEX_INTEGRATION_SKIP_RESTART=1."
  else
    flatpak --user kill "$APP_ID" >/dev/null 2>&1 || true
    info "Done. Start Codex from the desktop launcher or run: flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu $APP_ID"
  fi
}

main "$@"
