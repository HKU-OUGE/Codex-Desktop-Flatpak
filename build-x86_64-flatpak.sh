#!/usr/bin/env bash
set -euo pipefail

APP_ID="com.openai.CodexLinuxX64"
RUNTIME_ID="org.freedesktop.Sdk"
RUNTIME_VERSION="24.08"
ASAR_NPM_PACKAGE="${ASAR_NPM_PACKAGE:-@electron/asar@3.2.17}"
ELECTRON_REBUILD_VERSION="${ELECTRON_REBUILD_VERSION:-3.7.2}"
CODEX_REFRESH_DOWNLOADS="${CODEX_REFRESH_DOWNLOADS:-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADS="$ROOT/downloads"
SOURCES="$ROOT/flatpak-sources"
WORK_DIR="$(mktemp -d "$ROOT/.build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -s "$HOME/.nvm/nvm.sh" ]; then
  # Keep builds reproducible when the script is launched from a non-login shell.
  # Ubuntu 22.04's system Node 12 is too old for the Electron tooling used here.
  # shellcheck disable=SC1091
  . "$HOME/.nvm/nvm.sh"
  nvm use --silent default >/dev/null 2>&1 || nvm use --silent node >/dev/null 2>&1 || true
fi

# Official OpenAI Codex desktop app DMG. This is the app bundle, not the
# open-source CLI-only DMG from openai/codex releases.
CODEX_APP_DMG_URL="${CODEX_APP_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
CODEX_APP_VERSION="${CODEX_APP_VERSION:-26.707.31428}"
CODEX_APP_DMG_SHA256="${CODEX_APP_DMG_SHA256:-6f67af7e2f934093ab8afebcec11374d40c8db8f9100fb6620f24155401d8319}"
CODEX_APP_DMG="${CODEX_APP_DMG:-$DOWNLOADS/Codex-app-${CODEX_APP_VERSION}.dmg}"

# Official OpenAI Codex CLI backend. Keep the release tag pinned because the
# Desktop app and its Linux helpers must follow the same version-specific flow.
CODEX_RELEASES_LATEST_API="${CODEX_RELEASES_LATEST_API:-https://api.github.com/repos/openai/codex/releases/latest}"
CODEX_RELEASES_TAG_API="${CODEX_RELEASES_TAG_API:-https://api.github.com/repos/openai/codex/releases/tags}"
CODEX_RELEASE_TAG="${CODEX_RELEASE_TAG:-rust-v0.144.1}"
CODEX_RELEASE_JSON="${CODEX_RELEASE_JSON:-$DOWNLOADS/openai-codex-${CODEX_RELEASE_TAG#rust-}-release.json}"
CODEX_TARGET_TRIPLE="${CODEX_TARGET_TRIPLE:-x86_64-unknown-linux-musl}"
CODEX_CLI_ASSET="${CODEX_CLI_ASSET:-codex-${CODEX_TARGET_TRIPLE}.tar.gz}"
CODEX_CLI_SHA256="${CODEX_CLI_SHA256:-}"
CODEX_CLI_URL="${CODEX_CLI_URL:-}"
CODEX_CODE_MODE_HOST_ASSET="${CODEX_CODE_MODE_HOST_ASSET:-codex-code-mode-host-${CODEX_TARGET_TRIPLE}.tar.gz}"
CODEX_CODE_MODE_HOST_SHA256="${CODEX_CODE_MODE_HOST_SHA256:-}"
CODEX_CODE_MODE_HOST_URL="${CODEX_CODE_MODE_HOST_URL:-}"
CODEX_LANG="${CODEX_LANG:-auto}"
CODEX_MIRROR_MODE="${CODEX_MIRROR_MODE:-auto}"
CODEX_USE_MIRROR=0

PROJECT_DIR="${CODEX_FLATPAK_PROJECT_DIR:-$HOME/codex-flatpak-workspace}"

info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

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
=== Codex Desktop Flatpak 构建程序 ===
说明：根据系统语言显示提示；本程序会从公开地址下载锁定版本的 Codex Desktop、Codex CLI 和 Electron，并在本机编译 Flatpak 输入。
免责声明：本项目不是 OpenAI 官方 Linux 安装包；构建结果、许可证合规性和运行风险由使用者自行确认并承担。
NOTICE
  else
    cat <<'NOTICE'
