#!/usr/bin/env bash
# =============================================================================
# generate-solaro-icon.sh — build Graphics/AppIcon.icns from Graphics/solaro.svg
# =============================================================================
# The committed `Graphics/AppIcon.icns` is what the app-bundle steps
# (tools/build-solaro-app-local.sh and .github/workflows/build.yml) copy into
# Solaro.app/Contents/Resources. Regenerate it with this script whenever the
# source SVG changes — CI runners don't carry an SVG rasteriser, so the .icns
# is checked in rather than built on the fly.
#
# Requires: rsvg-convert (brew install librsvg) + iconutil (macOS built-in).
# Usage:    ./tools/generate-solaro-icon.sh
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SVG="Graphics/solaro.svg"
OUT="Graphics/AppIcon.icns"

if [ ! -f "$SVG" ]; then
    echo "error: $SVG not found" >&2
    exit 1
fi
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert not found — install with 'brew install librsvg'" >&2
    exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: iconutil not found (macOS only)" >&2
    exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

# (filename, pixel size) — the standard macOS iconset matrix (16→512 @1x/@2x).
render() {
    local name="$1" size="$2"
    rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/$name"
}

render icon_16x16.png        16
render icon_16x16@2x.png      32
render icon_32x32.png         32
render icon_32x32@2x.png      64
render icon_128x128.png      128
render icon_128x128@2x.png   256
render icon_256x256.png      256
render icon_256x256@2x.png   512
render icon_512x512.png      512
render icon_512x512@2x.png  1024

iconutil -c icns "$ICONSET" -o "$OUT"
echo "[solaro-icon] wrote $OUT ($(du -h "$OUT" | cut -f1))"
