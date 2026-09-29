#!/usr/bin/env bash
# Write the desktop protocol fixture values that every device run is compared
# with: fixtures/protocol/protocol-fixtures.json.
set -euo pipefail
source "$(dirname "$0")/env.sh"

out="$APPKIT_DIR/fixtures/protocol/protocol-fixtures.json"
mkdir -p "$(dirname "$out")"
cd "$FREENET_CORE_DIR"
cargo run -q -p freenet-mobile --release --example generate_fixtures -- "$out"
