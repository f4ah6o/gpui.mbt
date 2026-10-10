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
    --deadline-probe) MODE="deadline"; shift ;;
    --cleanup-probe) MODE="cleanup"; shift ;;
    --target-dir)
      [[ "$#" -ge 2 ]] || { echo '--target-dir requires a path.' >&2; exit 2; }
      TARGET_DIR="$2"
      shift 2
      ;;
    *) echo 'usage: test_macos_button_ax.sh [--all|--adapter-only|--mutation-probes|--deadline-probe|--cleanup-probe] [--target-dir PATH]' >&2; exit 2 ;;
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
CLIENT_PID=""
WATCHDOG_PID=""
SENTINEL_PID=""
KEEP_TARGET=0
app_process_state() {
  ps -p "$1" -o stat= 2>/dev/null | tr -d '[:space:]' || true
}

OWNED_PROCESS_CLEANUP_RESULT=""
terminate_owned_process() {
  local process_pid="$1"
  local process_name="$2"
  local process_state=""

  if [[ -z "$process_pid" ]]; then
    OWNED_PROCESS_CLEANUP_RESULT='not-started'
    return 0
  fi
  if ! kill -0 "$process_pid" 2>/dev/null; then
    wait "$process_pid" 2>/dev/null || true
    OWNED_PROCESS_CLEANUP_RESULT='already-exited-and-reaped'
    return 0
  fi

  kill -TERM "$process_pid" 2>/dev/null || true
  kill -CONT "$process_pid" 2>/dev/null || true
  for ((PROCESS_CLEANUP_TICK = 0; PROCESS_CLEANUP_TICK < 30; PROCESS_CLEANUP_TICK++)); do
    process_state="$(app_process_state "$process_pid")"
    if [[ -z "$process_state" || "$process_state" == Z* ]]; then break; fi
    sleep 0.1
  done
  process_state="$(app_process_state "$process_pid")"
  if [[ -n "$process_state" && "$process_state" != Z* ]]; then
    kill -KILL "$process_pid" 2>/dev/null || true
    for ((PROCESS_CLEANUP_TICK = 0; PROCESS_CLEANUP_TICK < 10; PROCESS_CLEANUP_TICK++)); do
      process_state="$(app_process_state "$process_pid")"
      if [[ -z "$process_state" || "$process_state" == Z* ]]; then break; fi
      sleep 0.1
    done
  fi
  process_state="$(app_process_state "$process_pid")"
  if [[ -z "$process_state" || "$process_state" == Z* ]]; then
    wait "$process_pid" 2>/dev/null || true
    OWNED_PROCESS_CLEANUP_RESULT='terminated-and-reaped'
  else
    OWNED_PROCESS_CLEANUP_RESULT="timeout-state-$process_state"
    echo "Timed out cleaning up owned $process_name process $process_pid (state $process_state)." >&2
  fi
}

record_process_cleanup() {
  local process_name="$1"
  local process_pid="$2"
  local process_result="$3"
  if [[ -f "$TARGET_DIR/client-receipt.txt" ]]; then
    printf '%s_process_cleanup_pid=%s\n%s_process_cleanup=%s\n' \
      "$process_name" "$process_pid" "$process_name" "$process_result" \
      >>"$TARGET_DIR/client-receipt.txt"
  fi
}

