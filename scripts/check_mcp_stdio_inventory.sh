#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
moon_bin=${MOON_BIN:-moon}
module="$repo_root/_build/js/release/build/examples/mcp_stdio/mcp_stdio.js"
fixture="$repo_root/examples/mcp_stdio/fixtures/tools-list.json"
mode=${1:---check}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT HUP INT TERM

case "$mode" in
  --check|--update) ;;
  *) printf '%s\n' "usage: $0 [--check|--update]" >&2; exit 64 ;;
esac

cd "$repo_root"
"$moon_bin" build examples/mcp_stdio --target js --release --deny-warn
node examples/mcp_stdio/inventory.mjs "$module" > "$tmp"

if [ "$mode" = "--update" ]; then
  cp "$tmp" "$fixture"
  printf '%s\n' "Updated examples/mcp_stdio/fixtures/tools-list.json from the compiled MoonBit fixture."
elif ! cmp -s "$fixture" "$tmp"; then
  diff -u "$fixture" "$tmp" >&2 || true
  printf '%s\n' "Checked MCP tools inventory is stale; run scripts/check_mcp_stdio_inventory.sh --update." >&2
  exit 1
else
  printf '%s\n' "MCP stdio tools inventory matches the compiled MoonBit fixture."
fi
