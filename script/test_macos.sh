#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p _build/macos
xcrun clang -fobjc-arc -Wall -Wextra -Werror tests/native/macos_e2e.m \
  platform/macos_text/core_text.c -framework AppKit -framework QuartzCore \
  -framework Metal -framework CoreText -framework CoreGraphics \
  -framework CoreFoundation -o _build/macos/macos_e2e
if [[ "${1:-}" == --build-only ]]; then exit 0; fi
GPUI_NATIVE_E2E=1 _build/macos/macos_e2e
./script/build_and_run.sh --smoke