cleanup() {
  local original_status=$?
  trap - EXIT
  if [[ -n "$WATCHDOG_PID" ]]; then
    terminate_owned_process "$WATCHDOG_PID" watchdog
    WATCHDOG_CLEANUP_RESULT="$OWNED_PROCESS_CLEANUP_RESULT"
    record_process_cleanup watchdog "$WATCHDOG_PID" "$WATCHDOG_CLEANUP_RESULT"
    WATCHDOG_PID=""
  fi
  if [[ -n "$CLIENT_PID" ]]; then
    terminate_owned_process "$CLIENT_PID" AX-client
    CLIENT_CLEANUP_RESULT="$OWNED_PROCESS_CLEANUP_RESULT"
    record_process_cleanup client "$CLIENT_PID" "$CLIENT_CLEANUP_RESULT"
    CLIENT_PID=""
  fi
  if [[ -n "$APP_PID" ]]; then
    terminate_owned_process "$APP_PID" app
    APP_CLEANUP_RESULT="$OWNED_PROCESS_CLEANUP_RESULT"
    record_process_cleanup app "$APP_PID" "$APP_CLEANUP_RESULT"
    APP_PID=""
  fi
  if [[ "${1:-}" != '--preserve-sentinel' && -n "$SENTINEL_PID" ]]; then
    terminate_owned_process "$SENTINEL_PID" cleanup-probe-sentinel
    SENTINEL_PID=""
  fi
  if [[ "$CLEAN_TARGET" == 1 && "$KEEP_TARGET" == 0 ]]; then
    rm -rf "$TARGET_DIR"
  elif [[ "$CLEAN_TARGET" == 1 ]]; then
    echo "Retained AX client evidence at $TARGET_DIR" >&2
  fi
  return "$original_status"
}
trap cleanup EXIT

if [[ "$MODE" == cleanup ]]; then
  CLEAN_TARGET=0
  start_cleanup_probe_child() {
    local process_name="$1"
    local ignore_term="$2"
    local ready_file="$TARGET_DIR/$process_name-cleanup-probe-ready"
    rm -f "$ready_file"
    if [[ "$ignore_term" == 1 ]]; then
      python3 -c 'import pathlib, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text("ready"); time.sleep(60)' "$ready_file" &
    else
      python3 -c 'import pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text("ready"); time.sleep(60)' "$ready_file" &
    fi
    PROBE_CHILD_PID="$!"
    for ((APP_READY_TICK = 0; APP_READY_TICK < 30; APP_READY_TICK++)); do
      [[ -f "$ready_file" ]] && break
      sleep 0.1
    done
    if [[ ! -f "$ready_file" ]]; then
      kill -KILL "$PROBE_CHILD_PID" 2>/dev/null || true
      wait "$PROBE_CHILD_PID" 2>/dev/null || true
      return 1
    fi
  }
  python3 -c 'import time; time.sleep(60)' &
  SENTINEL_PID="$!"
  start_cleanup_probe_child app 1 || { echo 'App cleanup probe did not become ready.' >&2; exit 1; }
  APP_PID="$PROBE_CHILD_PID"
  start_cleanup_probe_child client 0 || { echo 'Client cleanup probe did not become ready.' >&2; exit 1; }
  CLIENT_PID="$PROBE_CHILD_PID"
  start_cleanup_probe_child watchdog 0 || { echo 'Watchdog cleanup probe did not become ready.' >&2; exit 1; }
  WATCHDOG_PID="$PROBE_CHILD_PID"
  kill -STOP "$APP_PID" "$CLIENT_PID" "$WATCHDOG_PID"
  APP_CLEANUP_STARTED="$SECONDS"
  cleanup --preserve-sentinel
  APP_CLEANUP_ELAPSED=$((SECONDS - APP_CLEANUP_STARTED))
  if [[ "$APP_CLEANUP_RESULT" != 'terminated-and-reaped' || \
        "$CLIENT_CLEANUP_RESULT" != 'terminated-and-reaped' || \
        "$WATCHDOG_CLEANUP_RESULT" != 'terminated-and-reaped' || \
        "$APP_CLEANUP_ELAPSED" -gt 5 ]]; then
    kill -TERM "$SENTINEL_PID" 2>/dev/null || true
    wait "$SENTINEL_PID" 2>/dev/null || true
    SENTINEL_PID=""
    echo "Expected stopped owned child to be reaped; got $APP_CLEANUP_RESULT." >&2
    exit 1
  fi
  if ! kill -0 "$SENTINEL_PID" 2>/dev/null; then
    kill -TERM "$SENTINEL_PID" 2>/dev/null || true
    wait "$SENTINEL_PID" 2>/dev/null || true
    echo 'Unrelated sentinel process was terminated by owned-child cleanup.' >&2
    exit 1
  fi
  kill -TERM "$SENTINEL_PID" 2>/dev/null || true
  wait "$SENTINEL_PID" 2>/dev/null || true
  SENTINEL_PID=""
  echo "PASS: stopped app/client/watchdog cleaned up within ${APP_CLEANUP_ELAPSED}s; unrelated sentinel survived"
  exit 0
