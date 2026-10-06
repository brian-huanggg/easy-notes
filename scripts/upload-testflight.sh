#!/bin/bash
# Builds the iOS / iPadOS Release and uploads it to App Store Connect (TestFlight).
# Uses the Apple ID signed in to Xcode (Xcode → Settings → Accounts); signing is automatic.
# The build number is a timestamp, so it increases every time without editing project.yml.
# After changing web/src, run (cd web && pnpm build) first.
#
#   ./scripts/upload-testflight.sh            # archive + upload
#   ./scripts/upload-testflight.sh --export   # only export build/TestFlight/EasyNotes.ipa, no upload
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
  echo "Uploaded $VERSION ($BUILD_NUMBER); TestFlight notifies you once App Store Connect finishes processing (about 5–15 minutes)."
else
  echo "$OUT/EasyNotes.ipa — $VERSION ($BUILD_NUMBER)"
fi
