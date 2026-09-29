#!/usr/bin/env bash
# Build freenet-mobile for Android, copy the libraries into the Kotlin
# library's jniLibs and generate the Kotlin bindings.
#
#   scripts/build-android.sh                 # arm64-v8a, x86_64, armeabi-v7a
#   ABIS="arm64-v8a" scripts/build-android.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"

ABIS="${ABIS:-arm64-v8a x86_64 armeabi-v7a}"
toolchain="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"
[ -d "$toolchain" ] || { echo "NDK not found at $ANDROID_NDK_ROOT" >&2; exit 1; }

rust_target() {
  case "$1" in
    arm64-v8a) echo aarch64-linux-android ;;
    x86_64) echo x86_64-linux-android ;;
    armeabi-v7a) echo armv7-linux-androideabi ;;
    *) echo "unknown ABI $1" >&2; exit 2 ;;
  esac
}

clang_prefix() {
  case "$1" in
    armv7-linux-androideabi) echo "armv7a-linux-androideabi$ANDROID_API_LEVEL" ;;
    *) echo "$1$ANDROID_API_LEVEL" ;;
  esac
}

jni_libs="$APPKIT_DIR/android/appkit/src/main/jniLibs"
cd "$FREENET_CORE_DIR"
for abi in $ABIS; do
  target="$(rust_target "$abi")"
  prefix="$(clang_prefix "$target")"
  upper="$(echo "$target" | tr 'a-z-' 'A-Z_')"
  lower="$(echo "$target" | tr '-' '_')"
  export "CC_$lower=$toolchain/$prefix-clang"
  export "CXX_$lower=$toolchain/$prefix-clang++"
  export "AR_$lower=$toolchain/llvm-ar"
  export "CARGO_TARGET_${upper}_LINKER=$toolchain/$prefix-clang"
  # 16 KB pages: Android 15+ devices and the API 37 emulator image need
  # 16 KB-aligned ELF segments.
  export "CARGO_TARGET_${upper}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384"
  log "cargo build freenet-mobile for $abi ($target, $PROFILE)"
  cargo build -p freenet-mobile --lib $(profile_flag) --target "$target"
  mkdir -p "$jni_libs/$abi"
  cp "$CARGO_TARGET_DIR/$target/$(profile_dir)/libfreenet_mobile.so" "$jni_libs/$abi/"
  "$toolchain/llvm-strip" --strip-debug "$jni_libs/$abi/libfreenet_mobile.so"
done

log "build the host library for binding generation"
cargo build -p freenet-mobile --lib $(profile_flag)
log "generate Kotlin bindings"
kotlin_out="$APPKIT_DIR/android/appkit/src/main/java"
rm -rf "$kotlin_out/org/freenet/mobile"
cargo run -q -p freenet-mobile --features bindgen-cli --bin uniffi-bindgen -- \
  generate --library "$CARGO_TARGET_DIR/$(profile_dir)/libfreenet_mobile.dylib" \
  --language kotlin --out-dir "$kotlin_out"

log "done"
for abi in $ABIS; do
  size=$(stat -f %z "$jni_libs/$abi/libfreenet_mobile.so")
  echo "  $abi: libfreenet_mobile.so $((size / 1024 / 1024)) MiB"
done
