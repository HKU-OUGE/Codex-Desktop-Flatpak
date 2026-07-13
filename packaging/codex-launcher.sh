#!/usr/bin/env bash
set -euo pipefail

export ELECTRON_IS_DEV=0
export ELECTRON_RENDERER_URL="file:///app/lib/codex/resources/app.asar/webview/index.html"
export CODEX_HOME="${CODEX_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/codex}"
export CODEX_CLI_PATH="/app/lib/codex/resources/codex"
mkdir -p "$CODEX_HOME"

electron_args=(--no-sandbox --log-level=3)

if [ -n "${CODEX_FLATPAK_PROXY:-}" ]; then
  electron_args+=("--proxy-server=$CODEX_FLATPAK_PROXY")
  if [ -n "${CODEX_FLATPAK_PROXY_BYPASS:-}" ]; then
    electron_args+=("--proxy-bypass-list=${CODEX_FLATPAK_PROXY_BYPASS//,/;}")
  fi
fi

scale_factor="${CODEX_FLATPAK_SCALE:-}"
if [ -n "$scale_factor" ]; then
  [[ "$scale_factor" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "Unsupported CODEX_FLATPAK_SCALE=$scale_factor; expected a number such as 1.25 or 2" >&2
    exit 64
  }
  electron_args+=(--high-dpi-support=1 "--force-device-scale-factor=$scale_factor")
fi

renderer_mode="${CODEX_FLATPAK_RENDERER:-swiftshader}"
[ "${CODEX_FLATPAK_ENABLE_GPU:-}" = "1" ] && renderer_mode=gpu
case "$renderer_mode" in
  gpu) ;;
  swiftshader)
    electron_args+=(--use-gl=swiftshader --use-angle=swiftshader --enable-unsafe-swiftshader
      --disable-gpu-rasterization --disable-accelerated-2d-canvas --disable-zero-copy
      --disable-lcd-text --font-render-hinting=medium
      --disable-features=UseSkiaRenderer,Vulkan,CanvasOopRasterization)
    ;;
  software)
    electron_args+=(--disable-gpu --disable-gpu-compositing --disable-gpu-rasterization
      --disable-accelerated-2d-canvas --disable-zero-copy --disable-lcd-text
      --font-render-hinting=medium --disable-features=UseSkiaRenderer,Vulkan,CanvasOopRasterization)
    ;;
  safe)
    electron_args+=(--disable-gpu-rasterization --disable-accelerated-2d-canvas --disable-zero-copy
      --disable-lcd-text --font-render-hinting=medium
      --disable-features=UseSkiaRenderer,Vulkan,CanvasOopRasterization)
    ;;
  *)
    echo "Unsupported CODEX_FLATPAK_RENDERER=$renderer_mode; expected swiftshader, safe, gpu, or software" >&2
    exit 64
    ;;
esac

exec /app/lib/codex/electron "${electron_args[@]}" /app/lib/codex/resources/app.asar "$@"
