#!/usr/bin/env bash
# Build the iOS app for the simulator (default) or a device.
#   scripts/build-ios-app.sh [Debug|Release] [simulator|device]
#   APP=atlas scripts/build-ios-app.sh Debug simulator
# APP picks the hosted app: river (default, bundle freenet.appkit) or atlas
# (bundle freenet.appkit.atlas). Each is its own installation with its own
# node, stores and consent records.
# Device builds need a signing team: DEVELOPMENT_TEAM=<team id>. Simulator
# builds are arm64 only (Apple silicon Macs), matching the XCFramework.
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-Release}"
kind="${2:-simulator}"
app="${APP:-river}"
case "$app" in
  river) app_settings=(APPKIT_APPLICATION=river APPKIT_BUNDLE_SUFFIX= APPKIT_DISPLAY_NAME=River) ;;
  atlas) app_settings=(APPKIT_APPLICATION=atlas APPKIT_BUNDLE_SUFFIX=.atlas APPKIT_DISPLAY_NAME=Atlas) ;;
  *) echo "APP must be river or atlas" >&2; exit 2 ;;
esac
derived="build/ios/DerivedData-$app"
if [ "$kind" = "device" ]; then
  : "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"
  xcodebuild -project ios/AppKitDemo.xcodeproj -scheme AppKitDemo -configuration "$config" \
    -sdk iphoneos -destination "${DEVICE_ID:+id=$DEVICE_ID}${DEVICE_ID:-generic/platform=iOS}" -derivedDataPath "$derived" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" "${app_settings[@]}" -allowProvisioningUpdates build | grep -E "error:|\*\* " || true
else
  xcodebuild -project ios/AppKitDemo.xcodeproj -scheme AppKitDemo -configuration "$config" \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO "${app_settings[@]}" build | grep -E "error:|\*\* " || true
fi
echo "$derived/Build/Products/$config-$( [ "$kind" = device ] && echo iphoneos || echo iphonesimulator )/AppKitDemo.app"
