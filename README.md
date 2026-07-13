# Codex Desktop for Linux（Flatpak）

[中文](README.md) | [English](README.en.md)

这是一个面向 Ubuntu x86_64 的 Codex Desktop Flatpak 打包项目。

它不是 OpenAI 官方发布的 Linux 安装包，而是将 Codex Desktop、Linux CLI 和相关运行文件整理为 Flatpak，方便在 Ubuntu 上安装、运行和回滚。

应用 ID：`com.openai.CodexLinuxX64`

## 快速安装

在 Ubuntu 宿主机终端安装依赖：

```bash
sudo apt update
sudo apt install git flatpak flatpak-builder p7zip-full curl file nodejs npm \
  python3 python3-pil unzip tar
```

把仓库克隆或解压到任意位置，然后进入能看到 `install.sh` 的仓库根目录。若文件没有运行权限，先执行下面的授权步骤；这条命令本身不依赖脚本权限：

```bash
chmod +x install.sh
find . -maxdepth 2 -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.py' -o -name '*.cjs' \) -exec chmod +x {} +
./install.sh
```

安装脚本启动后还会再次修复仓库内主脚本、管理器、测试脚本和辅助脚本的运行权限；以后重新运行安装脚本时无需重复手动授权。

只有上面安装 Ubuntu 依赖的 `apt` 命令需要 `sudo`。不要使用 `sudo ./install.sh` 或 `sudo sh install.sh`，因为安装器创建的是用户级 Flatpak 和构建缓存。如果已经用 `sudo` 运行过，先在仓库根目录修复所有权，再以普通用户重跑：

```bash
sudo chown -R "$USER":"$(id -gn)" .
sh install.sh
```

如果安装器检测到 root 所有或不可写的文件，会显示针对当前仓库路径的完整恢复命令。构建器会在用户工作目录中解包，使用独立的用户级 npm 缓存，并通过 `node` 直接运行 asar 工具，不依赖可能被 sudo 污染的 `~/.npm` 或 npm 命令 shim。

`install.sh` 会：

- 从公开地址下载并构建当前官方版本；
- 安装 Flatpak Desktop、桌面图标和窗口修复；
- 安装可选的终端管理命令；
- 如果缺少 Flatpak SDK 24.08，自动从 Flathub 安装；
- 停用旧版本遗留的自动升级 timer；
- 首次安装时询问文件访问权限。

脚本会根据系统语言自动显示中文或英文说明，也可以手动指定：

```bash
CODEX_LANG=zh ./install.sh
CODEX_LANG=en ./install.sh
```

