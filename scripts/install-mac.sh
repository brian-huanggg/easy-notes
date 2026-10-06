#!/bin/bash
# Quick local update: builds the macOS Release, replaces /Applications/EasyNotes.app and relaunches it (no DMG).
# Only the app bundle is replaced; the vault (~/Documents/EasyNotes) and app data are untouched.
# Pass --web after changing web/src to rebuild the CM6 bundle first.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--web" ]]; then
  (cd web && pnpm build)
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

# Quit gracefully (lets the app save and flush its upload queue), waiting up to 10 seconds.
# Match by path so an EasyNotes running in the iOS Simulator is not picked up
running() { pgrep -qf "^$DEST/Contents/MacOS/EasyNotes"; }
if running; then
  osascript -e 'tell application id "'"$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")"'" to quit' || true
  for _ in {1..20}; do running || break; sleep 0.5; done
  if running; then
    echo "EasyNotes did not quit; close it manually and rerun" >&2
    exit 1
  fi
fi

# Move the old app aside before copying the new one; restore it if the copy fails
OLD=""
if [[ -d "$DEST" ]]; then
  OLD="$DEST.old-$$"
  mv "$DEST" "$OLD"
fi
if ditto "$APP" "$DEST"; then
  [[ -n "$OLD" ]] && rm -rf "$OLD"
else
  [[ -n "$OLD" ]] && mv "$OLD" "$DEST"
  echo "Install failed; the previous version was restored" >&2
  exit 1
fi

open "$DEST"
echo "Updated ${DEST} ($(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist"))"
