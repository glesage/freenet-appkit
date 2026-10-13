#!/usr/bin/env bash
# Build the Android APKs: [APP=river|atlas] scripts/build-android-app.sh [Debug|Release]
# APP picks the hosted app flavor; without it both flavors build.
set -euo pipefail
cd "$(dirname "$0")/../android"
config="${1:-Release}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
[ -f local.properties ] || printf 'sdk.dir=%s\n' "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}" > local.properties
case "${APP:-}" in
  "") task=":demo:assemble$config" ;;
  river|atlas) task=":demo:assemble$(tr '[:lower:]' '[:upper:]' <<<"${APP:0:1}")${APP:1}$config" ;;
  *) echo "APP must be river or atlas" >&2; exit 2 ;;
esac
./gradlew --no-configuration-cache -q "$task"
ls -l demo/build/outputs/apk/*/*/demo-*.apk | grep -i "$config"
