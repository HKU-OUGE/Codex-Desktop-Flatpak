#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install-codex-desktop-integration.sh"
UPGRADER="$ROOT/upgrade-codex-desktop-flatpak.sh"
MAIN_README="$ROOT/README.md"
README="$ROOT/Codex_Desktop_Flatpak_使用说明.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$INSTALLER" ]] || fail "missing install-codex-desktop-integration.sh"
bash -n "$INSTALLER"
[[ -f "$UPGRADER" ]] || fail "missing upgrade-codex-desktop-flatpak.sh"
bash -n "$UPGRADER"

grep -Fq 'patch-codex-linux-titlebar.cjs" apply' "$INSTALLER" ||
  fail "installer must apply the ASAR titlebar/window patch"
grep -Fq 'patch-codex-linux-titlebar.cjs" status' "$INSTALLER" ||
  fail "installer must print patch status"
grep -Fq 'Exec=flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu com.openai.CodexLinuxX64 %U' "$INSTALLER" ||
  fail "installer must create a direct Flatpak desktop launcher"
grep -Fq 'StartupWMClass=codex' "$INSTALLER" ||
  fail "installer must set the observed StartupWMClass"
grep -Fq 'icon-512.png' "$INSTALLER" ||
  fail "installer must install the app icon"
grep -Fq 'local legacy_unit="codex-x11-focus-helper.service"' "$INSTALLER" ||
  fail "installer must detect the legacy X11 focus helper service"
grep -Fq 'systemctl --user disable --now "$legacy_unit"' "$INSTALLER" ||
  fail "installer must disable the legacy X11 focus helper service"
grep -Fq 'systemctl --user is-active --quiet "$legacy_unit"' "$INSTALLER" ||
  fail "installer must detect an active legacy X11 focus helper"
! grep -Fq 'systemctl --user enable --now codex-x11-focus-helper.service' "$INSTALLER" ||
  fail "installer must not enable the legacy X11 focus helper"
! grep -Fq 'install_focus_helper' "$INSTALLER" ||
  fail "installer must not retain the focus helper installation function"
! grep -Fq 'ExecStart=%h/.local/bin/codex-x11-focus-helper' "$INSTALLER" ||
  fail "installer must not create the legacy focus helper service"
grep -Fq 'ExecStart=%h/.local/bin/codex-desktop-window-patch' "$INSTALLER" ||
  fail "window patch service must use systemd %h, not literal HOME"
grep -Fq 'PathModified=%h/.local/share/flatpak/app/com.openai.CodexLinuxX64/x86_64/master' "$INSTALLER" ||
  fail "path unit must watch the user Flatpak deployment"
grep -Fq 'CODEX_INTEGRATION_SKIP_RESTART' "$INSTALLER" ||
  fail "installer must support applying integration without killing the running app"

grep -Fq 'build-x86_64-flatpak.sh' "$UPGRADER" ||
  fail "upgrader must call the build script"
grep -Fq 'CODEX_INTEGRATION_SKIP_RESTART=1' "$UPGRADER" ||
  fail "upgrader must apply integration before restart"
grep -Fq 'verify_installed_payload' "$UPGRADER" ||
  fail "upgrader must verify installed CLI/helper payload"
grep -Fq 'codex-code-mode-host' "$UPGRADER" ||
  fail "upgrader must verify the code mode host"
grep -Fq 'ROLLBACK_STATUS=running_old_commit' "$UPGRADER" ||
  fail "upgrader must include rollback status logging"
grep -Fq 'flatpak-spawn --host env CODEX_UPGRADE_ON_HOST=1' "$UPGRADER" ||
  fail "upgrader must re-exec on the host when launched from inside Flatpak"

! grep -Eq '/home/[A-Za-z0-9._-]+' "$INSTALLER" || fail "installer must not contain local personal paths"
! grep -Fq 'ExecStart=$HOME' "$INSTALLER" || fail "systemd units must not use unexpanded HOME"

grep -Fq './upgrade-codex-desktop-flatpak.sh' "$MAIN_README" ||
  fail "README must document the one-command upgrader"
grep -Fq -- '--no-restart' "$MAIN_README" ||
  fail "README must document non-restarting upgrade mode"
grep -Fq './install-codex-desktop-integration.sh' "$README" ||
  fail "README must instruct users to run the integration installer"
grep -Fq './upgrade-codex-desktop-flatpak.sh' "$README" ||
  fail "legacy Chinese README must document the one-command upgrader"
grep -Fq '无法拖动' "$README" ||
  fail "README must document the window dragging fix"

echo "desktop integration packaging checks passed"
