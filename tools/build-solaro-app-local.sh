#!/usr/bin/env bash
# =============================================================================
# build-solaro-app-local.sh — assemble a local Solaro.app for dev use.
# =============================================================================
# CI uses its own packaging step (see .github/workflows/build.yml). This
# script is for local development: build the Solaro executable + launcher,
# wrap the binary in a minimal .app bundle, and stage it under .build/ so
# the `solaro` launcher can find it via SOLARO_APP=.
#
# Usage:
#   ./tools/build-solaro-app-local.sh [release|debug]
#
# Outputs:
#   .build/Solaro.app/...
#   .build/<config>/solaro       (the launcher CLI)
# =============================================================================

set -euo pipefail

CONFIG="${1:-release}"
case "$CONFIG" in
    release) ;;
    debug) ;;
    *) echo "Usage: $0 [release|debug]" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "[solaro-app] swift build -c $CONFIG --product SolaroApp"
swift build -c "$CONFIG" --product SolaroApp

echo "[solaro-app] swift build -c $CONFIG --product solaro"
swift build -c "$CONFIG" --product solaro

# `aro ask`'s native MLX backend looks for `mlx.metallib` alongside the
# binary. SwiftPM doesn't compile .metal sources, so we shell out to the
# dedicated build script — first run only compiles, subsequent calls
# are no-ops because the metallib is cached.
if [ -d ".build/checkouts/mlx-swift" ]; then
    echo "[solaro-app] tools/build-metallib.sh $CONFIG"
    ./tools/build-metallib.sh "$CONFIG" 2>&1 | sed 's/^/[metallib] /'
fi

APP_DIR=".build/Solaro.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# Copy the SolaroApp binary into the .app under its user-facing
# name (Solaro). The product is named SolaroApp internally only
# to dodge SwiftPM's case-insensitive-fs collision with the
# launcher product `solaro`.
cp ".build/$CONFIG/SolaroApp" "$APP_DIR/Contents/MacOS/Solaro"
cp Sources/SOLARO/LICENSE-NOTICE.md "$APP_DIR/Contents/Resources/LICENSE-NOTICE.md"

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Solaro</string>
  <!-- CFBundleIdentifier intentionally keeps the SOLARO suffix even
       though the app is now called Solaro — changing the bundle ID
       would orphan every existing user's NSUserDefaults, Launch
       Services file association, and crash-report history. -->
  <key>CFBundleIdentifier</key><string>com.arolang.SOLARO</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Solaro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Tell Launch Services Solaro opens folders (ARO projects)
       and individual .aro source files (#277). Double-click in
       Finder routes through RootView.onOpenURL. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>ARO project folder</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
        <string>public.directory</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>ARO source file</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.arolang.aro-source</string>
      </array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.arolang.aro-source</string>
      <key>UTTypeDescription</key><string>ARO source file</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.source-code</string>
        <string>public.plain-text</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>aro</string></array>
        <key>public.mime-type</key>
        <array><string>text/x-aro</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Solaro deep link</string>
      <key>CFBundleURLSchemes</key>
      <array><string>solaro</string></array>
    </dict>
  </array>
</dict></plist>
PLIST

echo ""
echo "[solaro-app] Built: $(pwd)/$APP_DIR"
echo "[solaro-app] Launcher: $(pwd)/.build/$CONFIG/solaro"
echo ""
echo "Try it:"
echo "  export SOLARO_APP=\"$(pwd)/$APP_DIR\""
echo "  ./.build/$CONFIG/solaro ./Examples/HelloWorld"