=== Codex Desktop Flatpak build ===
Notice: Messages follow the system language. This script downloads pinned Codex Desktop, Codex CLI, and Electron sources, then builds the Flatpak locally.
Disclaimer: This is not an official OpenAI Linux package. Verify the build result, licenses, and runtime risks yourself.
NOTICE
  fi
  if [ "$CODEX_USE_MIRROR" = "1" ]; then
    if [ "$CODEX_LANG" = "zh" ]; then
      info "检测到中国时区：Flatpak SDK 将优先使用 USTC Flathub 镜像；Codex Desktop/CLI/Electron 仍使用官方地址并校验摘要。"
    else
      info "China timezone detected: the Flatpak SDK will prefer the USTC Flathub mirror; Codex Desktop/CLI/Electron stay on official URLs with checksum verification."
    fi
  else
    if [ "$CODEX_LANG" = "zh" ]; then
      info "使用官方 Flathub 地址；Codex Desktop/CLI/Electron 始终使用官方地址并校验摘要。"
    else
      info "Using the official Flathub URL; Codex Desktop/CLI/Electron always use official URLs with checksum verification."
    fi
  fi
}

configure_flathub_remote() {
  local mirror_url="${CODEX_FLATHUB_REMOTE_URL:-https://mirrors.ustc.edu.cn/flathub}"
  local official_url="https://flathub.org/repo/flathub.flatpakrepo"
  flatpak --user remote-add --if-not-exists flathub "$official_url"
  if [ "$CODEX_USE_MIRROR" = "1" ]; then
    if flatpak --user remote-modify flathub --url="$mirror_url"; then
      info "Configured Flathub mirror: $mirror_url"
    else
      warn "Could not configure the Flathub mirror; falling back to the official Flathub URL."
      flatpak --user remote-modify flathub --url="https://dl.flathub.org/repo/"
    fi
  fi
}

require() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "Missing required command: $cmd"
      missing=1
    fi
  done
  [ "$missing" = 0 ] || die "Install the missing tools and rerun this script."
}

download() {
  local url="$1"
  local out="$2"
  local tmp
  if [ "${CODEX_FORCE_DOWNLOAD:-0}" = "1" ] && [ -e "$out" ]; then
    rm -f "$out"
  fi
  if [ -s "$out" ]; then
    if [ "$CODEX_REFRESH_DOWNLOADS" = "1" ]; then
      info "Checking cached $(basename "$out")"
      tmp="$(mktemp "$out.XXXXXX")"
      if curl_download -z "$out" -o "$tmp" "$url"; then
        if [ -s "$tmp" ]; then
          mv "$tmp" "$out"
          ok "Updated cached $(basename "$out")"
        else
          rm -f "$tmp"
          info "Cached $(basename "$out") is current"
        fi
      else
        rm -f "$tmp"
        die "Could not refresh cached $(basename "$out")"
      fi
    else
      info "Using cached $(basename "$out")"
    fi
    return
  fi
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "$out.part.XXXXXX")"
  info "Downloading $url"
  if curl_download -o "$tmp" "$url" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$out"
  else
    rm -f "$tmp"
    die "Download failed or returned an empty file: $url"
  fi
}

curl_download() {
  if [ "${CODEX_NONINTERACTIVE:-0}" = "1" ]; then
    curl -fL --retry 3 --connect-timeout 20 --silent --show-error "$@"
  else
    curl -fL --retry 3 --connect-timeout 20 --progress-bar --show-error "$@"
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  [ -n "$expected" ] || return 0
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    warn "SHA256 mismatch for $file: expected $expected, got $actual"
    return 1
  fi
}

download_verified() {
  local url="$1"
  local out="$2"
  local expected="$3"
  download "$url" "$out"
  if verify_sha256 "$out" "$expected"; then
    return 0
  fi
  warn "Removing the invalid cached file and downloading it again: $out"
  rm -f "$out"
  download "$url" "$out"
  verify_sha256 "$out" "$expected" ||
    die "Download checksum verification failed after retry: $out"
}

verify_linux_elf_file() {
  local file="$1"
  local label="$2"
  [ -s "$file" ] || die "$label is missing or empty: $file"
  local description
  description="$(file "$file")"
  case "$description" in
    *"ELF 64-bit"*"x86-64"*) ;;
    *) die "$label is not a target Linux x86-64 ELF: $description" ;;
  esac
  case "$description" in
    *"Mach-O"*) die "$label is a Mach-O binary, not Linux ELF: $description" ;;
  esac
}

verify_linux_elf_executable() {
  local file="$1"
  local label="$2"
  verify_linux_elf_file "$file" "$label"
  [ -x "$file" ] || die "$label is not executable: $file"
}

ensure_release_json() {
  if [ -s "$CODEX_RELEASE_JSON" ] && python3 - "$CODEX_RELEASE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    payload = json.load(source)
if not isinstance(payload, dict) or not payload.get("tag_name"):
    raise SystemExit(1)
PY
  then
    info "Using locked Codex release JSON: $CODEX_RELEASE_JSON"
    return
  elif [ -e "$CODEX_RELEASE_JSON" ]; then
    warn "Ignoring an incomplete or invalid Codex release JSON: $CODEX_RELEASE_JSON"
    rm -f "$CODEX_RELEASE_JSON"
  fi
  mkdir -p "$(dirname "$CODEX_RELEASE_JSON")"
  local tmp release_url
  tmp="$(mktemp "$CODEX_RELEASE_JSON.XXXXXX")"
  if [ "$CODEX_RELEASE_TAG" = "latest" ]; then
    release_url="$CODEX_RELEASES_LATEST_API"
    info "Downloading Codex latest release metadata"
  else
    release_url="$CODEX_RELEASES_TAG_API/$CODEX_RELEASE_TAG"
    info "Downloading Codex release metadata for $CODEX_RELEASE_TAG"
  fi
  curl_download -H "Accept: application/vnd.github+json" -o "$tmp" "$release_url"
  mv "$tmp" "$CODEX_RELEASE_JSON"
}

