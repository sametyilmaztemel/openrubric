#!/usr/bin/env bash
# Builds the OpenRubric .app bundle, signs it (Developer ID when provided,
# ad-hoc otherwise), and packages a distributable DMG.
#
#   ./scripts/build-dmg.sh [output-dir]
#
# Environment (all optional, read from CI secrets or a local env file):
#   APPLE_IDENTITY     Developer ID Application certificate name. When set
#                       the app is signed for distribution; when absent an
#                       ad-hoc signature is used (local builds).
#   APPLE_ID           Apple ID for notarization (only used with identity).
#   APPLE_APP_PASSWORD  App-specific password for notarization.
#   APPLE_TEAM_ID      Team ID (required for notarization).
set -euo pipefail

OUT_DIR="${1:-dist}"
APP_NAME="OpenRubric"
APP="$OUT_DIR/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo dev)"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"

echo "==> swift build (release)"
swift build -c release --product "$APP_NAME"

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> assemble .app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> sign"
if [ -n "${APPLE_IDENTITY:-}" ]; then
  codesign --force --sign "$APPLE_IDENTITY" --options runtime     --timestamp=verified "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo "==> DMG"
# Stage the bundle in its own parent directory: `hdiutil -srcfolder` copies
# the *contents* of the given folder to the volume root, so pointing it at
# OpenRubric.app directly would drop a loose Contents/ folder onto the
# volume instead of an OpenRubric.app item.
rm -rf "$OUT_DIR/stage"
mkdir -p "$OUT_DIR/stage"
cp -R "$APP" "$OUT_DIR/stage/"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT_DIR/stage" -ov   -format UDZO "$DMG"

if [ -n "${APPLE_IDENTITY:-}" ] && [ -n "${APPLE_ID:-}" ] &&    [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  echo "==> notarize"
  xcrun notarytool submit "$DMG"     --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD"     --team-id "$APPLE_TEAM_ID" --wait
  xcrun notarytool staple "$DMG"
else
  echo "==> notarization skipped (no APPLE_ID/APP_PASSWORD/TEAM_ID)"
fi

echo "==> done: $DMG"
