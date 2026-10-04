#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
moon_bin=${MOON_BIN:-moon}
module="$repo_root/_build/js/release/build/examples/mcp_stdio/mcp_stdio.js"

cd "$repo_root"
"$moon_bin" build examples/mcp_stdio --target js --release --deny-warn
exec node examples/mcp_stdio/host.mjs "$module"
