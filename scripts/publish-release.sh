#!/bin/bash
# 發佈 ./scripts/release.sh 建好的 tag：
#   打包 DMG → 產生 Sparkle appcast（簽章）→ push main 與 tag → 建立 GitHub Release（DMG + appcast.xml）
# 已安裝的 Mac 版 App 之後會從 Release 的 appcast.xml 收到更新（SUFeedURL 在 project.yml）。
#
#   ./scripts/publish-release.sh              發佈 HEAD 上的版本 tag
#   ./scripts/publish-release.sh --testflight 之後一併上傳 iOS / iPadOS 到 TestFlight
#   ./scripts/publish-release.sh --yes        不再確認（push 與發佈是對外的動作，預設會問）
#
# 第一次使用前：./scripts/sparkle-tools.sh generate-keys，把印出的公鑰填進 project.yml 的 SPARKLE_PUBLIC_ED_KEY。
set -euo pipefail

cd "$(dirname "$0")/.."

TESTFLIGHT=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --testflight) TESTFLIGHT=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "不認得的參數：$arg" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }

# MARK: 檢查

TAG=$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null) || die "HEAD 不是版本 tag：先跑 ./scripts/release.sh"
VERSION=${TAG#v}
[[ -z "$(git status --porcelain)" ]] || die "工作目錄不乾淨"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "請在 main 上發佈"
PROJECT_VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml)
[[ "$PROJECT_VERSION" == "$VERSION" ]] || die "project.yml 的 MARKETING_VERSION（${PROJECT_VERSION}）與 tag（${VERSION}）不同"
grep -qE '^ *SPARKLE_PUBLIC_ED_KEY: "[^"]+"' project.yml \
  || die "project.yml 的 SPARKLE_PUBLIC_ED_KEY 是空的：./scripts/sparkle-tools.sh generate-keys"
gh release view "$TAG" >/dev/null 2>&1 && die "GitHub Release ${TAG} 已經存在"

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
if [[ $ASSUME_YES == 0 ]]; then
  echo "即將發佈 ${TAG}："
  echo "  1. 打包 DMG、簽章 appcast"
  echo "  2. git push origin main ${TAG}"
  echo "  3. 在 ${REPO} 建立 Release（DMG + appcast.xml）"
  [[ $TESTFLIGHT == 1 ]] && echo "  4. 上傳 TestFlight"
  read -r -p "繼續？[y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || exit 1
fi

# MARK: 打包與 appcast

./scripts/make-dmg.sh
DMG="build/EasyNotes-${VERSION}.dmg"
[[ -f "$DMG" ]] || die "找不到 $DMG"

STAGING=build/appcast
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$DMG" "$STAGING/"
# 與 DMG 同檔名的 .md 會成為 Sparkle 更新視窗的說明
python3 scripts/changelog.py show "$VERSION" > "$STAGING/EasyNotes-${VERSION}.md"
cp "$STAGING/EasyNotes-${VERSION}.md" build/release-notes.md

"$(./scripts/sparkle-tools.sh path)/generate_appcast" \
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
  --embed-release-notes \
  "$STAGING"
[[ -f "$STAGING/appcast.xml" ]] || die "沒有產生 appcast.xml"

# MARK: 推送與 Release

git push origin main "$TAG"
gh release create "$TAG" "$DMG" "$STAGING/appcast.xml" \
  --title "EasyNotes ${VERSION}" \
  --notes-file build/release-notes.md \
  --verify-tag

echo "✓ 已發佈 $(gh release view "$TAG" --json url --jq .url)"

if [[ $TESTFLIGHT == 1 ]]; then
  ./scripts/upload-testflight.sh
fi