resolve_codex_release_assets() {
  ensure_release_json
  local resolved
  resolved="$(python3 - "$CODEX_RELEASE_JSON" "$CODEX_RELEASE_TAG" "$CODEX_CLI_ASSET" "$CODEX_CODE_MODE_HOST_ASSET" <<'PY'
import json
import sys

json_path, requested_tag, cli_asset, helper_asset = sys.argv[1:]
with open(json_path, "r", encoding="utf-8") as response:
    release = json.load(response)

tag = release.get("tag_name") or ""
if not tag:
    raise SystemExit("Codex release JSON is missing tag_name")
if requested_tag != "latest" and tag != requested_tag:
    raise SystemExit(f"Codex release JSON tag {tag} does not match requested {requested_tag}")
if release.get("draft") or release.get("prerelease"):
    raise SystemExit(f"{tag} is not a stable release")

assets = {asset.get("name"): asset for asset in release.get("assets") or []}

def require_asset(name):
    asset = assets.get(name)
    if not asset:
        raise SystemExit(f"Codex release {tag} is missing asset {name}")
    url = asset.get("browser_download_url") or ""
    digest = asset.get("digest") or ""
    sha = digest.removeprefix("sha256:")
    if not url:
        raise SystemExit(f"Codex release {tag} asset {name} is missing browser_download_url")
    if not digest.startswith("sha256:") or len(sha) != 64:
        raise SystemExit(f"Codex release {tag} asset {name} is missing sha256 digest")
    return url, sha

cli_url, cli_sha = require_asset(cli_asset)
helper_url, helper_sha = require_asset(helper_asset)

print(f"CODEX_RELEASE_TAG={tag}")
print(f"CODEX_CLI_URL={cli_url}")
print(f"CODEX_CLI_SHA256={cli_sha}")
print(f"CODEX_CODE_MODE_HOST_URL={helper_url}")
print(f"CODEX_CODE_MODE_HOST_SHA256={helper_sha}")
PY
)"
  while IFS='=' read -r key value; do
    case "$key" in
      CODEX_RELEASE_TAG) CODEX_RELEASE_TAG="$value" ;;
      CODEX_CLI_URL) CODEX_CLI_URL="$value" ;;
      CODEX_CLI_SHA256) CODEX_CLI_SHA256="$value" ;;
      CODEX_CODE_MODE_HOST_URL) CODEX_CODE_MODE_HOST_URL="$value" ;;
      CODEX_CODE_MODE_HOST_SHA256) CODEX_CODE_MODE_HOST_SHA256="$value" ;;
    esac
  done <<<"$resolved"
}

extract_with_asar() {
  local asar_file="$1"
  local out_dir="$2"
  if command -v asar >/dev/null 2>&1; then
    asar extract "$asar_file" "$out_dir"
  else
    npm exec --yes "$ASAR_NPM_PACKAGE" -- extract "$asar_file" "$out_dir"
  fi
}

extract_asar_file() {
  local asar_file="$1"
  local file_name="$2"
  local out_file="$3"
  local out_dir
  out_dir="$(mktemp -d "$WORK_DIR/asar-file.XXXXXX")"
  (
    cd "$out_dir"
    if command -v asar >/dev/null 2>&1; then
      asar extract-file "$asar_file" "$file_name"
    else
      npm exec --yes "$ASAR_NPM_PACKAGE" -- extract-file "$asar_file" "$file_name"
    fi
  )
  [ -f "$out_dir/$file_name" ] || die "Could not extract $file_name from app.asar"
  mkdir -p "$(dirname "$out_file")"
  cp "$out_dir/$file_name" "$out_file"
}

list_with_asar() {
  local asar_file="$1"
  if command -v asar >/dev/null 2>&1; then
    asar list "$asar_file"
  else
    npm exec --yes "$ASAR_NPM_PACKAGE" -- list "$asar_file"
  fi
}

find_app_resources() {
  local dmg_root="$1"
  python3 - "$dmg_root" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
matches = []
for resources in root.rglob("Contents/Resources"):
    if (resources / "app.asar").is_file() and (resources / "app.asar.unpacked").is_dir():
        matches.append(resources)
if len(matches) != 1:
    print(
        f"Expected exactly one app resources directory with app.asar and app.asar.unpacked, found {len(matches)}",
        file=sys.stderr,
    )
    for match in matches:
        print(match, file=sys.stderr)
    raise SystemExit(1)
print(matches[0])
PY
}

