# 脱敏与打包清单

生成发布包时只复制必要构建输入和说明文档，不修改原始目录。

## 已排除

- `.flatpak-builder/`：Flatpak builder 缓存和对象库。
- `.build.*`：临时构建目录。
- `build-dir/`：本机安装构建输出，其中可能包含 `var/run/host` 主机视图。
- `downloads/`：本机下载缓存和历史备份文件。
- `debug/`：窗口截图、XWD 截图和调试探针。
- `__pycache__/` 与 `*.pyc`：本机 Python 字节码缓存。
- `codex-flatpak-workspace/`：用户工作目录，未进入发布包。
- `$HOME/.var/app/com.openai.CodexLinuxX64/`：用户配置、会话和日志目录，未进入发布包。

## 已替换或泛化

- 本机用户名和绝对 home 路径不进入发布文档。
- manifest 中的默认文件访问路径改为通用 XDG Documents 入口，用户可用 `flatpak override` 自行授权项目路径。
- host launcher 桌面入口不再硬编码个人 home 路径。
- 旧 README 中的本机代理示例、个人路径和机器状态说明不进入发布包。

## 验证建议

打包前后至少执行：

```bash
grep -RIna -E '<LOCAL_USER>|/home/<LOCAL_USER>|<LOCAL_PRIVATE_IP>|<LOCAL_PRIVATE_DOMAIN>|OPENAI_API_KEY|github_pat|ghp_|OPENAI_SECRET_KEY_PATTERN|BEGIN .*PRIVATE KEY' .
sha256sum codex-linux-x86_64-flatpak-redacted.tar.zst
```

执行时请把 `<LOCAL_USER>`、`<LOCAL_PRIVATE_IP>` 和 `<LOCAL_PRIVATE_DOMAIN>` 替换成实际要排除的本机值。如命中来自第三方许可证文本中的公开维护者邮箱或通用词汇，不视为本机个人信息；但任何本机路径、账户、令牌或私钥命中都必须处理后再发布。
