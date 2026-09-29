#!/usr/bin/env bash
# Build freenet-mobile for iOS devices and the iOS simulator, generate the
# Swift bindings and package build/ios/FreenetMobileFFI.xcframework.
#
#   scripts/build-ios.sh            # device and simulator
#   TARGETS=sim scripts/build-ios.sh  # simulator only
set -euo pipefail
source "$(dirname "$0")/env.sh"

TARGETS="${TARGETS:-all}"
case "$TARGETS" in
  all) rust_targets=(aarch64-apple-ios aarch64-apple-ios-sim) ;;
  sim) rust_targets=(aarch64-apple-ios-sim) ;;
  device) rust_targets=(aarch64-apple-ios) ;;
  *) echo "TARGETS must be all, sim or device" >&2; exit 2 ;;
esac

cd "$FREENET_CORE_DIR"
for target in "${rust_targets[@]}"; do
  log "cargo build freenet-mobile for $target ($PROFILE)"
  cargo build -p freenet-mobile --lib $(profile_flag) --target "$target"
done

log "build the host library for binding generation"
cargo build -p freenet-mobile --lib $(profile_flag)
log "generate Swift bindings"
out="$BUILD_DIR/ios/bindings"
rm -rf "$out" && mkdir -p "$out"
cargo run -q -p freenet-mobile --features bindgen-cli --bin uniffi-bindgen -- \
  generate --library "$CARGO_TARGET_DIR/$(profile_dir)/libfreenet_mobile.dylib" \
  --language swift --out-dir "$out"

log "package FreenetMobileFFI.xcframework"
headers="$BUILD_DIR/ios/headers"
rm -rf "$headers" && mkdir -p "$headers"
cp "$out/FreenetMobileFFI.h" "$headers/"
cp "$out/FreenetMobileFFI.modulemap" "$headers/module.modulemap"
xcframework="$BUILD_DIR/ios/FreenetMobileFFI.xcframework"
rm -rf "$xcframework"
args=()
for target in "${rust_targets[@]}"; do
  args+=(-library "$CARGO_TARGET_DIR/$target/$(profile_dir)/libfreenet_mobile.a" -headers "$headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$xcframework" >/dev/null

generated="$APPKIT_DIR/Sources/FreenetAppKit/Generated"
mkdir -p "$generated"
cp "$out/FreenetMobile.swift" "$generated/FreenetMobile.swift"

log "done"
for target in "${rust_targets[@]}"; do
  size=$(stat -f %z "$CARGO_TARGET_DIR/$target/$(profile_dir)/libfreenet_mobile.a")
  echo "  $target: libfreenet_mobile.a $((size / 1024 / 1024)) MiB"
done
echo "  $xcframework"
echo "  $generated/FreenetMobile.swift"
