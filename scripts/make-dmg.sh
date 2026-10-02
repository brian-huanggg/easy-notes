#!/bin/bash
# 建置 macOS Release，打包成 build/EasyNotes-<版本>.dmg（拖到「應用程式」安裝）。
# 簽章沿用 project.yml（Apple Development、個人團隊），沒有公證：只適合裝在自己註冊過的 Mac。
# web/src 有改動時，先跑 (cd web && npm run build)。
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
  build -quiet

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/EasyNotes-$VERSION.dmg"

# DMG 內容：App + 指向 /Applications 的捷徑
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
diskutil image create from --format ULFO --volumeName EasyNotes "$STAGING" "$DMG" >/dev/null

echo "$DMG"