check_upstream_compatibility() {
  local app_asar="$1"
  local out_dir="$2"
  local out_json="$3"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  extract_with_asar "$app_asar" "$out_dir"
  python3 - "$out_dir" "$out_json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])
patterns = [
    "features.code_mode_host=true",
    "codex-code-mode-host",
    "windowsSiblingExecutableNames",
    "codex_chronicle",
]
summary = {}
for pattern in patterns:
    files = []
    total = 0
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            data = path.read_text("utf-8", errors="ignore")
        except Exception:
            continue
        count = data.count(pattern)
        if count:
            total += count
            files.append(str(path.relative_to(root)))
    summary[pattern] = {"count": total, "files": files[:20]}
required = summary["features.code_mode_host=true"]["count"] > 0 or summary["codex-code-mode-host"]["count"] > 0
payload = {
    "codeModeHostRequired": required,
    "patterns": summary,
    "linuxHelperPolicy": "required when code mode host feature or helper reference is present",
    "chroniclePolicy": "not packaged unless an official Linux codex_chronicle asset exists",
}
out.write_text(json.dumps(payload, indent=2) + "\n")
print("CODE_MODE_HOST_REQUIRED=1" if required else "CODE_MODE_HOST_REQUIRED=0")
PY
}

copy_rebuilt_native_outputs() {
  local module_name="$1"
  local src_root="$2/node_modules/$module_name"
  local dst_root="$3/node_modules/$module_name"
  [ -d "$src_root" ] || die "Native build module not found: $module_name"
  local native_paths=()
  while IFS= read -r native_file; do
    native_paths+=("$native_file")
  done < <(find "$src_root/build/Release" -name '*.node' -type f 2>/dev/null | sort)
  if [ "$module_name" = "node-pty" ]; then
    while IFS= read -r native_file; do
      native_paths+=("$native_file")
    done < <(find "$src_root/bin" -path '*/linux-x64-*/*.node' -type f 2>/dev/null | sort)
  fi
  [ "${#native_paths[@]}" -gt 0 ] || die "No rebuilt native outputs found for $module_name"
  local native_file
  while IFS= read -r native_file; do
    local rel="${native_file#"$src_root"/}"
    mkdir -p "$(dirname "$dst_root/$rel")"
    cp "$native_file" "$dst_root/$rel"
    if [ -x "$native_file" ]; then
      chmod 755 "$dst_root/$rel"
    fi
    ok "Installed rebuilt native output: $module_name/$rel"
  done < <(printf '%s\n' "${native_paths[@]}")
}

sanitize_native_module_outputs() {
  local unpacked="$1"
  rm -f "$unpacked/node_modules/node-pty/build/Release/spawn-helper"
  rm -rf "$unpacked/node_modules/node-pty/build/Release/pty.node.dSYM"
}

verify_linux_native_outputs() {
  local unpacked="$1"
  local required_node=(
    "node_modules/better-sqlite3/build/Release/better_sqlite3.node"
    "node_modules/node-pty/build/Release/pty.node"
  )
  local rel
  for rel in "${required_node[@]}"; do
    verify_linux_elf_file "$unpacked/$rel" "$rel"
  done
  if [ -e "$unpacked/node_modules/node-pty/build/Release/spawn-helper" ]; then
    verify_linux_elf_executable "$unpacked/node_modules/node-pty/build/Release/spawn-helper" \
      "node_modules/node-pty/build/Release/spawn-helper"
  fi
  local bad
  bad="$(find "$unpacked/node_modules/better-sqlite3/build/Release" "$unpacked/node_modules/node-pty/build/Release" \( -name '*.node' -o -name 'spawn-helper' \) -type f -exec file {} + 2>/dev/null | grep 'Mach-O' || true)"
  [ -z "$bad" ] || die "Linux-called native module path still contains Mach-O files: $bad"
}

extract_release_binary() {
  local archive="$1"
  local binary_name="$2"
  local out="$3"
  local work="$4"
  rm -rf "$work"
  mkdir -p "$work"
  tar xf "$archive" -C "$work"
  local bin
  bin="$(find "$work" -type f \( -name "$binary_name" -o -name "${binary_name}-${CODEX_TARGET_TRIPLE}" \) | head -1 || true)"
  [ -n "$bin" ] || die "Could not find $binary_name binary in $(basename "$archive")"
  install -m755 "$bin" "$out"
}

write_resized_png_icon() {
  local src="$1"
  local dst="$2"
  local size="$3"
  python3 - "$src" "$dst" "$size" <<'PY'
from pathlib import Path
import sys
from PIL import Image

src, dst, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
image = Image.open(src).convert("RGBA")
if image.size != (size, size):
    image = image.resize((size, size), Image.Resampling.LANCZOS)
Path(dst).parent.mkdir(parents=True, exist_ok=True)
image.save(dst, format="PNG")
PY
}

