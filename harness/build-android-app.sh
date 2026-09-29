#!/usr/bin/env bash
# Build the Android demo APK: harness/build-android-app.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/../android"
config="${1:-Release}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
[ -f local.properties ] || printf 'sdk.dir=%s\n' "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}" > local.properties
./gradlew --no-configuration-cache -q ":demo:assemble$config"
ls -l demo/build/outputs/apk/*/demo-*.apk | grep -i "$config"
