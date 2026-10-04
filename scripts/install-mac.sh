#!/bin/bash
# 本機快速更新：建置 macOS Release，直接取代 /Applications/EasyNotes.app 並重新開啟（不產生 DMG）。
# 只替換 App bundle；Vault（~/Documents/EasyNotes）與 App 資料不受影響。
# web/src 有改動時加 --web，先重新打包 CM6。
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--web" ]]; then
  (cd web && npm run build)
fi

DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Release/EasyNotes.app"
DEST=/Applications/EasyNotes.app

xcodegen generate --quiet

xcodebuild \
  -project EasyNotes.xcodeproj \
  -scheme EasyNotes \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build -quiet

# 正常結束（讓 App 存檔、送出上傳佇列），最多等 10 秒。
# 依路徑比對，避免抓到 iOS 模擬器裡同名的 EasyNotes
running() { pgrep -qf "^$DEST/Contents/MacOS/EasyNotes"; }
if running; then
  osascript -e 'tell application id "'"$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")"'" to quit' || true
  for _ in {1..20}; do running || break; sleep 0.5; done
  if running; then
    echo "EasyNotes 沒有結束，請手動關閉後重跑" >&2
    exit 1
  fi
fi

# 先放到旁邊再換上新的，複製失敗時還原
OLD=""
if [[ -d "$DEST" ]]; then
  OLD="$DEST.old-$$"
  mv "$DEST" "$OLD"
fi
if ditto "$APP" "$DEST"; then
  [[ -n "$OLD" ]] && rm -rf "$OLD"
else
  [[ -n "$OLD" ]] && mv "$OLD" "$DEST"
  echo "安裝失敗，已還原舊版" >&2
  exit 1
fi

open "$DEST"
echo "已更新 ${DEST}（$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist")）"