extract_icon() {
  local resources="$1"
  local dst="$2"
  local png
  png="$(find "$resources" -maxdepth 2 -type f \( -name 'icon.png' -o -name 'codexTemplate.png' -o -name '*512*.png' \) | head -1 || true)"
  if [ -n "$png" ]; then
    write_resized_png_icon "$png" "$dst/icon-512.png" 512
    write_resized_png_icon "$png" "$dst/icon-256.png" 256
    return
  fi

  local icns
  icns="$(find "$resources" -name '*.icns' -type f | head -1 || true)"
  [ -n "$icns" ] || die "No PNG or ICNS icon found in app resources"
  python3 - "$icns" "$dst" <<'PY'
import struct
import sys
from pathlib import Path

icns_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
data = icns_path.read_bytes()
chunks = {b"ic09": "icon-512.png", b"ic08": "icon-256.png"}
seen = set()
pos = 8
while pos + 8 <= len(data):
    kind = data[pos:pos + 4]
    size = struct.unpack(">I", data[pos + 4:pos + 8])[0]
    payload = data[pos + 8:pos + size]
    if kind in chunks:
        (out_dir / chunks[kind]).write_bytes(payload)
        seen.add(chunks[kind])
    pos += size
if "icon-512.png" not in seen and "icon-256.png" in seen:
    (out_dir / "icon-512.png").write_bytes((out_dir / "icon-256.png").read_bytes())
if "icon-256.png" not in seen and "icon-512.png" in seen:
    (out_dir / "icon-256.png").write_bytes((out_dir / "icon-512.png").read_bytes())
if not seen:
    raise SystemExit("No PNG icon chunks found in ICNS")
PY
  write_resized_png_icon "$dst/icon-512.png" "$dst/icon-512.png" 512
  write_resized_png_icon "$dst/icon-256.png" "$dst/icon-256.png" 256
}

write_build_info() {
  local out="$1"
  local electron="$2"
  local dmg_sha="$3"
  local cli_archive_sha="$4"
  local cli_binary_sha="$5"
  local helper_archive_sha="$6"
  local helper_binary_sha="$7"
  local code_mode_host_required="$8"
  local app_version="$9"
  python3 - "$out" "$electron" "$dmg_sha" "$cli_archive_sha" "$cli_binary_sha" "$helper_archive_sha" "$helper_binary_sha" "$code_mode_host_required" "$app_version" "$CODEX_RELEASE_TAG" "$RUNTIME_ID" "$RUNTIME_VERSION" "$CODEX_APP_DMG_URL" "$CODEX_APP_DMG" "$CODEX_RELEASES_LATEST_API" "$CODEX_RELEASE_JSON" "$CODEX_CLI_ASSET" "$CODEX_CLI_URL" "$CODEX_CODE_MODE_HOST_ASSET" "$CODEX_CODE_MODE_HOST_URL" "$CODEX_TARGET_TRIPLE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    out,
    electron,
    dmg_sha,
    cli_archive_sha,
    cli_binary_sha,
    helper_archive_sha,
    helper_binary_sha,
    code_mode_host_required,
    app_version,
    codex_tag,
    runtime_id,
    runtime_version,
    dmg_url,
    dmg_local_path,
    release_api_url,
    release_json_path,
    cli_asset,
    cli_url,
    helper_asset,
    helper_url,
    target_triple,
) = sys.argv[1:]
payload = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "appId": "com.openai.CodexLinuxX64",
    "runtime": f"{runtime_id}//{runtime_version}",
    "targetTriple": target_triple,
    "codexAppVersion": app_version,
    "codexAppDmgUrl": dmg_url,
    "codexAppDmgLocalPath": f"downloads/{Path(dmg_local_path).name}",
    "codexAppDmgSha256": dmg_sha,
    "codexReleaseApiUrl": release_api_url,
    "codexReleaseJson": f"downloads/{Path(release_json_path).name}",
    "codexCliReleaseTag": codex_tag,
    "codexCliUrl": cli_url,
    "codexCliAsset": cli_asset,
    "codexCliSha256": cli_archive_sha,
    "codexCliBinarySha256": cli_binary_sha,
    "codexCodeModeHostRequired": code_mode_host_required == "1",
    "codexCodeModeHostUrl": helper_url,
    "codexCodeModeHostAsset": helper_asset,
    "codexCodeModeHostSha256": helper_archive_sha,
    "codexCodeModeHostBinarySha256": helper_binary_sha,
    "electronVersion": electron,
    "securityPosture": {
        "bundlePatches": "none",
        "runtimePatches": "none",
        "remoteControlEnabled": False,
        "chromeNativeMessagingHost": False,
        "browserUseShim": False,
        "codexHome": "$XDG_CONFIG_HOME/codex inside the Flatpak sandbox",
    },
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n")
PY
}

