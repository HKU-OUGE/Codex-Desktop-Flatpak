# Codex Desktop Flatpak User Guide

[中文](Codex_Desktop_Flatpak_使用说明.md) | [English](Codex_Desktop_Flatpak_User_Guide.md)

This guide covers the Linux x86_64 Flatpak build of Codex Desktop in this repository. It is a reproducible and inspectable community package with application ID `com.openai.CodexLinuxX64`.

## Recommended one-command upgrade

Run the upgrade entry point from the repository root. It downloads the pinned public sources, builds and installs the Flatpak, applies desktop integration, performs basic checks, and uses rollback protection when restarting the application:

Enter the repository root—the directory that contains `install.sh`—after cloning or extracting the repository, then run:

```bash
chmod +x install.sh build-x86_64-flatpak.sh upgrade-codex-desktop-flatpak.sh \
  install-codex-desktop-integration.sh
./upgrade-codex-desktop-flatpak.sh
```

When run inside the Codex Desktop Flatpak, the script automatically switches to the host through `flatpak-spawn --host`.

Build and install without restarting the current GUI:

```bash
./upgrade-codex-desktop-flatpak.sh --no-restart
```

Reapply integration and verify the installed version without rebuilding:

```bash
./upgrade-codex-desktop-flatpak.sh --no-build --no-restart
```

See the [English README](README.en.md) or [中文 README](README.md) for the security boundary and basic commands.

## Optional manager and local web panel

The manager does not replace the existing manual workflow; it calls the same upgrade script. `install.sh` downloads and builds the pinned Desktop version, installs the manager, and does not start the web service unless requested:

```bash
./install.sh
codex-flatpak-manager status
codex-flatpak-manager panel
codex-flatpak-manager upgrade --no-restart
codex-flatpak-manager permissions list
codex-flatpak-manager profile create work
codex-flatpak-manager profile launch work
```

Start the loopback-only web panel with:

```bash
./install.sh --enable
# install.sh prints a local URL containing the access token
```

Or run it temporarily without enabling a background service:

```bash
codex-flatpak-manager serve --open
```

Install only the manager:

```bash
./install.sh --manager-only
```

Automatic upgrades are disabled. Any legacy `codex-flatpak-manager-auto-upgrade.timer` is disabled and removed during installation. `--enable-auto` is retained only for compatibility and does not re-enable it.

The manager supports status checks, stable-version manual upgrades, rollback, user-level Flatpak permissions, and experimental profiles. The web service binds to `127.0.0.1`. Profile isolation depends on Electron's separate `XDG_*` directories, while Flatpak permissions remain application-wide.

`install.sh` is a POSIX `sh` script and can be called from Bash, Zsh, Dash, and other compatible shells. Do not run it with `source install.sh`. On another Ubuntu machine, `./install.sh` downloads and builds the pinned version instead of resolving GitHub `latest`.

`codex-flatpak-manager panel` is a linear, two-level text workflow. It initially shows only top-level categories; press `Enter` to enter a category and see its child actions. Use `↑/↓` or `j/k` to move, `←`/`Backspace`/`h` to go back, `→`/`l` to enter a child page, `Enter` to run an action, `r` to refresh, `u` for an upgrade without restart, `U` for an upgrade that may restart the app, and `q` to quit. Permission changes, profile actions, and commit rollback prompt for input in their child pages. Use `codex-flatpak-manager panel --plain` for a one-time tree snapshot when no interactive terminal is available.

On the first installation, `install.sh` asks for a file-access level: no extra access, Home read/write, all files read-only, or full Host read/write. When an existing installation is detected, rerunning the script lets you choose between rebuilding Desktop and updating permissions only. Explicit examples:

The script reads the current Flatpak `filesystems` configuration and marks the detected type with “← current”. Press Enter to use that type. If the configuration contains an unrecognized combination, the script warns and falls back to no extra filesystem access; choose “keep original configuration” only when you intentionally want to retain it.

```bash
./install.sh --permissions-only --permission=home
./install.sh --reinstall --permission=none
```

## Repository contents

- `com.openai.CodexLinuxX64.yml`: Flatpak manifest;
- `packaging/`: launcher and desktop-entry source files copied into the Flatpak during the build;
- `build-x86_64-flatpak.sh`: fetch and build script;
- `upgrade-codex-desktop-flatpak.sh`: recommended upgrade entry point;
- `flatpak-sources/`: generated build inputs, ignored and not committed;
- `host-launcher/`: optional host-side window launch and drag helpers;
- `manager/`: optional host CLI and local web manager;
- `install.sh`: POSIX one-command installer for Desktop and the manager;
- `scripts/`: debugging and patch helpers;
- `README.md`, `README.en.md`, and the two user guides: documentation and usage references.

## Prerequisites

Install the build tools on the host:

```bash
sudo apt install flatpak flatpak-builder p7zip-full curl file nodejs npm python3 python3-pil unzip tar
```

Install the runtime:

```bash
flatpak --user install flathub org.freedesktop.Sdk//24.08
```

If Flathub is not configured:

