#!/bin/bash
# Prepares a release (local only: no build, no push):
#   tests → Changelog → in-app "What's New" content → MARKETING_VERSION → commit → tag
# Then ./scripts/publish-release.sh packages, pushes, and creates the GitHub Release and Sparkle update.
#
#   ./scripts/release.sh                 version from commit types (feat → minor, fix → patch, `!` → major)
#   ./scripts/release.sh 1.3.0           explicit version
#   ./scripts/release.sh minor           patch / minor / major
#   ./scripts/release.sh --dry-run       print the version and Changelog block only; change no files
#   ./scripts/release.sh --skip-tests    skip tests (check-l10n, web, EasyNotesCore)
#
# The Changelog comes from feat / fix / perf / security commits since the last tag (cliff.toml).
# To hand-write a version, add a `## [Unreleased]` block to docs/Changelog.md first; it is renamed, not regenerated.
set -euo pipefail

cd "$(dirname "$0")/.."

CHANGELOG=docs/Changelog.md
WHATS_NEW=App/Resources/WhatsNew.json
cliff() { pnpm exec git-cliff --config cliff.toml "$@" 2>/dev/null; }

DRY_RUN=0
SKIP_TESTS=0
REQUEST=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -*) echo "Unknown argument: $arg" >&2; exit 2 ;;
    *) REQUEST="$arg" ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }

# MARK: Dependencies (git-cliff and web tests; --frozen-lockfile installs from the lockfile without changing it. Root and web share one pnpm workspace)

pnpm install --frozen-lockfile --silent

# MARK: Version

CURRENT=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml)
[[ -n "$CURRENT" ]] || die "MARKETING_VERSION not found in project.yml"

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
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must look like 1.2.3 (got \"${VERSION}\")"
TAG="v$VERSION"

# MARK: Checks

if [[ $DRY_RUN == 0 ]]; then
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "Release from main"
  [[ -z "$(git status --porcelain)" ]] || die "Working tree is not clean: commit or stash first"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "Tag ${TAG} already exists"
LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
[[ -n "$LAST_TAG" && "${LAST_TAG#v}" == "$VERSION" ]] && die "${VERSION} is already the latest tag"

# MARK: Changelog block

if python3 scripts/changelog.py has-unreleased; then
  SOURCE="hand-written [Unreleased]"
  BLOCK=""
else
  SOURCE="commits in ${LAST_TAG}..HEAD"
  BLOCK=$(cliff --unreleased --tag "$TAG")
  grep -q '^- ' <<<"$BLOCK" || die "${SOURCE}: no feat / fix / perf / security, nothing to release"
fi

echo "Version  ${CURRENT} → ${VERSION} (${SOURCE})"
if [[ $DRY_RUN == 1 ]]; then
  [[ -n "$BLOCK" ]] && { echo; echo "$BLOCK"; } || sed -n '/^## \[Unreleased\]/,/^## \[/p' "$CHANGELOG" | sed '$d'
  exit 0
fi

# MARK: Tests

if [[ $SKIP_TESTS == 0 ]]; then
  ./scripts/check-l10n.py
  python3 scripts/test_changelog.py
  (cd web && pnpm test)
  (cd Packages/EasyNotesCore && swift test)
fi

# MARK: Write

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

echo "✓ Created commit and tag ${TAG} (not pushed)"
echo "  Next: ./scripts/publish-release.sh   (includes TestFlight; --skip-testflight for the Mac release only)"
