# Shared paths for the build scripts. Source it; do not run it.
#
# Every path can be overridden from the environment:
#   FREENET_CORE_DIR  freenet-core checkout (default: ../freenet-core)
#   ANDROID_SDK_ROOT  Android SDK (default: ~/Library/Android/sdk)
#   ANDROID_NDK_ROOT  Android NDK (default: $ANDROID_SDK_ROOT/ndk/29.0.14206865)
#   PROFILE           Cargo profile: release (default) or debug

APPKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export APPKIT_DIR
export FREENET_CORE_DIR="${FREENET_CORE_DIR:-$(cd "$APPKIT_DIR/../freenet-core" && pwd)}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_SDK_ROOT/ndk/29.0.14206865}"
export PROFILE="${PROFILE:-release}"
export BUILD_DIR="$APPKIT_DIR/build"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$FREENET_CORE_DIR/target}"

# Lowest OS versions the libraries are built for.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-26}"

profile_flag() {
  if [ "$PROFILE" = "release" ]; then echo "--release"; fi
}

profile_dir() {
  if [ "$PROFILE" = "release" ]; then echo "release"; else echo "debug"; fi
}

log() {
  printf '\033[1m==> %s\033[0m\n' "$*"
}
