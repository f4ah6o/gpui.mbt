#!/usr/bin/env bash
set -euo pipefail
if (($# != 2)); then echo 'Usage: build.sh PINNED_DRIVER_CHECKOUT FRESH_OUTPUT_DIRECTORY'; exit 2; fi
HERE="$(cd "$(dirname "$0")" && pwd -P)"
DRIVER="$(cd "$1" && pwd -P)"
[[ "$(git -C "$DRIVER" rev-parse HEAD)" == 072fa83e824c1b633f508f60cbad87b41aab3047 ]] || { echo 'Unexpected driver source'; exit 2; }
[[ -z "$(git -C "$DRIVER" status --porcelain)" ]] || { echo 'Driver source is modified'; exit 2; }
[[ ! -e "$2" ]] || { echo 'Output must be fresh'; exit 2; }
mkdir "$2"
OUTPUT="$(cd "$2" && pwd -P)"
xcrun clang++ -std=c++23 -fobjc-arc -Wall -Wextra -Werror \
  -I"$DRIVER/include" -I"$DRIVER/vendor/vendor/include" "$HERE/producer.mm" \
  -framework AppKit -framework Carbon -framework SystemConfiguration -o "$OUTPUT/producer"
xcrun clang -fobjc-arc -Wall -Wextra -Werror "$HERE/activate-owned.m" -framework AppKit -o "$OUTPUT/activate-owned"
"$OUTPUT/producer" --dry-run > "$OUTPUT/planned-pairs.jsonl"
shasum -a 256 "$HERE/producer.mm" "$HERE/activate-owned.m" "$HERE/../../../platform/macos/testing_hid_wire.h" > "$OUTPUT/sources.sha256"
shasum -a 256 "$OUTPUT/producer" "$OUTPUT/activate-owned" > "$OUTPUT/binaries.sha256"
echo "$OUTPUT"
