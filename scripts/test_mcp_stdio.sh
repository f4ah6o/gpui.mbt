#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
moon_bin=${MOON_BIN:-moon}

cd "$repo_root"
"$moon_bin" build examples/mcp_stdio --target js --release --deny-warn
node --test tests/mcp_stdio/endpoint.test.mjs
MOON_BIN="$moon_bin" scripts/check_mcp_stdio_inventory.sh --check
