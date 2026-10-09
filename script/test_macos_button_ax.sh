#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="all"
TARGET_DIR=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --adapter-only) MODE="adapter"; shift ;;
    --mutation-probes) MODE="mutations"; shift ;;
    --target-dir)
      [[ "$#" -ge 2 ]] || { echo '--target-dir requires a path.' >&2; exit 2; }
      TARGET_DIR="$2"
      shift 2
      ;;
    *) echo 'usage: test_macos_button_ax.sh [--all|--adapter-only|--mutation-probes] [--target-dir PATH]' >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The macOS AX adapter tests require macOS and Xcode command-line tools.' >&2
  exit 2
fi

if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpui-macos-button-ax.XXXXXX")"
  CLEAN_TARGET=1
else
  case "$TARGET_DIR" in /*) ;; *) TARGET_DIR="$ROOT_DIR/$TARGET_DIR" ;; esac
  mkdir -p "$TARGET_DIR"
  CLEAN_TARGET=0
fi

APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [[ "$CLEAN_TARGET" == 1 ]]; then rm -rf "$TARGET_DIR"; fi
}
trap cleanup EXIT

cd "$ROOT_DIR"
ADAPTER="$TARGET_DIR/macos_accessibility_adapter_test"
xcrun clang -DGPUI_TESTING -fobjc-arc -Wall -Wextra -Werror \
  tests/native/macos_accessibility_adapter_test.m \
  platform/macos/accessibility.m \
  -framework AppKit -framework CoreFoundation \
  -o "$ADAPTER"
"$ADAPTER"

if [[ "$MODE" == mutations ]]; then
  MUTATION_DIR="$TARGET_DIR/mutations"
  mkdir -p "$MUTATION_DIR"

  python3 - "$ROOT_DIR/platform/macos/accessibility.m" \
    "$MUTATION_DIR/accessibility.m" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old = "self.loading || self.bindingToken <= 0"
new = "self.loading || self.enabled || self.bindingToken <= 0"
if source.count(old) != 1:
    raise SystemExit("could not identify the bounded AX Invoke guard")
Path(sys.argv[2]).write_text(source.replace(old, new, 1))
PY
  xcrun clang -DGPUI_TESTING -fobjc-arc -Wall -Wextra -Werror \
    tests/native/macos_accessibility_adapter_test.m \
    "$MUTATION_DIR/accessibility.m" \
    -I platform/macos \
    -framework AppKit -framework CoreFoundation \
    -o "$MUTATION_DIR/ax-intentionally-broken"
  set +e
  "$MUTATION_DIR/ax-intentionally-broken" >"$MUTATION_DIR/ax.log" 2>&1
  AX_STATUS=$?
  set -e
  if [[ "$AX_STATUS" -eq 0 ]] || ! grep -F 'enabled Invoke should enqueue' "$MUTATION_DIR/ax.log" >/dev/null; then
    cat "$MUTATION_DIR/ax.log" >&2
    echo 'AX mutation probe did not fail at the intended assertion.' >&2
    exit 1
  fi
  echo 'PASS: AX adapter regression probe failed at its enabled-Invoke assertion.'

  rsync -a \
    --exclude=.git --exclude=_build --exclude=.codex --exclude=target \
    "$ROOT_DIR/" "$MUTATION_DIR/repo/"
  python3 - "$MUTATION_DIR/repo/examples/macos_button/session.mbt" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = "Ok(demo.handle_input(input))"
if source.count(old) != 2:
    raise SystemExit("could not identify both semantic input routes")
path.write_text(source.replace(old, "Ok(demo)", 2))
PY
  set +e
  (cd "$MUTATION_DIR/repo" && moon test --target native --deny-warn \
    --target-dir "$MUTATION_DIR/moon" examples/macos_button) \
    >"$MUTATION_DIR/keyboard.log" 2>&1
  KEYBOARD_STATUS=$?
  set -e
  if [[ "$KEYBOARD_STATUS" -eq 0 ]] || \
    ! grep -F 'macOS event adapter routes Tab Enter and Space once' \
      "$MUTATION_DIR/keyboard.log" >/dev/null; then
    cat "$MUTATION_DIR/keyboard.log" >&2
    echo 'Keyboard mutation probe did not fail at the intended event assertion.' >&2
    exit 1
  fi
  echo 'PASS: keyboard regression probe failed at its event-routing test.'
  exit 0
fi

if [[ "$MODE" == adapter ]]; then exit 0; fi

./script/build_macos_button.sh --build --target-dir "$TARGET_DIR/bundle"
APP_BINARY="$TARGET_DIR/bundle/GpuiMacButton.app/Contents/MacOS/GpuiMacButton"
APP_BUNDLE="$TARGET_DIR/bundle/GpuiMacButton.app"
APP_LIBRARY="$TARGET_DIR/bundle/GpuiMacButton.app/Contents/Frameworks/libgpui_macos.dylib"
CLIENT="$TARGET_DIR/macos_button_ax_client"
xcrun clang -Wall -Wextra -Werror \
  tests/native/macos_button_ax_client.m \
  -framework AppKit -framework ApplicationServices -framework CoreFoundation \
  -o "$CLIENT"

# Keep LaunchServices/AX identity unique while leaving the production build
# script's stable bundle identifier untouched. Other task-owned sample
# processes may still be running with the regular example identifier.
TEST_BUNDLE_ID="org.gpui.mbt.macos-button.ax-test.p$$"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_BUNDLE_ID" \
  "$APP_BUNDLE/Contents/Info.plist"
echo "AX test bundle identifier: $TEST_BUNDLE_ID"

GPUI_MACOS_LIBRARY="$APP_LIBRARY" "$APP_BINARY" \
  >"$TARGET_DIR/app.log" 2>&1 &
APP_PID="$!"
printf '%s\n' "$APP_PID" >"$TARGET_DIR/app.pid"
printf 'bundle_path=%s\nbundle_id=%s\npid=%s\n' \
  "$APP_BUNDLE" "$TEST_BUNDLE_ID" "$APP_PID" >"$TARGET_DIR/client-receipt.txt"
echo "Launched $APP_BINARY (bundle $APP_BUNDLE, bundle id $TEST_BUNDLE_ID, pid $APP_PID)"
set +e
"$CLIENT" --pid "$APP_PID" --bundle-id "$TEST_BUNDLE_ID"
CLIENT_STATUS=$?
set -e
printf 'client_status=%s\n' "$CLIENT_STATUS" >>"$TARGET_DIR/client-receipt.txt"
if [[ "$CLIENT_STATUS" -eq 77 ]]; then
  echo 'UNSUPPORTED: real AXUIElement client is blocked by current macOS accessibility authorization.' >&2
  exit 77
fi
if [[ "$CLIENT_STATUS" -ne 0 ]]; then
  cat "$TARGET_DIR/app.log" >&2
  exit "$CLIENT_STATUS"
fi
echo 'PASS: separately launched AXUIElement client observed the app-owned Button.'
