#!/bin/sh
# One bounded failure-only replay of the lifecycle E2E at both integer scales.
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

failure=0
for scale in 1 2; do
  runtime=$(mktemp -d)
  chmod 700 "$runtime"
  compositor_pid=
  temp_dir=$(mktemp -d)
  stdout_file="$temp_dir/stdout"
  stderr_file="$temp_dir/stderr"
  weston_log="$PWD/_build/ubuntu-e2e/weston-diagnostic-scale-$scale.log"
  trace_file="$PWD/_build/ubuntu-e2e/wayland-client-scale-$scale.trace"
  stage_file="$PWD/_build/ubuntu-e2e/first-frame-stage-trace-scale-$scale.log"
  status_file="$PWD/_build/ubuntu-e2e/diagnostic-status-scale-$scale.txt"
  : > "$status_file"

  cleanup() {
    if [ -n "$compositor_pid" ]; then
      kill "$compositor_pid" 2>/dev/null || true
      wait "$compositor_pid" 2>/dev/null || true
      compositor_pid=
    fi
    rm -rf "$runtime" "$temp_dir"
  }
  trap cleanup EXIT HUP INT TERM

  export XDG_RUNTIME_DIR="$runtime" XDG_SESSION_TYPE=wayland
  export WAYLAND_DISPLAY="gpui-trace-$scale" LIBGL_ALWAYS_SOFTWARE=1
  timeout --kill-after=5s 360s weston --backend=headless-backend.so --use-gl --shell=kiosk-shell.so \
    --width=1024 --height=768 --scale="$scale" --socket="$WAYLAND_DISPLAY" \
    --no-config --idle-time=0 --log="$weston_log" &
  compositor_pid=$!
  if ! python3 scripts/wait_wayland_ready.py --pid "$compositor_pid" \
      --socket "$runtime/$WAYLAND_DISPLAY" --timeout-seconds 30; then
    printf 'scale=%s\nprotocol_ready=0\n' "$scale" > "$status_file"
    echo "Diagnostic Weston was not protocol-ready at scale $scale" >&2
    tail -n 120 "$weston_log" >&2 || true
    failure=1
    cleanup
    continue
  fi

  set +e
  GPUI_UBUNTU_E2E=1 GPUI_UBUNTU_E2E_STAGE_TRACE=1 \
    timeout --kill-after=5s 170s \
    python3 scripts/capture_wayland_client_trace.py \
      --output "$trace_file" --max-bytes 262144 -- \
      timeout --kill-after=5s 120s moon test ubuntu --target native --deny-warn --no-parallelize \
      > "$stdout_file" 2> "$stderr_file"
  test_status=$?
  set -e

  awk '
    /^GPUI_UBUNTU_E2E_STAGE stage=[0-9]+ iteration=[0-9]+ scale=[0-9]+([.][0-9]+)? generation=[0-9]+$/ {
      if (count < 3984) print
      count++
    }
    END {
      printf "records=%d\n", count
      if (count > 3984) print "truncated=true"
    }
  ' "$stdout_file" > "$stage_file"

  if kill -0 "$compositor_pid" 2>/dev/null; then
    weston_state=alive_after_test
    kill "$compositor_pid" 2>/dev/null || true
    set +e
    wait "$compositor_pid"
    weston_exit=$?
    set -e
  else
    set +e
    wait "$compositor_pid"
    weston_exit=$?
    set -e
    weston_state="exit:$weston_exit"
    compositor_pid=
  fi
  {
    printf 'scale=%s\nprotocol_ready=1\nmoon_test_exit=%s\nweston_state=%s\n' \
      "$scale" "$test_status" "$weston_state"
    grep -E '^GPUI_WAYLAND_TRACE_FILE=.* bytes=[0-9]+$' "$stderr_file" || true
  } > "$status_file"
  printf 'GPUI_UBUNTU_DIAGNOSTIC scale=%s moon_test_exit=%s weston=%s\n' \
    "$scale" "$test_status" "$weston_state"

  if [ "$test_status" -ne 0 ] || [ "$weston_state" != alive_after_test ]; then
    failure=1
    tail -n 120 "$weston_log" >&2 || true
  fi
  cleanup
  trap - EXIT HUP INT TERM
done

exit "$failure"
