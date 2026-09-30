#!/usr/bin/env bash
# Build the iOS app for the simulator (default) or a device.
#   scripts/build-ios-app.sh [Debug|Release] [simulator|device]
# Device builds need a signing team: DEVELOPMENT_TEAM=<team id>. Simulator
# builds are arm64 only (Apple silicon Macs), matching the XCFramework.
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-Release}"
kind="${2:-simulator}"
if [ "$kind" = "device" ]; then
  : "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"
  xcodebuild -project ios/AppKitDemo.xcodeproj -scheme AppKitDemo -configuration "$config" \
    -sdk iphoneos -destination "${DEVICE_ID:+id=$DEVICE_ID}${DEVICE_ID:-generic/platform=iOS}" -derivedDataPath build/ios/DerivedData \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates build | grep -E "error:|\*\* " || true
else
  xcodebuild -project ios/AppKitDemo.xcodeproj -scheme AppKitDemo -configuration "$config" \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios/DerivedData \
    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build | grep -E "error:|\*\* " || true
fi
