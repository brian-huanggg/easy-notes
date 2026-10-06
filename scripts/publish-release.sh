#!/bin/bash
# Publishes the tag created by ./scripts/release.sh:
#   build DMG → sign Sparkle appcast → push main and tag → create GitHub Release (DMG + appcast.xml)
#   → upload iOS / iPadOS to TestFlight
# Installed Mac apps then receive the update from the Release's appcast.xml (SUFeedURL is in project.yml).
#
#   ./scripts/publish-release.sh                   publish the version tag at HEAD
#   ./scripts/publish-release.sh --skip-testflight publish the Mac release only, no TestFlight upload
#   ./scripts/publish-release.sh --yes             skip the confirmation (pushing and publishing are outward-facing)
#
# Before the first use: run ./scripts/sparkle-tools.sh generate-keys and put the printed public key in
# SPARKLE_PUBLIC_ED_KEY in project.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

TESTFLIGHT=1
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --skip-testflight) TESTFLIGHT=0 ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }

# MARK: Checks

TAG=$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null) || die "HEAD is not a version tag: run ./scripts/release.sh first"
VERSION=${TAG#v}
[[ -z "$(git status --porcelain)" ]] || die "Working tree is not clean"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "Publish from main"
PROJECT_VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml)
[[ "$PROJECT_VERSION" == "$VERSION" ]] || die "MARKETING_VERSION in project.yml (${PROJECT_VERSION}) does not match the tag (${VERSION})"
grep -qE '^ *SPARKLE_PUBLIC_ED_KEY: "[^"]+"' project.yml \
  || die "SPARKLE_PUBLIC_ED_KEY in project.yml is empty: run ./scripts/sparkle-tools.sh generate-keys"
gh release view "$TAG" >/dev/null 2>&1 && die "GitHub Release ${TAG} already exists"

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
if [[ $ASSUME_YES == 0 ]]; then
  echo "About to publish ${TAG}:"
  echo "  1. Build the DMG and sign the appcast"
  echo "  2. git push origin main ${TAG}"
  echo "  3. Create the Release on ${REPO} (DMG + appcast.xml)"
  [[ $TESTFLIGHT == 1 ]] && echo "  4. Upload to TestFlight"
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || exit 1
fi

# MARK: Package and appcast

./scripts/make-dmg.sh
DMG="build/EasyNotes-${VERSION}.dmg"
[[ -f "$DMG" ]] || die "$DMG not found"

STAGING=build/appcast
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$DMG" "$STAGING/"
# A .md with the DMG's file name becomes the release notes in Sparkle's update window
python3 scripts/changelog.py show "$VERSION" > "$STAGING/EasyNotes-${VERSION}.md"
cp "$STAGING/EasyNotes-${VERSION}.md" build/release-notes.md

"$(./scripts/sparkle-tools.sh path)/generate_appcast" \
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
  --embed-release-notes \
  "$STAGING"
[[ -f "$STAGING/appcast.xml" ]] || die "appcast.xml was not generated"

# MARK: Push and Release

git push origin main "$TAG"
gh release create "$TAG" "$DMG" "$STAGING/appcast.xml" \
  --title "EasyNotes ${VERSION}" \
  --notes-file build/release-notes.md \
  --verify-tag

echo "✓ Published $(gh release view "$TAG" --json url --jq .url)"

if [[ $TESTFLIGHT == 1 ]]; then
  # The Release is public now, so rerunning this script stops at "already exists": retry the upload alone
  ./scripts/upload-testflight.sh || die "TestFlight upload failed (the GitHub Release is already published): fix it, then run ./scripts/upload-testflight.sh"
fi
