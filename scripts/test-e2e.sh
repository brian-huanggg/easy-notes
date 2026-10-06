#!/bin/bash
# E2E (XCUITest): drives the app from outside and verifies results through files on disk. Tests live in Tests/E2E.
#
#   ./scripts/test-e2e.sh [smoke|sync|perf|all] [mac|ipad] [--ci]
#
#   smoke  open vault, create / rename / move / pin / delete, external edits, open each kind, search, reindex (default)
#   sync   two-device sync: the app and the test runner share a folder backend (no Docker or network needed)
#   perf   launch, 1,000-element whiteboard, typing, 50 files changed externally at once (EASYNOTES_E2E_PERF=1)
#   all    all of the above
#   mac    macOS (default); ipad uses an iPad Simulator (IPAD_SIMULATOR picks the model)
#   --ci   sign without a developer certificate (machines with no Apple ID signed in, e.g. GitHub Actions)
#
# Results go to build/E2E-<suite>-<dest>.xcresult (with screenshots and recordings on failure); open it in Xcode.
# Do not touch the mouse or keyboard while it runs (XCUITest sends real input events); macOS tests switch to the
# ABC input source and restore it afterwards.
# On the first macOS run, the system asks to allow "Xcode Helper" / Terminal to control the computer (Accessibility).
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
    *) echo "Usage: $0 [smoke|sync|perf|all] [mac|ipad] [--ci]" >&2; exit 2 ;;
  esac
done

TARGET=EasyNotesE2ETests
SMOKE=(LaunchTests DocumentLifecycleTests ExternalChangeTests KindTests NavigationTests TabTests IndexRebuildTests)
case "$SUITE" in
  smoke) CLASSES=("${SMOKE[@]}") ;;
  sync) CLASSES=(SyncTests) ;;
  perf) CLASSES=(PerformanceTests) ;;
  all) CLASSES=("${SMOKE[@]}" SyncTests PerformanceTests) ;;
esac
ONLY=()
for c in "${CLASSES[@]}"; do ONLY+=("-only-testing:$TARGET/$c"); done

# Environment variables for the test runner need the TEST_RUNNER_ prefix
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
    # Ad-hoc signing; drop the Sign in with Apple entitlement (macOS refuses to launch the app without a profile, and E2E does not sign in)
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
