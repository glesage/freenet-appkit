#!/usr/bin/env bash
# Archive the iOS app and export it for App Store Connect, then check the
# archived app with scripts/check-store-build.sh.
#
#   DEVELOPMENT_TEAM=<team id> BUILD_NUMBER=<n> scripts/archive-ios.sh
#
# DEVELOPMENT_TEAM is the paid Apple Developer Program team. BUILD_NUMBER
# must go up on every upload. Build the XCFramework first with
# scripts/build-ios.sh (device and simulator).
#
# Output: build/ios/AppKitDemo.xcarchive. The export writes its logs to
# build/ios/export/ and, with `destination` = `upload` in
# ios/ExportOptions.plist, sends the build to App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the Apple team ID}"
: "${BUILD_NUMBER:?set BUILD_NUMBER; it must go up on every upload}"

archive=build/ios/AppKitDemo.xcarchive
export_dir=build/ios/export
options=build/ios/ExportOptions.plist

rm -rf "$archive" "$export_dir"
mkdir -p build/ios

xcodebuild -project ios/AppKitDemo.xcodeproj -scheme AppKitDemo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates archive

# The export options in git hold a placeholder team; write the real one into
# a copy.
cp ios/ExportOptions.plist "$options"
plutil -replace teamID -string "$DEVELOPMENT_TEAM" "$options"

xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$options" -exportPath "$export_dir" -allowProvisioningUpdates

scripts/check-store-build.sh ios "$archive/Products/Applications/AppKitDemo.app"