main() {
  detect_language
  configure_source_policy
  print_notice
  require 7z curl file flatpak flatpak-builder node npm python3 sha256sum tar unzip
  python3 -c 'from PIL import Image' >/dev/null 2>&1 ||
    die "Missing Python Pillow module required to resize Flatpak icons."
  mkdir -p "$DOWNLOADS" "$SOURCES" "$PROJECT_DIR"

  info "Ensuring Flatpak runtime is available"
  if ! flatpak info --user "${RUNTIME_ID}//${RUNTIME_VERSION}" >/dev/null 2>&1; then
    configure_flathub_remote
    flatpak --user install -y flathub "${RUNTIME_ID}//${RUNTIME_VERSION}"
  fi

  info "Downloading Codex Desktop $CODEX_APP_VERSION"
  CODEX_REFRESH_DOWNLOADS=0 download "$CODEX_APP_DMG_URL" "$CODEX_APP_DMG"
  if ! verify_sha256 "$CODEX_APP_DMG" "$CODEX_APP_DMG_SHA256"; then
    warn "Removing the invalid cached Codex app DMG and downloading it again"
    rm -f "$CODEX_APP_DMG"
    CODEX_REFRESH_DOWNLOADS=0 download "$CODEX_APP_DMG_URL" "$CODEX_APP_DMG"
    verify_sha256 "$CODEX_APP_DMG" "$CODEX_APP_DMG_SHA256" ||
      die "Codex app DMG checksum verification failed after retry"
  fi
  local dmg_sha
  dmg_sha="$(sha256sum "$CODEX_APP_DMG" | awk '{print $1}')"
  ok "Codex app DMG SHA256: $dmg_sha"

  resolve_codex_release_assets
  ok "Codex release: $CODEX_RELEASE_TAG"
  local codex_cli_download="$DOWNLOADS/${CODEX_RELEASE_TAG}-${CODEX_CLI_ASSET}"
  download_verified "$CODEX_CLI_URL" "$codex_cli_download" "$CODEX_CLI_SHA256"
  local cli_sha
  cli_sha="$(sha256sum "$codex_cli_download" | awk '{print $1}')"
  ok "Codex CLI asset SHA256: $cli_sha"
  local code_mode_host_download="$DOWNLOADS/${CODEX_RELEASE_TAG}-${CODEX_CODE_MODE_HOST_ASSET}"
  download_verified "$CODEX_CODE_MODE_HOST_URL" "$code_mode_host_download" "$CODEX_CODE_MODE_HOST_SHA256"
  local helper_sha
  helper_sha="$(sha256sum "$code_mode_host_download" | awk '{print $1}')"
  ok "Codex code mode host asset SHA256: $helper_sha"

  info "Extracting Codex app DMG"
  if ! 7z x "$CODEX_APP_DMG" -o"$WORK_DIR/dmg" -y; then
    warn "7z returned warnings while extracting the DMG; checking whether app resources were extracted."
    if ! find_app_resources "$WORK_DIR/dmg" >/dev/null 2>&1; then
      warn "7z did not expose app resources; trying dmg2img fallback."
      command -v dmg2img >/dev/null 2>&1 || die "Install dmg2img and rerun this script: sudo apt install dmg2img"
      local dmg_img="$WORK_DIR/Codex.img"
      dmg2img "$CODEX_APP_DMG" "$dmg_img"
      7z x "$dmg_img" -o"$WORK_DIR/dmg" -y
    fi
  fi
  local resources
  resources="$(find_app_resources "$WORK_DIR/dmg")"
  [ -f "$resources/app.asar" ] || die "Could not find app.asar in Codex resources"
  [ -d "$resources/app.asar.unpacked" ] || die "Could not find app.asar.unpacked in Codex resources"
  ok "Found app resources: $resources"

  info "Reading app package metadata"
  local package_json="$WORK_DIR/package.json"
  extract_asar_file "$resources/app.asar" "package.json" "$package_json"
  list_with_asar "$resources/app.asar" | grep -q '^/webview/index.html$' || die "app.asar is missing webview/index.html"
  local better_sqlite3_version
  local node_pty_version
  better_sqlite3_version="$(node -e "const p=require('$package_json'); console.log((p.dependencies&&p.dependencies['better-sqlite3']) || '^12.9.0')")"
  node_pty_version="$(node -e "const p=require('$package_json'); console.log((p.dependencies&&p.dependencies['node-pty']) || '^1.1.0')")"
  local app_version
  local app_main
  app_version="$(node -e "const p=require('$package_json'); console.log(p.version || '')")"
  app_main="$(node -e "const p=require('$package_json'); console.log(p.main || '')")"
  [ "$app_version" = "$CODEX_APP_VERSION" ] ||
    die "Desktop app version mismatch: expected $CODEX_APP_VERSION, got ${app_version:-unknown}"
  ok "Desktop app version: ${app_version:-unknown}; main: ${app_main:-unknown}"
  local compat_output
  local upstream_compatibility_json="$WORK_DIR/upstream-compatibility.json"
  compat_output="$(check_upstream_compatibility "$resources/app.asar" "$WORK_DIR/app-asar-extracted" "$upstream_compatibility_json")"
  local code_mode_host_required=0
  if grep -qx 'CODE_MODE_HOST_REQUIRED=1' <<<"$compat_output"; then
    code_mode_host_required=1
    ok "Upstream app.asar requires code mode host support"
  else
    info "Upstream app.asar did not require code mode host support"
  fi

  local electron_plist
  electron_plist="$(find "$WORK_DIR/dmg" \( -path '*/Electron Framework.framework/*/Info.plist' -o -path '*/Codex Framework.framework/*/Info.plist' \) -type f | head -1 || true)"
  local electron_version
  electron_version="$(node -e "const p=require('$package_json'); const v=(p.devDependencies&&p.devDependencies.electron)||(p.dependencies&&p.dependencies.electron)||'42.1.0'; console.log(String(v).replace(/^[~^]/,''));")"
  if [ -z "$electron_version" ] && [ -n "$electron_plist" ]; then
    electron_version="$(python3 - "$electron_plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
print(p.get('CFBundleShortVersionString') or p.get('CFBundleVersion') or '')
PY
)"
  fi
  [ -n "$electron_version" ] || die "Could not determine Electron version"
  ok "Electron version: $electron_version"

  local electron_zip="$DOWNLOADS/electron-v${electron_version}-linux-x64.zip"
  local electron_shasums="$DOWNLOADS/electron-v${electron_version}-SHASUMS256.txt"
  electron_url="https://github.com/electron/electron/releases/download/v${electron_version}/electron-v${electron_version}-linux-x64.zip"
  electron_shasums_url="https://github.com/electron/electron/releases/download/v${electron_version}/SHASUMS256.txt"
  download "$electron_url" "$electron_zip"
  download "$electron_shasums_url" "$electron_shasums"
  if ! (
    cd "$DOWNLOADS"
    grep "[ *]electron-v${electron_version}-linux-x64.zip$" "electron-v${electron_version}-SHASUMS256.txt" |
      sed 's/ \*/  /' |
      sha256sum -c -
  ); then
    warn "Electron cache verification failed; removing both cached files and downloading them again"
    rm -f "$electron_zip" "$electron_shasums"
    download "$electron_url" "$electron_zip"
    download "$electron_shasums_url" "$electron_shasums"
    (
      cd "$DOWNLOADS"
      grep "[ *]electron-v${electron_version}-linux-x64.zip$" "electron-v${electron_version}-SHASUMS256.txt" |
        sed 's/ \*/  /' |
        sha256sum -c -
    ) || die "Electron checksum verification failed after retry"
  fi
  ok "Electron checksum verified"

  info "Preparing Flatpak sources"
  rm -rf "$SOURCES/electron" "$SOURCES/app.asar" "$SOURCES/codex-app.asar" "$SOURCES/app.asar.unpacked" "$SOURCES/codex" "$SOURCES/codex-code-mode-host" "$SOURCES/build-info.json" "$SOURCES/upstream-compatibility.json" "$SOURCES/icon-512.png" "$SOURCES/icon-256.png"
  unzip -q "$electron_zip" -d "$SOURCES/electron"
  cp "$resources/app.asar" "$SOURCES/app.asar"
  cp -a "$resources/app.asar.unpacked" "$SOURCES/app.asar.unpacked"
  cp "$upstream_compatibility_json" "$SOURCES/upstream-compatibility.json"
  cp "$ROOT/packaging/codex-launcher.sh" "$SOURCES/codex-launcher.sh"
  cp "$ROOT/packaging/com.openai.CodexLinuxX64.desktop" "$SOURCES/com.openai.CodexLinuxX64.desktop"
  chmod 755 "$SOURCES/codex-launcher.sh"
  extract_icon "$resources" "$SOURCES"

  ok "Native dependency versions: better-sqlite3@$better_sqlite3_version, node-pty@$node_pty_version"

  info "Extracting official Linux x86_64 Codex CLI"
  extract_release_binary "$codex_cli_download" "codex" "$SOURCES/codex" "$WORK_DIR/codex-cli"
  verify_linux_elf_executable "$SOURCES/codex" "Codex CLI"
  local expected_cli_version
  local actual_cli_version
  expected_cli_version="${CODEX_RELEASE_TAG#rust-v}"
  actual_cli_version="$("$SOURCES/codex" --version | awk '{print $2}')"
  [ "$actual_cli_version" = "$expected_cli_version" ] ||
    die "Codex CLI version mismatch: tag $CODEX_RELEASE_TAG expects $expected_cli_version, got $actual_cli_version"
  local cli_binary_sha
  cli_binary_sha="$(sha256sum "$SOURCES/codex" | awk '{print $1}')"
  ok "Codex CLI binary SHA256: $cli_binary_sha"

  info "Extracting official Linux x86_64 Codex code mode host"
  extract_release_binary "$code_mode_host_download" "codex-code-mode-host" "$SOURCES/codex-code-mode-host" "$WORK_DIR/codex-code-mode-host"
  verify_linux_elf_executable "$SOURCES/codex-code-mode-host" "Codex code mode host"
  local helper_binary_sha
  helper_binary_sha="$(sha256sum "$SOURCES/codex-code-mode-host" | awk '{print $1}')"
  ok "Codex code mode host binary SHA256: $helper_binary_sha"

  info "Rebuilding native modules for Electron linux-x64"
  local native_build="$WORK_DIR/native_build"
  mkdir -p "$native_build"
  python3 - "$native_build/package.json" "$better_sqlite3_version" "$node_pty_version" "$ELECTRON_REBUILD_VERSION" <<'PY'
