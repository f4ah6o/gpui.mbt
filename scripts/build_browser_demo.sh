#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
moon_bin="${MOON_BIN:-moon}"

cd "$repo_root"
"$moon_bin" build examples/browser --target js --release --deny-warn

site_dir="$repo_root/_build/browser-site"
rm -rf "$site_dir"
mkdir -p "$site_dir"
cp -R examples/browser/site/. "$site_dir/"
cp _build/js/release/build/examples/browser/browser.js "$site_dir/gpui-browser.js"