fi

cd "$ROOT_DIR"
CLIENT="$TARGET_DIR/macos_button_ax_client"
compile_client_deadline_probe() {
  xcrun clang -Wall -Wextra -Werror \
    tests/native/macos_button_ax_client.m \
    -framework AppKit -framework ApplicationServices -framework CoreFoundation \
    -o "$CLIENT"
  "$CLIENT" --deadline-probe
}

if [[ "$MODE" == deadline ]]; then
  compile_client_deadline_probe
  exit 0
fi

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
compile_client_deadline_probe
APP_BINARY="$TARGET_DIR/bundle/GpuiMacButton.app/Contents/MacOS/GpuiMacButton"
APP_BUNDLE="$TARGET_DIR/bundle/GpuiMacButton.app"
APP_LIBRARY="$TARGET_DIR/bundle/GpuiMacButton.app/Contents/Frameworks/libgpui_macos.dylib"
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
CLIENT_RUN_ID="${APP_PID}-$$"
CLIENT_LOG="$TARGET_DIR/client-$CLIENT_RUN_ID.log"
CLIENT_DONE="$TARGET_DIR/client-complete-$CLIENT_RUN_ID"
CLIENT_WATCHDOG_FIRED="$TARGET_DIR/client-watchdog-fired-$CLIENT_RUN_ID"
printf 'client_log=%s\nwatchdog_marker=%s\n' \
  "$CLIENT_LOG" "$CLIENT_WATCHDOG_FIRED" >>"$TARGET_DIR/client-receipt.txt"
set +e
"$CLIENT" --pid "$APP_PID" --bundle-id "$TEST_BUNDLE_ID" \
  --bundle-path "$APP_BUNDLE" \
  >"$CLIENT_LOG" 2>&1 &
CLIENT_PID="$!"
printf 'client_pid=%s\n' "$CLIENT_PID" >>"$TARGET_DIR/client-receipt.txt"
CLIENT_WATCHDOG_SECONDS=35
python3 script/watch_macos_button_ax_client.py \
  --pid "$CLIENT_PID" --timeout-seconds "$CLIENT_WATCHDOG_SECONDS" \
  --done "$CLIENT_DONE" --fired "$CLIENT_WATCHDOG_FIRED" &
WATCHDOG_PID="$!"
wait "$CLIENT_PID"
CLIENT_STATUS=$?
set -e
: >"$CLIENT_DONE"
printf 'client_wait_status=%s\nclient_process_cleanup=waited\n' \
  "$CLIENT_STATUS" >>"$TARGET_DIR/client-receipt.txt"
CLIENT_PID=""
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=""
if [[ -e "$CLIENT_WATCHDOG_FIRED" ]]; then
  CLIENT_STATUS=124
  printf '%s\n' 'FAIL: shell watchdog stopped AX client after 35 seconds' \
    >>"$CLIENT_LOG"
  printf '%s\n' 'client_watchdog_fired=true' >>"$TARGET_DIR/client-receipt.txt"
fi
printf 'client_status=%s\n' "$CLIENT_STATUS" >>"$TARGET_DIR/client-receipt.txt"
cat "$CLIENT_LOG"
if [[ "$CLIENT_STATUS" -eq 77 ]]; then
  KEEP_TARGET=1
  echo 'UNSUPPORTED: real AXUIElement client is blocked by current macOS accessibility authorization.' >&2
  exit 77
fi
if [[ "$CLIENT_STATUS" -ne 0 ]]; then
  KEEP_TARGET=1
  cat "$TARGET_DIR/app.log" >&2
  exit "$CLIENT_STATUS"
fi
echo 'PASS: separately launched AXUIElement client observed the app-owned Button.'
