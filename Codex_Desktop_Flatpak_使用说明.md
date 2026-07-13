# Codex Desktop Flatpak 使用说明

[中文](Codex_Desktop_Flatpak_使用说明.md) | [English](Codex_Desktop_Flatpak_User_Guide.md)

本文档适用于本包中的 Linux x86_64 Flatpak 形式 Codex Desktop。本包是本机整理出的可重建/可审计版本，应用 ID 为 `com.openai.CodexLinuxX64`。

## 推荐一键升级

优先使用仓库根目录的升级入口。它会自动完成官方下载、构建、安装、桌面集成、基础验收和带回滚保护的重启：

进入能看到 `install.sh` 的仓库根目录（也就是刚刚克隆或解压出的目录），再执行：

```bash
./upgrade-codex-desktop-flatpak.sh
```

如果这个命令是在 Codex Desktop Flatpak 内部执行，脚本会自动通过 `flatpak-spawn --host` 切到宿主机继续执行。

只构建和安装、不重启当前 GUI：

```bash
./upgrade-codex-desktop-flatpak.sh --no-restart
```

只重新应用桌面集成和检查已安装版本：

```bash
./upgrade-codex-desktop-flatpak.sh --no-build --no-restart
```

详细安全边界、验收命令和回滚命令见同目录 `README.md`。

## 可选管理器和本地网页面板

管理器不会替换原有手动链路，只是调用同一个升级脚本。`install.sh` 会下载并构建仓库锁定的当前 Codex Desktop，同时安装管理器，不会自动启动网页服务：

```bash
./install.sh
codex-flatpak-manager status
codex-flatpak-manager panel
codex-flatpak-manager upgrade --no-restart
codex-flatpak-manager permissions list
codex-flatpak-manager profile create work
codex-flatpak-manager profile launch work
```

需要启动仅监听本机回环地址的网页面板时：

```bash
./install.sh --enable
# install.sh 会打印带本地令牌的网页地址
```

或者不启用后台服务，临时运行网页面板：

```bash
codex-flatpak-manager serve --open
```

如果只需要管理器、不重新安装仓库内的 Desktop：

```bash
./install.sh --manager-only
```

自动升级已关闭。旧版本遗留的 `codex-flatpak-manager-auto-upgrade.timer` 会在安装时被停用并删除；`--enable-auto` 仅作为兼容参数保留，不会重新启用它。每个 Codex 版本请按对应的手动流程执行升级。

管理器支持状态查看、稳定版本升级、回滚、用户级 Flatpak 文件权限和实验性的 profile 多开。网页服务默认绑定 `127.0.0.1`，升级操作使用锁和现有日志/回滚链路。profile 多开依赖 Electron 对独立 `XDG_*` 数据目录的支持，当前标记为实验性；Flatpak 权限目前是应用级，不会伪装成每个 profile 独立隔离。

`install.sh` 是 POSIX shell 脚本，可以从 Bash、Zsh、Dash 等终端直接执行；不要使用 `source install.sh`。复制本目录到其他 Ubuntu 机器后，直接运行 `./install.sh` 会从公开地址下载并构建锁定版本，不会重新解析 GitHub latest。

`codex-flatpak-manager panel` 会打开线性工作流式的二级文字菜单，默认只显示上层节点；选择上层后按 `Enter` 进入下一级页面，此时只显示当前页面的子功能。使用 `↑/↓` 或 `j/k` 切换，`←`/`Backspace`/`h` 返回上级，`→`/`l` 进入下级，`Enter` 执行子功能，`r` 刷新，`u` 执行不重启升级，`U` 执行允许重启升级，`q` 退出。权限授权/撤销、Profile 创建/启动和 commit 回滚会在子菜单中要求输入。无法使用交互式终端时可用 `codex-flatpak-manager panel --plain` 输出一次性树形快照。

首次安装时，`install.sh` 会询问文件权限：无额外权限、Home 目录读写、所有文件只读，或 Host 全部文件读写。检测到已有安装后，再次运行脚本会让你选择重新构建 Desktop，或只更新权限而不重新安装。也可以直接执行：

```bash
./install.sh --permissions-only --permission=home
./install.sh --reinstall --permission=none
```

## 包内内容

- `com.openai.CodexLinuxX64.yml`：Flatpak manifest。
- `packaging/`：由构建脚本放入 Flatpak 的启动器和桌面入口源码。
- `build-x86_64-flatpak.sh`：从官方来源重新拉取并构建 Flatpak 的脚本。
- `upgrade-codex-desktop-flatpak.sh`：推荐升级入口。
- `flatpak-sources/`：构建过程中生成的 Electron、Codex app、Codex CLI、Code Mode Host 和图标等输入，不提交到仓库。
- `host-launcher/`：可选的宿主侧窗口启动/拖动脚本。
- `manager/`：可选的宿主机 CLI 和本地网页管理器。
- `install.sh`：用 POSIX `sh` 编写的 Codex Desktop 与管理器一键安装入口，可从 Bash、Zsh 等终端调用。
- `scripts/`：可选的调试/补丁辅助脚本。
- `Codex_Desktop_Flatpak_使用说明.md` 和 `REDACTION_MANIFEST.md`：使用说明与脱敏清单。

## 安装前提

在宿主机终端安装 Flatpak 相关工具：

```bash
sudo apt install flatpak flatpak-builder p7zip-full curl file nodejs npm python3 python3-pil unzip tar
```

安装运行时：

```bash
flatpak --user install flathub org.freedesktop.Sdk//24.08
```

