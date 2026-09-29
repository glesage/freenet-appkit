#!/usr/bin/env bash
# Read River's and Atlas's website containers from the public network into
# fixtures/webapps/ and check them against the pins in fixtures/webapps.json.
# The run joins the network read-only and writes nothing to it.
set -euo pipefail
source "$(dirname "$0")/env.sh"

cd "$FREENET_CORE_DIR"
cargo build -q -p freenet-mobile --release --example fetch_contract
python3 - "$APPKIT_DIR/fixtures/webapps.json" <<'EOF' | while read -r name id; do
import json, sys
for name, pin in json.load(open(sys.argv[1]))["containers"].items():
    print(name, pin["instance_id"])
EOF
  log "fetch $name ($id)"
  "$CARGO_TARGET_DIR/release/examples/fetch_contract" "$id" "$APPKIT_DIR/fixtures/webapps/$name"
  rm -f "$APPKIT_DIR/fixtures/webapps/$name.json"
done
echo "Compare with the pins: scripts/prepare-resources.sh fails on any mismatch."
