#!/bin/bash
# 建置 macOS Release，打包成 build/EasyNotes-<版本>.dmg（拖到「應用程式」安裝）。
# 簽章沿用 project.yml（Apple Development、個人團隊），沒有公證：只適合裝在自己註冊過的 Mac。
# Build 號碼用時間戳（Sparkle 靠它判斷哪個版本比較新，必須遞增；與 upload-testflight.sh 相同）。
# web/src 有改動時，先跑 (cd web && npm run build)。發版用 ./scripts/publish-release.sh（會呼叫這支）。
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

# DMG 內容：App + 指向 /Applications 的捷徑
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
diskutil image create from --format ULFO --volumeName EasyNotes "$STAGING" "$DMG" >/dev/null

# 大小（記到 docs/Roadmap.md 的「版本體積紀錄」）
mb() { awk -v k="$1" 'BEGIN { printf "%.1f MB", k / 1024 }'; }
echo "DMG    $(mb $(( $(stat -f%z "$DMG") / 1024 )))"
echo ".app   $(mb "$(du -sk "$APP" | cut -f1)")"
echo "執行檔 $(mb "$(du -sk "$APP/Contents/MacOS/EasyNotes" | cut -f1)")"
echo "$DMG"
