#!/usr/bin/env bash
set -euo pipefail

APP_ID="com.openai.CodexLinuxX64"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${CODEX_UPGRADE_LOG_DIR:-$ROOT/upgrade-logs/$(date +%Y%m%d-%H%M%S)}"
RESTART=1
BUILD=1
ORIGINAL_ARGS=("$@")
CODEX_LANG="${CODEX_LANG:-auto}"
CODEX_MIRROR_MODE="${CODEX_MIRROR_MODE:-auto}"
CODEX_USE_MIRROR=0

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

detect_language() {
  case "$CODEX_LANG" in
    zh|zh_*) CODEX_LANG="zh" ;;
    en|en_*) CODEX_LANG="en" ;;
    auto|"")
      local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
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

is_china_timezone() {
  local timezone="${TZ:-}"
  if [ -z "$timezone" ] && command -v timedatectl >/dev/null 2>&1; then
    timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [ -z "$timezone" ] && [ -e /etc/localtime ] && command -v readlink >/dev/null 2>&1; then
    timezone="$(readlink -f /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')"
  fi
  if [ -z "$timezone" ] && [ -r /etc/timezone ]; then
    timezone="$(sed -n '1p' /etc/timezone)"
  fi
  case "$timezone" in
    Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Kashgar|Asia/Macao|Asia/Urumqi|Asia/Hong_Kong|Hongkong|PRC)
      return 0 ;;
  esac
  return 1
}

configure_source_policy() {
  case "$CODEX_MIRROR_MODE" in
    auto|always|never) ;;
    *)
      warn "Unsupported CODEX_MIRROR_MODE=$CODEX_MIRROR_MODE; using auto."
      CODEX_MIRROR_MODE="auto"
      ;;
  esac
  CODEX_USE_MIRROR=0
  if [ "$CODEX_MIRROR_MODE" = "always" ] ||
    { [ "$CODEX_MIRROR_MODE" = "auto" ] && is_china_timezone; }; then
    CODEX_USE_MIRROR=1
  fi
}

print_notice() {
  if [ "$CODEX_LANG" = "zh" ]; then
    cat <<'NOTICE'
=== Codex Desktop Flatpak 手动升级程序 ===
说明：根据系统语言显示提示；本程序按当前版本流程下载、构建、安装并验收 Codex Desktop。
免责声明：本项目不是 OpenAI 官方 Linux 安装包；请先确认本版本流程和来源，并自行承担升级、回滚及运行风险。
NOTICE
  else
    cat <<'NOTICE'
=== Codex Desktop Flatpak manual upgrade ===
Notice: Messages follow the system language. This script downloads, builds, installs, and verifies Codex Desktop using the current version-specific flow.
Disclaimer: This is not an official OpenAI Linux package. Confirm the flow and sources before use; upgrades, rollbacks, and runtime use are at your own risk.
NOTICE
  fi
  if [ "$CODEX_USE_MIRROR" = "1" ]; then
    if [ "$CODEX_LANG" = "zh" ]; then
      info "检测到中国时区：缺少 SDK 时优先使用 USTC Flathub 镜像；Codex 资源仍使用官方地址并校验摘要。"
    else
      info "China timezone detected: missing SDKs will prefer the USTC Flathub mirror; Codex assets stay on official URLs with checksum verification."
    fi
  fi
}

configure_flathub_remote() {
  local mirror_url="${CODEX_FLATHUB_REMOTE_URL:-https://mirrors.ustc.edu.cn/flathub}"
  flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  if [ "$CODEX_USE_MIRROR" = "1" ]; then
    if flatpak --user remote-modify flathub --url="$mirror_url"; then
      info "Configured Flathub mirror: $mirror_url"
    else
      warn "Could not configure the Flathub mirror; using the official Flathub URL."
      flatpak --user remote-modify flathub --url="https://dl.flathub.org/repo/"
    fi
  fi
}