如果检测到 `Asia/Shanghai`、`Asia/Macao`、`Asia/Urumqi` 等中国时区，缺少的 Flatpak SDK 会优先通过 USTC Flathub 镜像获取；Codex Desktop 使用官方最新地址，CLI 和 Electron 仍使用官方地址并校验下载摘要。USTC 的 Flathub 配置说明见[官方帮助](https://mirrors.ustc.edu.cn/help/flathub.html)。如需关闭镜像自动选择，可使用 `CODEX_MIRROR_MODE=never ./install.sh`；也可以通过 `CODEX_FLATHUB_REMOTE_URL` 指定自己的 Flathub 镜像。

脚本可以直接从 Bash、Zsh、Dash 等终端执行，不要使用 `source install.sh`。

安装完成后启动：

```bash
flatpak run --user --env=CODEX_FLATPAK_RENDERER=gpu com.openai.CodexLinuxX64
```

也可以从应用启动器打开“Codex Linux x86_64”。

安装完成后，也可以直接点击应用菜单中的“Codex Linux x86_64”桌面图标启动，不必每次都在终端执行命令。

> 每次构建默认获取当前官方 Codex Desktop 和最新稳定 Codex CLI。由于官方 Desktop DMG 地址是可变地址，Desktop 不使用固定 SHA256；CLI 和 Electron 仍校验下载摘要。实际版本会写入 `flatpak-sources/build-info.json`。

## 安装时选择文件权限

首次运行 `install.sh` 时，脚本会询问 Codex 的文件访问范围：

- 无额外文件权限：保留应用默认的 Documents 入口；
- Home 目录：读写当前用户的 Home 目录；
- 所有文件：只读访问整个宿主机文件系统；
- Host 权限：读写整个宿主机文件系统，风险最高。

再次运行 `./install.sh` 时，如果已经安装 Codex，脚本会识别现有安装并提供两个选择：重新构建安装 Desktop，或跳过安装、只更新文件权限。也可以直接使用：

脚本会读取当前 Flatpak 的 `filesystems` 配置，并在菜单中用“← 当前”标记识别出的权限类型；直接按回车会使用这个类型。无法映射的组合权限会提示警告，并按无额外文件权限处理。

```bash
./install.sh --permissions-only --permission=home
./install.sh --reinstall --permission=none
```

权限模式可用 `none`、`home`、`all`、`host` 或 `keep`。使用 `--manager-only` 时不会修改 Desktop 权限。

## 管理面板

默认安装不会启动后台网页服务。需要网页面板时：

```bash
./install.sh --enable
```

脚本会打印本机访问地址和访问令牌。网页服务只监听 `127.0.0.1`。

也可以只临时启动网页面板：

```bash
codex-flatpak-manager serve --open
```

常用终端命令：

```bash
codex-flatpak-manager status
codex-flatpak-manager panel
codex-flatpak-manager permissions list
codex-flatpak-manager profile list
```

`panel` 是交互式文字界面：

- `↑/↓` 或 `j/k`：移动选择；
- `Enter`：进入当前分类或执行功能；
- `←`、`Backspace` 或 `h`：返回上一级；
- `→` 或 `l`：进入下一级；
- `r`：刷新；
- `q`：退出。

不支持交互式终端时，可以输出一次性树形概览：

```bash
codex-flatpak-manager panel --plain
```

只安装管理命令、不重新安装 Desktop：

```bash
./install.sh --manager-only
```

## 更新与回滚

自动更新已经关闭。不同版本可能需要不同的构建、补丁和验收流程，因此请在确认对应版本流程后手动更新。

手动更新入口：

```bash
./upgrade-codex-desktop-flatpak.sh
```

不重启当前 Codex，只构建和安装：

```bash
./upgrade-codex-desktop-flatpak.sh --no-restart
```

只重新应用桌面集成和窗口修复：

```bash
./upgrade-codex-desktop-flatpak.sh --no-build --no-restart
```

旧版本遗留的 `codex-flatpak-manager-auto-upgrade.timer` 会由 `install.sh` 停用并删除。`--enable-auto` 仅作为旧命令的兼容参数，不会重新启用自动更新。

查看当前安装版本和 commit：

```bash
flatpak info --user --show-commit com.openai.CodexLinuxX64
flatpak run --user --command=sh com.openai.CodexLinuxX64 -lc \
  '/app/lib/codex/resources/codex --version'
```

回滚到已知 commit：

```bash
flatpak update --user -y --commit=<old-commit> com.openai.CodexLinuxX64
```

升级日志默认保存在仓库的 `upgrade-logs/` 目录。

## 文件权限

Flatpak 默认不会访问整个宿主机文件系统。推荐只授权需要使用的项目目录：

```bash
mkdir -p "$HOME/codex-flatpak-workspace"
flatpak --user override \
  --filesystem="$HOME/codex-flatpak-workspace:create" \
  com.openai.CodexLinuxX64
```

例如授权 `~/Documents`：

```bash
flatpak --user override \
  --filesystem="$HOME/Documents:create" \
  com.openai.CodexLinuxX64
```

查看当前权限：

```bash
flatpak --user override --show com.openai.CodexLinuxX64
```

撤销手动授权：

```bash
flatpak --user override --reset com.openai.CodexLinuxX64
```

也可以使用 Flatseal 图形化管理权限。权限修改后，退出并重新启动 Codex 才会完全生效。

## 窗口和焦点问题

安装脚本会应用 X11 窗口修复，解决窗口无法拖动、无法正常聚焦或像浮窗一样脱离桌面管理的问题。

旧版本可能安装过 `codex-x11-focus-helper.service`。现在的安装脚本会检测并停用它，也不会再创建这个服务，避免 Codex 抢走其他窗口的输入焦点。

检查窗口修复状态：

```bash
node scripts/patch-codex-linux-titlebar.cjs status
```

正常结果应包含：

```text
state=patched
integrityOk=true
```

如果桌面图标或窗口修复没有生效，重新执行：

```bash
./install-codex-desktop-integration.sh
```

## Profile 多开

管理器提供独立数据目录的多开入口：

```bash
codex-flatpak-manager profile create work
codex-flatpak-manager profile launch work
```

这个功能仍然属于实验功能。Profile 使用独立的配置、数据和缓存目录，但 Flatpak 文件权限仍然是应用级权限，不是每个 Profile 单独隔离。

## 从源码构建

如果要从官方来源重新获取 Desktop、CLI 和 Electron，请安装完整依赖：

```bash
sudo apt install flatpak flatpak-builder p7zip-full curl file \
  nodejs npm python3 python3-pil unzip tar
```

然后运行：

```bash
./build-x86_64-flatpak.sh
```

构建脚本会：

- 从官方 Codex Desktop DMG 获取应用资源；
- 从同一个 Codex CLI release 获取 Linux CLI 和 Code Mode Host；
- 校验下载摘要、Linux ELF 架构和可执行权限；
- 按 Electron 版本重建 Linux native modules；
- 构建并安装用户级 Flatpak。

构建结果和来源信息写入本地生成的 `flatpak-sources/build-info.json`。`install.sh` 和 `build-x86_64-flatpak.sh` 默认获取并编译当前官方版本；详细的构建检查、回滚和验收命令见 [Codex_Desktop_Flatpak_使用说明.md](Codex_Desktop_Flatpak_使用说明.md)。

## 数据位置

Codex 的 Flatpak 数据通常位于：

```text
$HOME/.var/app/com.openai.CodexLinuxX64/
```

其中可能包含登录状态、配置、缓存和日志。分享仓库或构建包时，不要把这个目录一起打包。

## 目录说明

- `install.sh`：下载并安装当前官方版本的 Desktop 和管理命令；
- `upgrade-codex-desktop-flatpak.sh`：手动更新入口；
- `build-x86_64-flatpak.sh`：从官方来源重新构建；
- `install-codex-desktop-integration.sh`：安装桌面入口和窗口修复；
- `manager/`：终端管理命令和本地网页面板；
- `flatpak-sources/`：构建过程中生成的临时输入，不提交到仓库；
- `README.en.md` 和 `Codex_Desktop_Flatpak_User_Guide.md`：英文文档；
- `tests/`：脚本和管理器测试。
