#!/usr/bin/env bash
#
# package-solaro-dmg.sh — sign, notarize, staple and package Solaro.app
# into a distributable DMG (#268).
#
# The same script runs in CI and on a developer's machine, because a
# release path that only exists inside a YAML file is a release path
# nobody can debug. Every step is skippable: with no signing identity
# it still produces an (unsigned, gatekept) DMG so the packaging
# itself can be tested without credentials.
#
# Usage:
#   Scripts/package-solaro-dmg.sh --app path/to/Solaro.app [options]
#
# Options:
#   --app PATH         Solaro.app to package                (required)
#   --out PATH         Output .dmg  (default: solaro-macos-arm64.dmg)
#   --version STRING   Version shown as the volume name     (default: dev)
#   --identity NAME    codesign identity or SHA-1           (default: $APPLE_SIGNING_IDENTITY)
#   --team-id ID       Apple Developer Team ID              (default: $APPLE_TEAM_ID)
#   --apple-id EMAIL   Notary account                       (default: $APPLE_ID)
#   --password PW      App-specific password                (default: $APPLE_APP_PASSWORD)
#   --skip-notarize    Sign and package, don't notarize
#   --skip-app-signing App is already signed + stapled; only build,
#                      sign and notarize the DMG around it (CI path)
#
# The Team ID is what SOLARO's Settings → Signing panel configures;
# it prints an `APPLE_TEAM_ID=…` line ready to paste into CI secrets.
#
# Notarization needs a **Developer ID Application** certificate.
# Apple Development / Apple Distribution certificates sign fine and
# are then rejected by the notary after upload — the script checks
# for this up front instead of failing at the end of a release.

set -euo pipefail

APP=""
OUT="solaro-macos-arm64.dmg"
VERSION="dev"
IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_ID_ACCOUNT="${APPLE_ID:-}"
APP_PASSWORD="${APPLE_APP_PASSWORD:-}"
SKIP_NOTARIZE=0
SKIP_APP_SIGNING=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-app-signing) SKIP_APP_SIGNING=1; shift ;;
    --app)            APP="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --version)        VERSION="$2"; shift 2 ;;
    --identity)       IDENTITY="$2"; shift 2 ;;
    --team-id)        TEAM_ID="$2"; shift 2 ;;
    --apple-id)       APPLE_ID_ACCOUNT="$2"; shift 2 ;;
    --password)       APP_PASSWORD="$2"; shift 2 ;;
    --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
    -h|--help)        sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$APP" ]; then
  echo "error: --app is required" >&2
  exit 2
fi
if [ ! -d "$APP" ]; then
  echo "error: $APP is not an app bundle" >&2
  exit 2
fi

say() { printf '\n==> %s\n' "$1"; }

# ---------------------------------------------------------------------
# 1. Sign the bundle
# ---------------------------------------------------------------------
if [ "$SKIP_APP_SIGNING" -eq 1 ]; then
  say "Skipping app signing — $APP is expected to be signed and stapled"
  if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "note: $APP has no stapled notarization ticket." >&2
  fi
elif [ -n "$IDENTITY" ]; then
  say "Signing $APP as $IDENTITY"

  ENTITLEMENTS="$(mktemp -t solaro-entitlements).plist"
  cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict>
</plist>
PLIST

  # Inside-out: nested code first, bundle last, or the outer
  # signature is invalidated by signing what it contains.
  while IFS= read -r nested; do
    codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$nested"
  done < <(find "$APP/Contents" -type f -perm -111 ! -path "*/MacOS/Solaro" 2>/dev/null || true)

  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP/Contents/MacOS/Solaro"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  rm -f "$ENTITLEMENTS"

  # Warn early if this certificate cannot notarize.
  if ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "warning: $APP is not signed by a Developer ID Application certificate;" >&2
    echo "         Apple's notary will reject it. Shipping unnotarized." >&2
    SKIP_NOTARIZE=1
  fi
