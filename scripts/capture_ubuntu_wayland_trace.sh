#!/bin/sh
# Failure-only repro of the Ubuntu scale-2 lifecycle test with bounded tracing.
set -eu
cd "$(dirname "$0")/.."

if [ "${GPUI_WAYLAND_TRACE:-0}" != 1 ]; then
  echo "Set GPUI_WAYLAND_TRACE=1 to opt in to the isolated protocol trace" >&2
  exit 2
fi

sh scripts/prepare_ubuntu.sh
mkdir -p _build/ubuntu-e2e
fontconfig_file=${GPUI_LINUX_TEXT_FONTCONFIG_FILE:-"$PWD/tests/linux_text/fonts.conf"}
if [ ! -r "$fontconfig_file" ]; then
  echo "Fontconfig fixture configuration is not readable: $fontconfig_file" >&2
  exit 1
fi
export FONTCONFIG_FILE="$fontconfig_file"
export FONTCONFIG_PATH="$(dirname "$fontconfig_file")"
export XDG_CACHE_HOME="$PWD/_build/ubuntu-e2e/font-cache"
mkdir -p "$XDG_CACHE_HOME"

runtime=$(mktemp -d)
chmod 700 "$runtime"
compositor_pid=
cleanup() {
  if [ -n "$compositor_pid" ]; then
    # Weston is owned by this diagnostic. The timeout wrapper escalates to
    # KILL if it ignores TERM, so waiting for it has a hard upper bound.
    kill "$compositor_pid" 2>/dev/null || true
    wait "$compositor_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime"
}
trap cleanup EXIT HUP INT TERM
export XDG_RUNTIME_DIR="$runtime" XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=gpui-trace
export LIBGL_ALWAYS_SOFTWARE=1

timeout --kill-after=5s 360s weston --backend=headless-backend.so --use-gl --shell=kiosk-shell.so \
  --width=1024 --height=768 --scale=2 --socket="$WAYLAND_DISPLAY" \
  --no-config --idle-time=0 --log="$PWD/_build/ubuntu-e2e/weston-trace-scale-2.log" &
compositor_pid=$!
if ! python3 scripts/wait_wayland_ready.py --pid "$compositor_pid" \
    --socket "$runtime/$WAYLAND_DISPLAY" --timeout-seconds 30; then
  echo "Diagnostic Weston did not become protocol-ready" >&2
  tail -n 120 "$PWD/_build/ubuntu-e2e/weston-trace-scale-2.log" >&2 || true
  exit 1
fi

trace_file="$PWD/_build/ubuntu-e2e/wayland-client-scale-2.trace"
rm -f "$trace_file"
set +e
GPUI_UBUNTU_E2E=1 timeout --kill-after=5s 170s \
  python3 scripts/capture_wayland_client_trace.py \
  --output "$trace_file" --max-bytes 262144 -- \
  timeout --kill-after=5s 120s moon test ubuntu --target native --deny-warn --no-parallelize
test_status=$?
set -e

if [ "$test_status" -ne 0 ]; then
  if kill -0 "$compositor_pid" 2>/dev/null; then
    echo "GPUI_TRACE_WESTON_STATUS=alive_after_test_failure" >&2
  else
    set +e
    wait "$compositor_pid"
    weston_status=$?
    set -e
    echo "GPUI_TRACE_WESTON_STATUS=exit:$weston_status" >&2
    compositor_pid=
  fi
  tail -n 120 "$PWD/_build/ubuntu-e2e/weston-trace-scale-2.log" >&2 || true
fi
exit "$test_status"