usage() {
  cat <<EOF
Usage: ./upgrade-codex-desktop-flatpak.sh [--no-restart] [--no-build]

Builds and installs the Codex Desktop Flatpak for the current user, applies
desktop integration, verifies the Linux CLI/helper, and restarts the app with
rollback protection when possible.

Options:
  --no-restart   Build/install/verify only. Leave the current GUI instance running.
  --no-build     Skip build-x86_64-flatpak.sh and only apply integration/checks.
  -h, --help     Show this help.

Environment:
  CODEX_APP_DMG=/path/to/Codex.dmg
  CODEX_RELEASE_JSON=/path/to/github-release-latest.json
  CODEX_FORCE_DOWNLOAD=1
  CODEX_UPGRADE_LOG_DIR=/path/to/log-dir
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART=0 ;;
    --no-build) BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

if [ -n "${FLATPAK_ID:-}" ] && [ "${CODEX_UPGRADE_ON_HOST:-0}" != "1" ]; then
  command -v flatpak-spawn >/dev/null 2>&1 ||
    die "Running inside Flatpak but flatpak-spawn is unavailable."
  info "Running inside Flatpak; re-executing on the host."
  exec flatpak-spawn --host env CODEX_UPGRADE_ON_HOST=1 \
    CODEX_LANG="$CODEX_LANG" \
    CODEX_MIRROR_MODE="$CODEX_MIRROR_MODE" \
    CODEX_FLATHUB_REMOTE_URL="${CODEX_FLATHUB_REMOTE_URL:-}" \
    "$ROOT/upgrade-codex-desktop-flatpak.sh" "${ORIGINAL_ARGS[@]}"
fi

require_cmd() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing required command: $cmd"
      missing=1
    fi
  done
  [ "$missing" = 0 ] || die "Install the missing commands, then rerun this script."
}

host_install_commit() {
  flatpak info --user --show-commit "$APP_ID" 2>/dev/null || true
}

running_instances() {
  flatpak ps --columns=instance,pid,child-pid,application,commit 2>/dev/null |
    awk -v app="$APP_ID" '$4 == app { print }'
}

verify_installed_payload() {
  local log="$LOG_DIR/verify-installed.log"
  info "Verifying installed Flatpak payload"
  flatpak run --user --command=sh "$APP_ID" -lc '
set -eu
for file in /app/lib/codex/resources/codex /app/lib/codex/resources/codex-code-mode-host; do
  test -x "$file"
  file "$file" | grep -q "ELF 64-bit.*x86-64"
  sha256sum "$file"
done
/app/lib/codex/resources/codex --version
' >"$log" 2>&1
  sed -n '1,120p' "$log"

  local permissions
  permissions="$(flatpak info --user --show-permissions "$APP_ID")"
  grep -Fq 'org.freedesktop.Flatpak=talk' <<<"$permissions" ||
    die "Flatpak permission org.freedesktop.Flatpak=talk is missing."
}

write_gui_env() {
  local env_file="$1"
  : >"$env_file"
  for name in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XAUTHORITY; do
    local value="${!name-}"
    [ -n "$value" ] || continue
    printf '%s=%q\n' "$name" "$value" >>"$env_file"
  done
}

write_restart_script() {
  local script="$1"
  local env_file="$2"
  local old_commit="$3"
  local new_commit="$4"
  local restart_log="$5"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -u

APP_ID="$APP_ID"
OLD_COMMIT="$old_commit"
NEW_COMMIT="$new_commit"
ENV_FILE="$env_file"
LOG_FILE="$restart_log"

mkdir -p "\$(dirname "\$LOG_FILE")"
exec >>"\$LOG_FILE" 2>&1

log() { printf '[%s] %s\n' "\$(date -Is)" "\$*"; }

if [ -f "\$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "\$ENV_FILE"
fi
export DISPLAY="\${DISPLAY:-}"
export WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-}"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-}"
export XAUTHORITY="\${XAUTHORITY:-}"

app_ps() {
  flatpak ps --columns=instance,pid,application,commit 2>/dev/null | awk -v app="\$APP_ID" '\$3 == app { print }'
}

wait_commit() {
  local expected="\$1"
  local short="\${expected:0:12}"
  local stable=0
  local i lines count commits
  for i in \$(seq 1 90); do
    lines="\$(app_ps)"
    count="\$(printf '%s\n' "\$lines" | sed '/^$/d' | wc -l)"
    commits="\$(printf '%s\n' "\$lines" | awk '{print \$4}' | sort -u | tr '\n' ' ')"
    log "poll=\$i count=\$count commits=\$commits"
    if [ "\$count" = "1" ] && printf '%s\n' "\$commits" | grep -q "\$short"; then
      stable=\$((stable + 1))
      [ "\$stable" -ge 5 ] && return 0
    else
      stable=0
    fi
    sleep 1
  done
  return 1
}

start_app() {
  local unit="\$1"
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --unit="\$unit" --collect \\
      --setenv=DISPLAY="\${DISPLAY:-}" \\
      --setenv=WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-}" \\
      --setenv=XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-}" \\
      --setenv=DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-}" \\
      --setenv=XAUTHORITY="\${XAUTHORITY:-}" \\
      flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu "\$APP_ID"
  else
    nohup setsid flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu "\$APP_ID" >/dev/null 2>&1 &
  fi
}

