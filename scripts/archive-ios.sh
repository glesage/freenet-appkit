#!/usr/bin/env bash
# Archive the iOS app and export it for App Store Connect, then check the
# archived app with scripts/check-store-build.sh.
#
#   DEVELOPMENT_TEAM=<team id> BUILD_NUMBER=<n> [APP=river|atlas] scripts/archive-ios.sh
#
# APP picks the hosted app: river (default, freenet.appkit) or atlas
# (freenet.appkit.atlas).
#
# DEVELOPMENT_TEAM is the paid Apple Developer Program team. BUILD_NUMBER
# must go up on every upload. Build the XCFramework first with
# scripts/build-ios.sh (device and simulator).
#
# Output: build/ios/<app>.xcarchive and build/ios/export-<app>/AppKitDemo.ipa,
# ready to upload with Xcode Organizer or `xcrun altool --upload-app`.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the Apple team ID}"
: "${BUILD_NUMBER:?set BUILD_NUMBER; it must go up on every upload}"

app="${APP:-river}"
case "$app" in
  river) app_settings=(APPKIT_APPLICATION=river APPKIT_BUNDLE_SUFFIX= APPKIT_DISPLAY_NAME=River) ;;
  atlas) app_settings=(APPKIT_APPLICATION=atlas APPKIT_BUNDLE_SUFFIX=.atlas APPKIT_DISPLAY_NAME=Atlas) ;;
  *) echo "APP must be river or atlas" >&2; exit 2 ;;
esac
archive="build/ios/$app.xcarchive"
export_dir="build/ios/export-$app"
options=build/ios/ExportOptions.plist

rm -rf "$archive" "$export_dir"
mkdir -p build/ios

xcodebuild -project ios/AppKitDemo.xcodeproj -scheme AppKitDemo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${app_settings[@]}" \
  -allowProvisioningUpdates archive

# The export options in git hold a placeholder team; write the real one into
# a copy.
cp ios/ExportOptions.plist "$options"
plutil -replace teamID -string "$DEVELOPMENT_TEAM" "$options"

xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$options" -exportPath "$export_dir" -allowProvisioningUpdates

scripts/check-store-build.sh ios "$archive/Products/Applications/AppKitDemo.app"
