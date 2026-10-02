#!/bin/bash
# 建置 iOS / iPadOS Release，上傳到 App Store Connect（TestFlight）。
# 帳號用 Xcode 已登入的 Apple ID（Xcode → Settings → Accounts）；簽章自動管理。
# Build 號碼每次自動遞增（時間戳），不需要改 project.yml。
# web/src 有改動時，先跑 (cd web && npm run build)。
#
#   ./scripts/upload-testflight.sh            # Archive + 上傳
#   ./scripts/upload-testflight.sh --export   # 只匯出 build/TestFlight/EasyNotes.ipa，不上傳
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION=upload
[[ "${1:-}" == "--export" ]] && DESTINATION=export

BUILD_NUMBER=$(date +%Y%m%d%H%M)
OUT=build/TestFlight
ARCHIVE="$OUT/EasyNotes.xcarchive"

rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen generate --quiet

xcodebuild archive \
  -project EasyNotes.xcodeproj \
  -scheme EasyNotes \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>$DESTINATION</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>SF553X26YR</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>testFlightInternalTestingOnly</key>
  <true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT" \
  -allowProvisioningUpdates \
  -quiet

VERSION=$(/usr/libexec/PlistBuddy -c "Print ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")
if [[ "$DESTINATION" == upload ]]; then
  echo "已上傳 $VERSION ($BUILD_NUMBER)；App Store Connect 處理完（約 5–15 分鐘）後 TestFlight 會通知。"
else
  echo "$OUT/EasyNotes.ipa — $VERSION ($BUILD_NUMBER)"
fi
