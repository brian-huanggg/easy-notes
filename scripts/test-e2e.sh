#!/bin/bash
# E2E（XCUITest）：從外部操作 App，並以磁碟上的檔案驗證結果。測試程式在 Tests/E2E。
#
#   ./scripts/test-e2e.sh [smoke|sync|perf|all] [mac|ipad] [--ci]
#
#   smoke  開啟 Vault、新增 / 改名 / 搬移 / 釘選 / 刪除、外部修改、各類型開啟、搜尋、重建索引（預設）
#   sync   兩台裝置的同步：App 與測試程序共用資料夾 backend（不需要 Docker 或網路）
#   perf   啟動、1,000 元素白板、打字、外部一次改 50 個檔案（EASYNOTES_E2E_PERF=1）
#   all    以上全部
#   mac    macOS（預設）；ipad 用 iPad 模擬器（IPAD_SIMULATOR 可指定機型）
#   --ci   不用開發者憑證簽署（GitHub Actions 等沒有登入 Apple ID 的機器）
#
# 結果在 build/E2E-<suite>-<dest>.xcresult（含失敗時的截圖與錄影），用 Xcode 開啟。
# 執行期間不要操作滑鼠鍵盤（XCUITest 送的是真實的輸入事件）；macOS 測試會自動切到 ABC 輸入法並在結束後還原。
# 第一次在 macOS 執行時，系統會要求允許「Xcode Helper」/ 終端機控制電腦（輔助使用）。
set -euo pipefail

cd "$(dirname "$0")/.."

SUITE=smoke
DEST=mac
CI=0
for arg in "$@"; do
  case "$arg" in
    smoke|sync|perf|all) SUITE=$arg ;;
    mac|ipad) DEST=$arg ;;
    --ci) CI=1 ;;
    *) echo "用法：$0 [smoke|sync|perf|all] [mac|ipad] [--ci]" >&2; exit 2 ;;
  esac
done

TARGET=EasyNotesE2ETests
SMOKE=(LaunchTests DocumentLifecycleTests ExternalChangeTests KindTests NavigationTests IndexRebuildTests)
case "$SUITE" in
  smoke) CLASSES=("${SMOKE[@]}") ;;
  sync) CLASSES=(SyncTests) ;;
  perf) CLASSES=(PerformanceTests) ;;
  all) CLASSES=("${SMOKE[@]}" SyncTests PerformanceTests) ;;
esac
ONLY=()
for c in "${CLASSES[@]}"; do ONLY+=("-only-testing:$TARGET/$c"); done

# 傳給測試程序的環境變數要加 TEST_RUNNER_ 前綴
if [[ "$SUITE" == perf || "$SUITE" == all ]]; then
  export TEST_RUNNER_EASYNOTES_E2E_PERF=1
fi

case "$DEST" in
  mac) DESTINATION='platform=macOS' ;;
  ipad) DESTINATION="platform=iOS Simulator,name=${IPAD_SIMULATOR:-iPad Pro 13-inch (M4)}" ;;
esac

SIGNING=()
if [[ $CI == 1 ]]; then
  if [[ "$DEST" == mac ]]; then
    # ad-hoc 簽署；拿掉 Sign in with Apple 的 entitlement（沒有描述檔時 macOS 不讓 App 啟動，E2E 也不登入）
    SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER=)
  else
    SIGNING=(CODE_SIGNING_ALLOWED=NO)
  fi
fi

RESULT="build/E2E-$SUITE-$DEST.xcresult"
rm -rf "$RESULT"
mkdir -p build

xcodegen generate --quiet

xcodebuild test \
  -project EasyNotes.xcodeproj \
  -scheme EasyNotes \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath build/DerivedData-E2E \
  -resultBundlePath "$RESULT" \
  "${ONLY[@]}" \
  ${SIGNING[@]+"${SIGNING[@]}"}
