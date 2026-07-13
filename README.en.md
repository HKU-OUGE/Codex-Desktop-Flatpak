# Codex Desktop for Linux (Flatpak)

[中文](README.md) | [English](README.en.md)

This project packages Codex Desktop, the Linux CLI, and related runtime files as a Flatpak for Ubuntu x86_64.

It is not an official OpenAI Linux package. It is a community packaging project that provides installation, manual upgrade, rollback, and local management tools.

Application ID: `com.openai.CodexLinuxX64`

## Quick install

On the Ubuntu host, install the build dependencies:

```bash
sudo apt update
sudo apt install git flatpak flatpak-builder p7zip-full curl file nodejs npm \
  python3 python3-pil unzip tar
```

Clone or extract the repository anywhere, then enter the repository root—the directory that contains `install.sh`. If the files do not have execute permission, run this bootstrap step first; it does not depend on script permissions:

```bash
chmod +x install.sh
find . -maxdepth 2 -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.py' -o -name '*.cjs' \) -exec chmod +x {} +
./install.sh
```

Once started, the installer also repairs execute permissions for the repository's main scripts, manager, tests, and helper scripts. You do not need to repeat the manual permission step on later runs.

Only the `apt` dependency commands above require `sudo`. Do not run `sudo ./install.sh` or `sudo sh install.sh`: the installer creates a per-user Flatpak and build cache. If the installer has already been run with `sudo`, repair the repository ownership once and rerun it as the normal desktop user:

```bash
sudo chown -R "$USER":"$(id -gn)" .
sh install.sh
```

If root-owned or non-writable files are detected, the installer prints complete recovery commands for the current repository path. The builder extracts into a user-owned workspace, uses its own user-level npm cache, and invokes the asar CLI through `node`. It therefore does not depend on a possibly sudo-contaminated `~/.npm` directory or executable bits for an npm command shim.

`install.sh` will:

- download and build the current official version from public sources;
- install the Flatpak, desktop entry, icon, and window integration;
- install the optional terminal manager;
- install the Flathub SDK 24.08 if it is missing;
- disable and remove legacy automatic-upgrade timers;
- ask for the desired file-access level on the first installation.

The scripts detect the system language and show Chinese or English explanations. You can override the choice explicitly:

```bash
CODEX_LANG=zh ./install.sh
CODEX_LANG=en ./install.sh
```