```bash
flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

`install.sh` detects the system language and automatically shows Chinese or English explanations. Set `CODEX_LANG=zh` or `CODEX_LANG=en` to override it. When a China timezone such as `Asia/Shanghai`, `Asia/Macao`, or `Asia/Urumqi` is detected, missing Flatpak SDKs prefer the USTC Flathub mirror. Codex Desktop, CLI, and Electron downloads remain on official URLs with checksum verification. Use `CODEX_MIRROR_MODE=never` to disable automatic mirror selection, or set `CODEX_FLATHUB_REMOTE_URL` to a custom Flathub mirror. Reference: [USTC Flathub help](https://mirrors.ustc.edu.cn/help/flathub.html).

## Build and install from public sources

Run the installer from the repository root. It shows download progress, fetches the pinned Desktop, Codex CLI, and Electron inputs, and builds locally:

```bash
./install.sh
```

After installation, launch Codex by clicking the “Codex Linux x86_64” desktop icon in the application menu, or use the terminal command:

```bash
flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu com.openai.CodexLinuxX64
```

To build without installing the manager:

```bash
./build-x86_64-flatpak.sh
```

Then apply the desktop entry and X11 window fix if you built manually:

```bash
./install-codex-desktop-integration.sh
```

The integration script:

- patches the installed `app.asar` so X11 does not create an unmanaged `override_redirect` window;
- writes the desktop entry under `~/.local/share/applications/`;
- installs icons under `~/.local/share/icons/hicolor/`;
- installs user-level systemd path/timer integration when supported, so the window patch is reapplied after a Flatpak update;
- detects and disables the legacy `codex-x11-focus-helper.service` without creating a replacement focus service.

Launch after installation:

```bash
flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu com.openai.CodexLinuxX64
```

## Rebuild from official public sources

To download the pinned Codex Desktop, Codex CLI, and Electron inputs again:

```bash
./build-x86_64-flatpak.sh
```

The script displays download, extraction, and dependency-build progress and verifies SHA256 checksums for Codex Desktop, Codex CLI, and Electron. Build metadata is written to the locally generated `flatpak-sources/build-info.json`.

The current flow resolves the main CLI and Linux `codex-code-mode-host` from the same pinned Codex release metadata and rejects a missing helper, non-Linux ELF, non-executable file, or release-tag mismatch. Do not use the macOS helper from the DMG.

## Granting file access

Flatpak restricts host paths by default. The manifest provides a generic Documents entry; grant the project directory explicitly when Codex cannot see it.

Recommended: grant one workspace directory:

```bash
mkdir -p "$HOME/codex-flatpak-workspace"
flatpak --user override --filesystem="$HOME/codex-flatpak-workspace:create" com.openai.CodexLinuxX64
flatpak --user kill com.openai.CodexLinuxX64 2>/dev/null || true
flatpak run --user com.openai.CodexLinuxX64
```

Grant a project parent directory:

```bash
flatpak --user override --filesystem="$HOME/Documents:create" com.openai.CodexLinuxX64
```

Grant the whole home directory:

```bash
flatpak --user override --filesystem=home com.openai.CodexLinuxX64
```

Grant nearly the whole host filesystem (higher risk):

```bash
flatpak --user override --filesystem=host com.openai.CodexLinuxX64
```

Flatseal can be used instead. Select “Codex Linux x86_64” and add the required paths under Filesystem.

## Check permissions

Show the current overrides:

```bash
flatpak --user override --show com.openai.CodexLinuxX64
```

Check visible paths from inside the sandbox:

```bash
flatpak --user run --command=sh com.openai.CodexLinuxX64 -lc 'cat /.flatpak-info; ls -la "$HOME"'
```

Run override commands on the host. A shell opened by Codex may itself be inside the Flatpak sandbox and may not have the `flatpak` command.

## Troubleshooting

If the window cannot be dragged, check the patch status:

```bash
node scripts/patch-codex-linux-titlebar.cjs status
```

Expected output includes:

```text
state=patched
integrityOk=true
```

If the state is not `patched`:

```bash
node scripts/patch-codex-linux-titlebar.cjs apply
./install-codex-desktop-integration.sh
```

If the system command is `nodejs` rather than `node`:

```bash
nodejs scripts/patch-codex-linux-titlebar.cjs apply
```

If the application entry or icon is missing:

```bash
./install-codex-desktop-integration.sh
```

Then restart GNOME/the application launcher, or log in again.

If Codex reports an error similar to `/bin/sh: No such file or directory`, do not check only whether `/bin/sh` exists. The current working directory may not be visible inside the sandbox. Confirm that the host path exists and that Flatpak has access to it.

Reset all manual overrides:

```bash
flatpak --user override --reset com.openai.CodexLinuxX64
flatpak --user kill com.openai.CodexLinuxX64 2>/dev/null || true
```

To remove broad access only:

```bash
flatpak --user override --nofilesystem=host --nofilesystem=home com.openai.CodexLinuxX64
```

## Data location

Flatpak application data is usually stored at:

```bash
$HOME/.var/app/com.openai.CodexLinuxX64/
```

Do not include this directory when sharing a build package. It may contain user sessions, logs, configuration, and caches.
