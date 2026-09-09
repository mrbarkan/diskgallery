#!/usr/bin/env bash
#
# Build a notarized, stapled DiskGallery.dmg for direct (non-App-Store) beta
# distribution. Archives Release, exports with Developer ID, notarizes via
# notarytool, staples, and packages a drag-to-Applications DMG.
#
# Prereqs (one time):
#   1. Developer ID Application cert in the login keychain (you have this).
#   2. A stored notarytool credential profile named "diskgallery":
#        xcrun notarytool store-credentials diskgallery \
#          --apple-id "you@example.com" \
#          --team-id "L26TPPMPF3" \
#          --password "<app-specific-password>"   # appleid.apple.com → App-Specific Passwords
#
# Usage:
#   Tools/build-beta-dmg.sh           # full build + notarize + staple + dmg
#   SKIP_NOTARIZE=1 Tools/build-beta-dmg.sh   # build + dmg only (local smoke test)
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="L26TPPMPF3"
SCHEME="DiskGallery"
APP_NAME="DiskGallery"
NOTARY_PROFILE="diskgallery"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
BUILD_NUMBER="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml | tail -1)"
DMG_DIR="$BUILD_DIR/release"
DMG="$DMG_DIR/$APP_NAME-$BUILD_NUMBER.dmg"
# Sparkle: the "latest" GitHub release hosts appcast.xml + the DMG.
RELEASES_REPO="mrbarkan/diskgallery"
SPARKLE_BIN="${SPARKLE_BIN:-$(ls -d ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)}"

echo "==> Regenerating project from project.yml"
xcodegen generate >/dev/null

echo "==> Archiving (Release, Developer ID, hardened runtime)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | tail -20

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist Tools/ExportOptions.plist \
  | tail -10

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Zipping for notarization"
  ZIP="$BUILD_DIR/$APP_NAME.zip"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

  echo "==> Submitting to notary service (waits for result)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling ticket"
  xcrun stapler staple "$APP"
fi

echo "==> Building DMG"
rm -rf "$DMG_DIR"; mkdir -p "$DMG_DIR"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vvv -t install "$APP" || true

echo "==> Signing DMG + writing appcast.xml (Sparkle)"
# generate_appcast signs with the EdDSA private key in the login keychain (generate_keys)
# and writes $DMG_DIR/appcast.xml pointing at the GitHub release asset below.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/build-$BUILD_NUMBER/" \
  "$DMG_DIR"

echo ""
echo "Done: $DMG"
echo "Publish (creates the release, uploads DMG + appcast; existing installs auto-update):"
echo "  gh release create build-$BUILD_NUMBER --repo $RELEASES_REPO --title \"DiskGallery beta $BUILD_NUMBER\" \"$DMG\" \"$DMG_DIR/appcast.xml\""
