#!/bin/bash
# 準備發版（只動本機：不 build、不 push）：
#   測試 → Changelog → App 內的「新功能」內容 → MARKETING_VERSION → commit → tag
# 之後用 ./scripts/publish-release.sh 打包、推送、建立 GitHub Release 與 Sparkle 更新。
#
#   ./scripts/release.sh                 版本號依 commit 類型決定（feat → minor、fix → patch、`!` → major）
#   ./scripts/release.sh 1.3.0           指定版本號
#   ./scripts/release.sh minor           patch / minor / major
#   ./scripts/release.sh --dry-run       只印出版本號與 Changelog 區塊，不改任何檔案
#   ./scripts/release.sh --skip-tests    略過測試（check-l10n、web、EasyNotesCore）
#
# Changelog 內容來自上個 tag 以來的 feat / fix / perf / security commit（cliff.toml）。
# 想手寫的版本：發版前在 docs/Changelog.md 放一個 `## [Unreleased]` 區塊，會直接改名成這個版本，不再產生。
set -euo pipefail

cd "$(dirname "$0")/.."

CHANGELOG=docs/Changelog.md
WHATS_NEW=App/Resources/WhatsNew.json
cliff() { npx --no-install git-cliff --config cliff.toml "$@" 2>/dev/null; }

DRY_RUN=0
SKIP_TESTS=0
REQUEST=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -*) echo "不認得的參數：$arg" >&2; exit 2 ;;
    *) REQUEST="$arg" ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }

# MARK: 版本號

CURRENT=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml)
[[ -n "$CURRENT" ]] || die "project.yml 找不到 MARKETING_VERSION"

bump() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$CURRENT"
  case "$1" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
  esac
}

case "$REQUEST" in
  "") VERSION=$(cliff --bumped-version); VERSION=${VERSION#v} ;;
  major|minor|patch) VERSION=$(bump "$REQUEST") ;;
  *) VERSION=${REQUEST#v} ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本號格式要像 1.2.3（得到「${VERSION}」）"
TAG="v$VERSION"

# MARK: 檢查

if [[ $DRY_RUN == 0 ]]; then
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "請在 main 上發版"
  [[ -z "$(git status --porcelain)" ]] || die "工作目錄不乾淨，先 commit 或 stash"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag ${TAG} 已經存在"
LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
[[ -n "$LAST_TAG" && "${LAST_TAG#v}" == "$VERSION" ]] && die "${VERSION} 已經是最新的 tag"

# MARK: Changelog 區塊

if python3 scripts/changelog.py has-unreleased; then
  SOURCE="手寫的 [Unreleased]"
  BLOCK=""
else
  SOURCE="${LAST_TAG}..HEAD 的 commit"
  BLOCK=$(cliff --unreleased --tag "$TAG")
  grep -q '^- ' <<<"$BLOCK" || die "${SOURCE} 沒有 feat / fix / perf / security，沒有東西可以發版"
fi

echo "版本  ${CURRENT} → ${VERSION}（${SOURCE}）"
if [[ $DRY_RUN == 1 ]]; then
  [[ -n "$BLOCK" ]] && { echo; echo "$BLOCK"; } || sed -n '/^## \[Unreleased\]/,/^## \[/p' "$CHANGELOG" | sed '$d'
  exit 0
fi

# MARK: 測試

if [[ $SKIP_TESTS == 0 ]]; then
  ./scripts/check-l10n.py
  python3 scripts/test_changelog.py
  (cd web && npm test)
  (cd Packages/EasyNotesCore && swift test)
fi

# MARK: 寫入

if [[ -z "$BLOCK" ]]; then
  python3 scripts/changelog.py promote "$VERSION"
else
  python3 scripts/changelog.py insert <<<"$BLOCK"
fi
python3 scripts/changelog.py show "$VERSION" --format json > "$WHATS_NEW"

sed -i '' -E "s/^( *MARKETING_VERSION: \")[^\"]*(\")/\1$VERSION\2/" project.yml
xcodegen generate --quiet

git add "$CHANGELOG" "$WHATS_NEW" project.yml EasyNotes.xcodeproj
git commit -q -m "chore(release): $TAG"
git tag -a "$TAG" -m "EasyNotes $VERSION"

echo "✓ 已建立 commit 與 tag ${TAG}（尚未 push）"
echo "  下一步：./scripts/publish-release.sh   （--testflight 一併上傳 iOS / iPadOS）"
