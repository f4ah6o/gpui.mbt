#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p _build/macos
xcrun clang -fobjc-arc -Wall -Wextra -Werror tests/native/macos_e2e.m \
  -framework AppKit -framework QuartzCore -framework Metal -o _build/macos/macos_e2e
if [[ "${1:-}" == --build-only ]]; then exit 0; fi
_build/macos/macos_e2e
./script/build_and_run.sh --smoke
