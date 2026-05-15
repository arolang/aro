#!/usr/bin/env bash
# Compile MLX Metal shaders into default.metallib
# Run after `swift build` to enable native MLX inference in `aro ask`.
#
# Usage: tools/build-metallib.sh [release|debug]

set -euo pipefail

MODE="${1:-release}"
METAL_DIR=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
BUNDLE_DIR=".build/${MODE}/mlx-swift_Cmlx.bundle"

if [ ! -d "$METAL_DIR" ]; then
    echo "Metal sources not found at $METAL_DIR"
    echo "Run 'swift build -c $MODE' first to fetch dependencies."
    exit 1
fi

mkdir -p "$BUNDLE_DIR"

# Check if metallib is already up-to-date
if [ -f "$BUNDLE_DIR/default.metallib" ]; then
    NEWEST_METAL=$(find "$METAL_DIR" -name "*.metal" -newer "$BUNDLE_DIR/default.metallib" 2>/dev/null | head -1)
    if [ -z "$NEWEST_METAL" ]; then
        echo "default.metallib is up-to-date."
        exit 0
    fi
fi

echo "Compiling Metal shaders..."

AIR_FILES=()
for f in "$METAL_DIR"/*.metal "$METAL_DIR"/steel/attn/kernels/*.metal; do
    [ -f "$f" ] || continue
    BASE=$(basename "$f" .metal)
    xcrun metal -c -target air64-apple-macos15.0 \
        -I"$METAL_DIR" \
        -fno-fast-math \
        "$f" -o "/tmp/mlx_${BASE}.air" 2>/dev/null
    AIR_FILES+=("/tmp/mlx_${BASE}.air")
done

xcrun metallib "${AIR_FILES[@]}" -o "$BUNDLE_DIR/default.metallib"

# Clean up .air files
rm -f /tmp/mlx_*.air

SIZE=$(ls -lh "$BUNDLE_DIR/default.metallib" | awk '{print $5}')
echo "Built default.metallib (${SIZE}) → ${BUNDLE_DIR}/"