When a China timezone such as `Asia/Shanghai`, `Asia/Macao`, or `Asia/Urumqi` is detected, missing Flatpak SDKs prefer the USTC Flathub mirror. Codex Desktop uses the current official URL; CLI and Electron inputs remain on official URLs with checksum verification. See the [USTC Flathub help](https://mirrors.ustc.edu.cn/help/flathub.html) for the mirror configuration. To disable automatic mirror selection, use `CODEX_MIRROR_MODE=never ./install.sh`; you can also set `CODEX_FLATHUB_REMOTE_URL` to your own Flathub mirror.

The installer can be executed from Bash, Zsh, Dash, and other POSIX-compatible shells. Do not run it with `source install.sh`.

Launch the application with:

```bash
flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu com.openai.CodexLinuxX64
```

You can also launch “Codex Linux x86_64” from the application menu.

After installation, you can also click the “Codex Linux x86_64” desktop icon in the application menu. You do not need to launch it from a terminal every time.

> Each build fetches the current official Codex Desktop and the latest stable Codex CLI by default. Because the official Desktop DMG URL is mutable, Desktop does not use a fixed SHA256; CLI and Electron downloads remain checksum-verified. The exact versions are recorded in `flatpak-sources/build-info.json`.

## Choose file permissions during installation

On the first run, `install.sh` asks how much of the host filesystem Codex may access:

- no extra filesystem access: keep the application's default Documents entry;
- Home directory: read/write access to the current user's Home directory;
- all files: read-only access to the host filesystem;
- Host permission: read/write access to the host filesystem; highest risk.

When `./install.sh` is run again and Codex is already installed, it detects the existing installation and offers two choices: rebuild and reinstall Desktop, or skip the installation and update only file permissions. You can also use explicit commands:

The script reads the current Flatpak `filesystems` configuration and marks the detected permission type with “← current” in the menu. Pressing Enter uses that type. An unrecognized combination is reported and falls back to no extra filesystem access.

```bash
./install.sh --permissions-only --permission=home
./install.sh --reinstall --permission=none
```

Permission modes are `none`, `home`, `all`, `host`, and `keep`. `--manager-only` does not change Desktop permissions.

## Management panel

The web service is not started by default. Enable it with:

```bash
./install.sh --enable
```

The script prints a loopback URL and access token. The service listens only on `127.0.0.1`.

To run the web panel temporarily without enabling a background service:

```bash
codex-flatpak-manager serve --open
```

Common terminal commands:

```bash
codex-flatpak-manager status
codex-flatpak-manager panel
codex-flatpak-manager permissions list
codex-flatpak-manager profile list
```

`panel` is an interactive text interface:

- `↑/↓` or `j/k`: move the selection;
- `Enter`: enter a category or run an action;
- `←`, `Backspace`, or `h`: go back;
- `→` or `l`: enter the next level;
- `r`: refresh;
- `q`: quit.

For non-interactive terminals, print a one-time tree view:

```bash
codex-flatpak-manager panel --plain
```

Install only the manager without reinstalling Desktop:

```bash
./install.sh --manager-only
```

## Upgrade and rollback

Automatic upgrades are disabled. Different Codex versions may require different build, patch, and acceptance procedures, so upgrades must be performed manually after reviewing the version-specific flow.

Manual upgrade entry point:

```bash
./upgrade-codex-desktop-flatpak.sh
```

Build and install without restarting the current Codex instance:

```bash
./upgrade-codex-desktop-flatpak.sh --no-restart
```

Reapply desktop integration and window fixes without rebuilding:

```bash
./upgrade-codex-desktop-flatpak.sh --no-build --no-restart
```

`install.sh` disables and removes the legacy `codex-flatpak-manager-auto-upgrade.timer`. `--enable-auto` remains only as a compatibility option and does not enable automatic updates.

Check the installed version and commit:

```bash
flatpak info --user --show-commit com.openai.CodexLinuxX64
flatpak run --user --command=sh com.openai.CodexLinuxX64 -lc \
  '/app/lib/codex/resources/codex --version'
```

Rollback to a known commit:

```bash
flatpak update --user -y --commit=<old-commit> com.openai.CodexLinuxX64
```

Upgrade logs are written to `upgrade-logs/` by default.

## File permissions

Flatpak does not access the entire host filesystem by default. Grant only the project directory that Codex needs:

```bash
mkdir -p "$HOME/codex-flatpak-workspace"
flatpak --user override \
  --filesystem="$HOME/codex-flatpak-workspace:create" \
  com.openai.CodexLinuxX64
```

For example, grant access to `~/Documents`:

```bash
flatpak --user override \
  --filesystem="$HOME/Documents:create" \
  com.openai.CodexLinuxX64
```

Show current permissions:

```bash
flatpak --user override --show com.openai.CodexLinuxX64
```

Reset manual overrides:

```bash
flatpak --user override --reset com.openai.CodexLinuxX64
```

Flatseal can also be used to manage permissions graphically. Restart Codex after changing permissions.

## Window and focus issues

The installer applies an X11 window fix for dragging, focusing, and normal desktop window management.

Older installations may contain `codex-x11-focus-helper.service`. The installer detects and disables it, and never creates it again, so Codex does not take input focus from other windows.

Check the patch status:

```bash
node scripts/patch-codex-linux-titlebar.cjs status
```

The expected output includes:

```text
state=patched
integrityOk=true
```

Reapply the integration if needed:

```bash
./install-codex-desktop-integration.sh
```

## Multiple profiles

The manager provides separate data directories for experimental multi-profile use:

```bash
codex-flatpak-manager profile create work
codex-flatpak-manager profile launch work
```

Profiles use separate configuration, data, and cache directories. Flatpak permissions remain application-wide; they are not isolated per profile.

## Build from source

To fetch the pinned Desktop, CLI, and Electron inputs from their public sources:

```bash
./build-x86_64-flatpak.sh
```

The script displays download, extraction, and dependency-build progress. It will:

- obtain the Codex Desktop application resources;
- obtain the Linux CLI and Code Mode Host from the matching Codex CLI release;
- verify checksums, Linux ELF architecture, and executable permissions;
- rebuild native modules for the bundled Electron version;
- build and install the user Flatpak.

Build metadata is written to the locally generated `flatpak-sources/build-info.json`. See the [user guide](Codex_Desktop_Flatpak_User_Guide.md) for validation, rollback, and troubleshooting commands.

## Data location

Codex Flatpak data is usually stored under:

```text
$HOME/.var/app/com.openai.CodexLinuxX64/
```

This directory may contain login state, configuration, caches, and logs. Do not include it when sharing the repository or a build package.

## Directory overview

- `install.sh`: download and install the current official Desktop version and manager;
- `upgrade-codex-desktop-flatpak.sh`: manual upgrade entry point;
- `build-x86_64-flatpak.sh`: rebuild from public sources;
- `install-codex-desktop-integration.sh`: install the desktop entry and window fix;
- `manager/`: terminal manager and local web panel;
- `packaging/`: launcher and desktop-entry source files copied into the Flatpak;
- `flatpak-sources/`: generated build inputs, ignored by Git;
- `tests/`: script and manager tests.