else
  say "No signing identity — packaging $APP unsigned"
  SKIP_NOTARIZE=1
fi

# ---------------------------------------------------------------------
# 2. Notarize + staple the app
# ---------------------------------------------------------------------
if [ "$SKIP_NOTARIZE" -eq 0 ] && [ "$SKIP_APP_SIGNING" -eq 0 ]; then
  if [ -z "$APPLE_ID_ACCOUNT" ] || [ -z "$TEAM_ID" ] || [ -z "$APP_PASSWORD" ]; then
    echo "warning: APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD not all set —" >&2
    echo "         skipping notarization (the DMG will be signed but gatekept)." >&2
  else
    say "Notarizing $APP (team $TEAM_ID)"
    ZIP="$(dirname "$APP")/$(basename "$APP").zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    SUBMIT_OUT=$(xcrun notarytool submit "$ZIP" \
      --apple-id "$APPLE_ID_ACCOUNT" \
      --team-id "$TEAM_ID" \
      --password "$APP_PASSWORD" \
      --wait 2>&1) || true
    echo "$SUBMIT_OUT"
    rm -f "$ZIP"
    STATUS=$(echo "$SUBMIT_OUT" | awk -F': ' '/status:/ { s=$2 } END { print s }')
    SUBMIT_ID=$(echo "$SUBMIT_OUT" | awk -F': ' '/id:/ { print $2; exit }')
    if [ "$STATUS" = "Accepted" ]; then
      xcrun stapler staple "$APP"
    else
      echo "warning: notarization status ${STATUS:-unknown} — shipping unstapled." >&2
      if [ -n "$SUBMIT_ID" ]; then
        xcrun notarytool log "$SUBMIT_ID" \
          --apple-id "$APPLE_ID_ACCOUNT" --team-id "$TEAM_ID" \
          --password "$APP_PASSWORD" || true
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------
# 3. Build the DMG
# ---------------------------------------------------------------------
say "Building $OUT"
STAGING="$(mktemp -d -t solaro-dmg)"
cp -R "$APP" "$STAGING/"
# The drag-to-install affordance every macOS user expects. Without
# it people run the app from the mounted image, which then can't
# update itself and confuses every path the app resolves.
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create \
  -volname "Solaro $VERSION" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$OUT"
rm -rf "$STAGING"

# ---------------------------------------------------------------------
# 4. Sign + notarize the DMG itself
# ---------------------------------------------------------------------
# Gatekeeper checks the disk image the user downloads, not just the
# app inside it. An unsigned DMG wrapping a notarized app still
# throws the "cannot be opened" dialog on first download.
if [ -n "$IDENTITY" ]; then
  say "Signing $OUT"
  codesign --force --timestamp --sign "$IDENTITY" "$OUT"

  if [ "$SKIP_NOTARIZE" -eq 0 ] && [ -n "$APPLE_ID_ACCOUNT" ] \
     && [ -n "$TEAM_ID" ] && [ -n "$APP_PASSWORD" ]
  then
    say "Notarizing $OUT"
    SUBMIT_OUT=$(xcrun notarytool submit "$OUT" \
      --apple-id "$APPLE_ID_ACCOUNT" \
      --team-id "$TEAM_ID" \
      --password "$APP_PASSWORD" \
      --wait 2>&1) || true
    echo "$SUBMIT_OUT"
    STATUS=$(echo "$SUBMIT_OUT" | awk -F': ' '/status:/ { s=$2 } END { print s }')
    if [ "$STATUS" = "Accepted" ]; then
      xcrun stapler staple "$OUT"
      xcrun stapler validate "$OUT"
    else
      echo "warning: DMG notarization status ${STATUS:-unknown}." >&2
    fi
  fi
fi

say "Done"
ls -lh "$OUT"
# Report what a downloader will actually see.
spctl -a -t open --context context:primary-signature -vv "$OUT" 2>&1 || true