如果系统没有配置 Flathub：

```bash
flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

## 从公开来源构建安装

在仓库根目录运行一键安装脚本。脚本会显示下载进度，获取锁定的 Desktop、Codex CLI 和 Electron，并在本机完成构建：

```bash
./install.sh
```

安装完成后，可以在应用菜单中点击“Codex Linux x86_64”桌面图标启动，也可以继续使用命令行启动：

如只想手动构建，不安装管理器，可直接运行：

```bash
./build-x86_64-flatpak.sh
```

然后必须安装桌面集成和 X11 窗口补丁：

```bash
./install-codex-desktop-integration.sh
```

这一步会做五件事：

- 修补已安装 Flatpak 内的 `app.asar`，避免 X11 下窗口变成 `override_redirect` unmanaged window。未修补时常见症状是无法拖动窗口、无法正常聚焦、像浮窗一样不受 GNOME/Mutter 管理。
- 写入 `~/.local/share/applications/com.openai.CodexLinuxX64.desktop`，让桌面应用列表里出现可点击入口。
- 安装 `~/.local/share/icons/hicolor/.../com.openai.CodexLinuxX64.png` 图标。
- 如系统支持 `systemd --user`，安装定时/路径服务，在 Flatpak 更新后自动重新应用窗口补丁。
- 检测并禁用旧版本可能残留的 `codex-x11-focus-helper.service`，但不会再创建新的焦点服务。

安装后运行：

```bash
flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu com.openai.CodexLinuxX64
```

也可以从桌面应用列表启动 `Codex Linux x86_64`。

## 从官方来源重新构建

如果要重新下载官方 Codex Desktop、Codex CLI 和 Electron 并重建：

```bash
./build-x86_64-flatpak.sh
```

脚本会显示下载/提取/依赖构建进度，并校验 Codex Desktop、Codex CLI 和 Electron 的 SHA256。构建结果和来源信息会写入本地生成的 `flatpak-sources/build-info.json`。

当前版本还会从同一次 GitHub latest release JSON 中锁定并下载主 CLI 与 Linux `codex-code-mode-host`，并拒绝 helper 缺失、非 Linux ELF、不可执行或与 CLI release tag 不一致的构建。不要使用 DMG 内的 macOS helper。

## 给 Codex Desktop 文件权限

Flatpak 默认会限制应用能看到的宿主机路径。本包的 manifest 默认只声明通用 Documents 入口；如果 Codex 里看不到项目目录，需要在宿主机终端执行授权命令，然后重启应用。

只授权一个工作目录，推荐：

```bash
mkdir -p "$HOME/codex-flatpak-workspace"
flatpak --user override --filesystem="$HOME/codex-flatpak-workspace:create" com.openai.CodexLinuxX64
flatpak --user kill com.openai.CodexLinuxX64 2>/dev/null || true
flatpak run --user com.openai.CodexLinuxX64
```

授权某个项目父目录：

```bash
flatpak --user override --filesystem="$HOME/Documents:create" com.openai.CodexLinuxX64
```

授权整个 home：

```bash
flatpak --user override --filesystem=home com.openai.CodexLinuxX64
```

授权几乎整个宿主机文件系统，风险更高：

```bash
flatpak --user override --filesystem=host com.openai.CodexLinuxX64
```

图形方式可以安装 Flatseal，选择 `Codex Linux x86_64`，在 Filesystem 区域添加需要的路径。

## 检查权限是否生效

查看当前 override：

```bash
flatpak --user override --show com.openai.CodexLinuxX64
```

从 Flatpak 沙箱内检查可见路径：

```bash
flatpak --user run --command=sh com.openai.CodexLinuxX64 -lc 'cat /.flatpak-info; ls -la "$HOME"'
```

注意：授权命令要在宿主机终端执行。Codex Desktop 自己打开的 shell 可能处在 Flatpak 沙箱内，里面不一定有 `flatpak` 命令。

## 常见问题

如果窗口无法拖动，先确认窗口补丁状态：

```bash
node scripts/patch-codex-linux-titlebar.cjs status
```

期望看到：

```text
state=patched
integrityOk=true
```

如果不是 patched，重新执行：

```bash
node scripts/patch-codex-linux-titlebar.cjs apply
./install-codex-desktop-integration.sh
```

如果系统命令是 `nodejs` 而不是 `node`：

```bash
nodejs scripts/patch-codex-linux-titlebar.cjs apply
```

如果桌面应用列表里没有图标入口，重新执行：

```bash
./install-codex-desktop-integration.sh
```

然后退出再打开 GNOME/应用启动器，或重新登录一次。

如果 Codex 报类似 `/bin/sh: No such file or directory`，不要只检查 `/bin/sh`。这类错误也可能是当前工作目录在沙箱里不可见。先确认宿主机路径存在，再确认 Flatpak 已授予该路径访问权限。

如果要撤销所有手动 override：

```bash
flatpak --user override --reset com.openai.CodexLinuxX64
flatpak --user kill com.openai.CodexLinuxX64 2>/dev/null || true
```

如果只是撤销 broad access，可以按需执行：

```bash
flatpak --user override --nofilesystem=host --nofilesystem=home com.openai.CodexLinuxX64
```

## 数据位置

Flatpak 应用数据通常在：

```bash
$HOME/.var/app/com.openai.CodexLinuxX64/
```

如果需要分享构建包，不要把这个目录一起打包；其中可能包含用户会话、日志、配置和缓存。