import json
import sys
from pathlib import Path

out, better, pty, rebuild = sys.argv[1:]
payload = {
    "name": "codex-linux-x64-native-rebuild",
    "version": "1.0.0",
    "private": True,
    "dependencies": {
        "better-sqlite3": better,
        "node-pty": pty,
    },
    "devDependencies": {
        "@electron/rebuild": rebuild,
    },
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n")
PY
  (
    cd "$native_build"
    info "Installing native build dependencies"
    npm install --ignore-scripts
    info "Rebuilding native modules with Electron $electron_version"
    ./node_modules/.bin/electron-rebuild --version "$electron_version" --arch x64
  )
  copy_rebuilt_native_outputs "better-sqlite3" "$native_build" "$SOURCES/app.asar.unpacked"
  copy_rebuilt_native_outputs "node-pty" "$native_build" "$SOURCES/app.asar.unpacked"
  sanitize_native_module_outputs "$SOURCES/app.asar.unpacked"
  verify_linux_native_outputs "$SOURCES/app.asar.unpacked"

  write_build_info "$SOURCES/build-info.json" "$electron_version" "$dmg_sha" "$cli_sha" "$cli_binary_sha" "$helper_sha" "$helper_binary_sha" "$code_mode_host_required" "$app_version"

  info "Building and installing user Flatpak"
  flatpak-builder --force-clean --user --install "$ROOT/build-dir" "$ROOT/${APP_ID}.yml"
  ok "Flatpak installed"
  printf '\nRun with:\n  flatpak run --user %s\n\n' "$APP_ID"
}

