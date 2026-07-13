#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

sh -n "$ROOT/install.sh"
bash -n "$ROOT/install.sh"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$ROOT/install.sh"
fi
python3 -m py_compile "$ROOT/manager/codex_flatpak_manager.py"
python3 -m unittest discover -s "$ROOT/manager" -p 'test*.py'
python3 "$ROOT/manager/codex_flatpak_manager.py" --help | grep -Fq 'panel'
grep -Fq 'Do not run this installer with sudo or as root' "$ROOT/install.sh"
grep -Fq 'sudo chown -R %s:%s' "$ROOT/install.sh"
grep -Fq 'check_workspace_permissions' "$ROOT/install.sh"
grep -Fq 'bash "$ROOT/build-x86_64-flatpak.sh"' "$ROOT/install.sh"
grep -Fq 'CODEX_INTEGRATION_SKIP_RESTART=1 sh "$ROOT/install-codex-desktop-integration.sh"' "$ROOT/install.sh"

TEMP_HOME=$(mktemp -d)
trap 'rm -rf "$TEMP_HOME"' EXIT
env -u FLATPAK_ID HOME="$TEMP_HOME" \
XDG_CONFIG_HOME="$TEMP_HOME/config" \
CODEX_MANAGER_INSTALL_DIR="$TEMP_HOME/share/codex-flatpak-manager" \
CODEX_MANAGER_BIN_DIR="$TEMP_HOME/bin" \
sh "$ROOT/install.sh" --manager-only

test -x "$TEMP_HOME/bin/codex-flatpak-manager"
test -f "$TEMP_HOME/share/codex-flatpak-manager/codex_flatpak_manager.py"
grep -Fq "$ROOT" "$TEMP_HOME/config/codex-flatpak-manager/repo"
grep -Fq "$TEMP_HOME/share/codex-flatpak-manager/codex_flatpak_manager.py" \
  "$TEMP_HOME/config/systemd/user/codex-flatpak-manager.service"
test ! -e "$TEMP_HOME/config/systemd/user/codex-flatpak-manager-auto-upgrade.service"
test ! -e "$TEMP_HOME/config/systemd/user/codex-flatpak-manager-auto-upgrade.timer"

echo "manager install checks passed"