rollback() {
  if [ -z "\$OLD_COMMIT" ]; then
    log "ROLLBACK_SKIPPED no_old_commit"
    return 1
  fi
  log "ROLLBACK_START old_commit=\$OLD_COMMIT"
  flatpak kill "\$APP_ID" >/dev/null 2>&1 || true
  sleep 2
  flatpak update --user -y --commit="\$OLD_COMMIT" "\$APP_ID" || return 1
  start_app "codex-desktop-flatpak-rollback"
  wait_commit "\$OLD_COMMIT" && log "ROLLBACK_STATUS=running_old_commit"
}

log "RESTART_BEGIN new=\$NEW_COMMIT old=\$OLD_COMMIT"
sleep 3
flatpak kill "\$APP_ID" >/dev/null 2>&1 || true
sleep 2
start_app "codex-desktop-flatpak-restart"
if wait_commit "\$NEW_COMMIT"; then
  log "RESTART_STATUS=running_expected_commit"
  exit 0
fi
log "EXPECTED_COMMIT_NOT_STABLE"
rollback || true
exit 1
EOF
  chmod 755 "$script"
}

main() {
  detect_language
  configure_source_policy
  print_notice
  mkdir -p "$LOG_DIR"
  require_cmd flatpak flatpak-builder file node npm python3 sha256sum

  if ! flatpak info --user org.freedesktop.Sdk//24.08 >/dev/null 2>&1; then
    configure_flathub_remote
    flatpak --user install -y flathub org.freedesktop.Sdk//24.08
  fi

  local old_commit new_commit
  old_commit="$(host_install_commit)"
  info "Old installed commit: ${old_commit:-not installed}"
  if [ -n "$(running_instances)" ]; then
    info "Running instances before upgrade:"
    running_instances
  fi

  if [ "$BUILD" = "1" ]; then
    info "Building and installing Flatpak"
    "$ROOT/build-x86_64-flatpak.sh" 2>&1 | tee "$LOG_DIR/build.log"
  else
    info "Skipping build because --no-build was requested"
  fi

  new_commit="$(host_install_commit)"
  [ -n "$new_commit" ] || die "$APP_ID is not installed after build."
  ok "Installed commit: $new_commit"

  info "Applying desktop integration without stopping the current instance"
  CODEX_INTEGRATION_SKIP_RESTART=1 "$ROOT/install-codex-desktop-integration.sh" 2>&1 |
    tee "$LOG_DIR/integration.log"

  verify_installed_payload
  ok "Static installed-payload checks passed"

  if [ "$RESTART" = "0" ]; then
    info "Skipping restart because --no-restart was requested."
    info "Start later with: flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu $APP_ID"
    return
  fi

  local env_file="$LOG_DIR/restart.env"
  local restart_script="$LOG_DIR/restart-with-rollback.sh"
  local restart_log="$LOG_DIR/restart.log"
  write_gui_env "$env_file"
  write_restart_script "$restart_script" "$env_file" "$old_commit" "$new_commit" "$restart_log"

  info "Starting detached restart with rollback protection"
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --unit="codex-flatpak-upgrade-$(date +%H%M%S)" --collect "$restart_script" |
      tee "$LOG_DIR/restart-launch.log"
  else
    nohup setsid "$restart_script" >/dev/null 2>&1 &
    echo "Started restart script with nohup; log: $restart_log" | tee "$LOG_DIR/restart-launch.log"
  fi

  info "Restart log: $restart_log"
}

main "$@"
