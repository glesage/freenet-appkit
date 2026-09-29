#!/usr/bin/env bash
# Copy everything the demo apps load at run time into their resource folders:
#   ios/AppKitResources/                           (a folder reference in Xcode)
#   android/demo/src/main/assets/AppKitResources/  (Android assets)
#
# - bridge-test/: the host-served test bundle, with manifest.json generated
#   from its files, plus secret.txt, which the manifest leaves out on purpose.
# - protocol-fixtures.json: the desktop values the devices compare with.
# - webapps/: River's and Atlas's website containers (fetched, see
#   fixtures/webapps.json), for the offline local profile.
# - contracts/: River's room contract and Atlas's index contract, compiled in
#   the conformance run.
set -euo pipefail
source "$(dirname "$0")/env.sh"

RIVER_DIR="${RIVER_DIR:-$APPKIT_DIR/../river}"
ATLAS_DIR="${ATLAS_DIR:-$APPKIT_DIR/../atlas}"
fixtures="$APPKIT_DIR/fixtures/protocol/protocol-fixtures.json"
[ -f "$fixtures" ] || { echo "missing $fixtures; run scripts/generate-fixtures.sh" >&2; exit 1; }

stage="$BUILD_DIR/resources"
rm -rf "$stage" && mkdir -p "$stage/webapps" "$stage/contracts"

log "bridge test bundle"
cp -R "$APPKIT_DIR/web/bridge-test" "$stage/bridge-test"
(cd "$FREENET_CORE_DIR" && cargo run -q -p freenet-mobile --release --example bundle_manifest -- \
  "$stage/bridge-test" bridge-test)
echo "not listed in the manifest, so the host must not serve it" > "$stage/bridge-test/secret.txt"

cp "$fixtures" "$stage/protocol-fixtures.json"
cp "$APPKIT_DIR/fixtures/webapps.json" "$stage/webapps.json"

log "website containers"
python3 - "$APPKIT_DIR/fixtures" "$stage/webapps" <<'EOF'
import hashlib, json, pathlib, shutil, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
pins = json.loads((src / "webapps.json").read_text())["containers"]
for name, pin in pins.items():
    for ext, key in (("code.wasm", "code_wasm"), ("params", "params"), ("state", "state")):
        f = src / "webapps" / f"{name}.{ext}"
        if not f.exists():
            print(f"  {name}.{ext} missing: run scripts/fetch-webapps.sh for the offline profile")
            break
        digest = hashlib.sha256(f.read_bytes()).hexdigest()
        if digest != pin[key]["sha256"]:
            sys.exit(f"{f} does not match its pin in webapps.json")
        shutil.copy(f, dst / f.name)
    else:
        print(f"  {name}: pinned container copied")
EOF

log "contracts"
cp "$RIVER_DIR/ui/public/contracts/room_contract.wasm" "$stage/contracts/river-room-contract.wasm"
cp "$ATLAS_DIR/contracts/index-contract/atlas_index_contract.wasm" "$stage/contracts/atlas-index-contract.wasm"

for dest in "$APPKIT_DIR/ios/AppKitResources" "$APPKIT_DIR/android/demo/src/main/assets/AppKitResources"; do
  rm -rf "$dest" && mkdir -p "$(dirname "$dest")"
  cp -R "$stage" "$dest"
done
log "done"
find "$stage" -type f | sed "s|$stage/|  |" | sort
