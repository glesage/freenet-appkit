#!/usr/bin/env bash
# Build the signed Android App Bundle for a Play upload, then check it with
# scripts/check-store-build.sh.
#
#   VERSION_CODE=<n> [VERSION_NAME=<x.y>] scripts/bundle-android.sh
#
# VERSION_CODE must go up on every upload. The upload key comes from
# android/keystore.properties (see android/keystore.properties.example); the
# script stops when that file is missing, so no debug-signed bundle reaches
# Play. Build the native libraries first with scripts/build-android.sh.
#
# Output: android/demo/build/outputs/bundle/release/demo-release.aab
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION_CODE:?set VERSION_CODE; it must go up on every upload}"
[ -f android/keystore.properties ] || {
  echo "android/keystore.properties is missing: copy android/keystore.properties.example and fill in the upload key" >&2
  exit 1
}

export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
[ -f android/local.properties ] ||
  printf 'sdk.dir=%s\n' "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}" > android/local.properties

args=(-PversionCode="$VERSION_CODE")
[ -z "${VERSION_NAME:-}" ] || args+=(-PversionName="$VERSION_NAME")
(cd android && ./gradlew --no-configuration-cache -q :demo:bundleRelease "${args[@]}")

aab=android/demo/build/outputs/bundle/release/demo-release.aab
ls -l "$aab"
scripts/check-store-build.sh android "$aab"
