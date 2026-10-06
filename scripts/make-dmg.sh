#!/bin/bash
# Builds the macOS Release and packages it as build/EasyNotes-<version>.dmg (drag to Applications to install).
# Signing follows project.yml (Apple Development, personal team) without notarization: only for Macs you registered.
# The build number is a timestamp (Sparkle uses it to order versions, so it must increase; same as upload-testflight.sh).
# After changing web/src, run (cd web && pnpm build) first. Releases use ./scripts/publish-release.sh, which calls this.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Release/EasyNotes.app"

xcodegen generate --quiet

xcodebuild \
  -project EasyNotes.xcodeproj \
  -scheme EasyNotes \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  build -quiet

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/EasyNotes-$VERSION.dmg"

# DMG contents: the app plus a link to /Applications
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
diskutil image create from --format ULFO --volumeName EasyNotes "$STAGING" "$DMG" >/dev/null

# Sizes (for the release size log)
mb() { awk -v k="$1" 'BEGIN { printf "%.1f MB", k / 1024 }'; }
echo "DMG    $(mb $(( $(stat -f%z "$DMG") / 1024 )))"
echo ".app   $(mb "$(du -sk "$APP" | cut -f1)")"
echo "Binary $(mb "$(du -sk "$APP/Contents/MacOS/EasyNotes" | cut -f1)")"
echo "$DMG"