if [ "${CODEX_TEST_DOWNLOAD:-}" = "1" ]; then
  require curl sha256sum
  test_dir="$(mktemp -d)"
  test_source="$ROOT/packaging/com.openai.CodexLinuxX64.desktop"
  test_expected="$(sha256sum "$test_source" | awk '{print $1}')"
  CODEX_NONINTERACTIVE=1 CODEX_REFRESH_DOWNLOADS=0 \
    download_verified "file://$test_source" "$test_dir/asset" "$test_expected"
  printf 'partial-cache' >"$test_dir/asset"
  CODEX_NONINTERACTIVE=1 CODEX_REFRESH_DOWNLOADS=0 \
    download_verified "file://$test_source" "$test_dir/asset" "$test_expected"
  cmp -s "$test_source" "$test_dir/asset" || die "Corrupt-cache recovery test failed"
  if ( CODEX_FORCE_DOWNLOAD=1 CODEX_NONINTERACTIVE=1 download \
    "file://$test_dir/missing" "$test_dir/failed" ); then
    die "Failed download test unexpectedly succeeded"
  fi
  [ ! -e "$test_dir/failed" ] || die "Failed download left a final output file"
  ! find "$test_dir" -maxdepth 1 -name 'asset.part.*' -print -quit | grep -q . ||
    die "Successful download left a temporary file"
  rm -rf "$test_dir"
  printf 'atomic download and corrupt-cache recovery passed\n'
  exit 0
fi

if [ "${CODEX_TEST_RESOLVE_CLI:-}" = "1" ]; then
  resolve_codex_release_assets
  printf 'CODEX_RELEASE_TAG=%s\n' "$CODEX_RELEASE_TAG"
  printf 'CODEX_CLI_URL=%s\n' "$CODEX_CLI_URL"
  printf 'CODEX_CLI_SHA256=%s\n' "$CODEX_CLI_SHA256"
  printf 'CODEX_CODE_MODE_HOST_URL=%s\n' "$CODEX_CODE_MODE_HOST_URL"
  printf 'CODEX_CODE_MODE_HOST_SHA256=%s\n' "$CODEX_CODE_MODE_HOST_SHA256"
  exit 0
fi

main "$@"
