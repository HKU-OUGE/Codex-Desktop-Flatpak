#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/build-x86_64-flatpak.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$TMP_DIR/latest.json" <<'JSON'
{
  "tag_name": "rust-v9.9.9",
  "draft": false,
  "prerelease": false,
  "assets": [
    {
      "name": "codex-x86_64-unknown-linux-musl.tar.gz",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "browser_download_url": "https://example.invalid/codex-x86_64-unknown-linux-musl.tar.gz"
    },
    {
      "name": "codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "browser_download_url": "https://example.invalid/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz"
    }
  ]
}
JSON

output="$(
  CODEX_TEST_RESOLVE_CLI=1 \
  CODEX_RELEASE_TAG=latest \
  CODEX_RELEASE_JSON="$TMP_DIR/latest.json" \
  bash "$SCRIPT"
)"

grep -qx 'CODEX_RELEASE_TAG=rust-v9.9.9' <<<"$output" || fail "latest stable tag was not resolved"
grep -qx 'CODEX_CLI_URL=https://example.invalid/codex-x86_64-unknown-linux-musl.tar.gz' <<<"$output" || fail "asset URL was not resolved from latest release"
grep -qx 'CODEX_CLI_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' <<<"$output" || fail "CLI digest was not resolved from latest release"
grep -qx 'CODEX_CODE_MODE_HOST_URL=https://example.invalid/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz' <<<"$output" || fail "code mode host URL was not resolved from same latest release"
grep -qx 'CODEX_CODE_MODE_HOST_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' <<<"$output" || fail "code mode host digest was not resolved from latest release"

cat >"$TMP_DIR/prerelease.json" <<'JSON'
{
  "tag_name": "rust-v9.9.10-beta.1",
  "draft": false,
  "prerelease": true,
  "assets": [
    {
      "name": "codex-x86_64-unknown-linux-musl.tar.gz",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "browser_download_url": "https://example.invalid/pre/codex-x86_64-unknown-linux-musl.tar.gz"
    },
    {
      "name": "codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "browser_download_url": "https://example.invalid/pre/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz"
    }
  ]
}
JSON

if CODEX_TEST_RESOLVE_CLI=1 CODEX_RELEASE_TAG=latest CODEX_RELEASE_JSON="$TMP_DIR/prerelease.json" bash "$SCRIPT" >/tmp/codex-prerelease-test.out 2>&1; then
  fail "prerelease fixture was accepted"
fi
grep -q 'not a stable release' /tmp/codex-prerelease-test.out || fail "prerelease rejection message was missing"

cat >"$TMP_DIR/missing-helper.json" <<'JSON'
{
  "tag_name": "rust-v9.9.11",
  "draft": false,
  "prerelease": false,
  "assets": [
    {
      "name": "codex-x86_64-unknown-linux-musl.tar.gz",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "browser_download_url": "https://example.invalid/codex-x86_64-unknown-linux-musl.tar.gz"
    }
  ]
}
JSON

if CODEX_TEST_RESOLVE_CLI=1 CODEX_RELEASE_TAG=latest CODEX_RELEASE_JSON="$TMP_DIR/missing-helper.json" bash "$SCRIPT" >/tmp/codex-missing-helper-test.out 2>&1; then
  fail "release without code mode host was accepted"
fi
grep -q 'missing asset codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz' /tmp/codex-missing-helper-test.out ||
  fail "missing helper rejection message was missing"

grep -Fq 'codex-code-mode-host' "$ROOT/com.openai.CodexLinuxX64.yml" ||
  fail "manifest must package codex-code-mode-host"
grep -Fq 'install -m755 codex-code-mode-host /app/lib/codex/resources/codex-code-mode-host' "$ROOT/com.openai.CodexLinuxX64.yml" ||
  fail "manifest must install helper into resources"
! grep -Fq "*/Codex.app/Contents/Resources" "$SCRIPT" ||
  fail "build script must not hard-code Codex.app resource path"
grep -Fq 'find_app_resources' "$SCRIPT" ||
  fail "build script must locate resources by app.asar and app.asar.unpacked"
grep -Fq 'verify_linux_elf_executable' "$SCRIPT" ||
  fail "build script must validate Linux ELF helper/CLI binaries"
grep -Fq 'sanitize_native_module_outputs' "$SCRIPT" ||
  fail "build script must remove Mach-O native outputs from Linux runtime paths"
grep -Fq 'write_resized_png_icon' "$SCRIPT" ||
  fail "build script must resize app icons to declared Flatpak icon sizes"
grep -Fq 'codexAppVersion' "$SCRIPT" ||
  fail "build info must record the bundled Codex Desktop version"
