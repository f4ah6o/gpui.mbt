#!/bin/sh
# Isolated Wayland/GLES E2E. Works with Ubuntu 24.04's Weston 13 and Weston 14.
set -eu
cd "$(dirname "$0")/.."
sh scripts/prepare_ubuntu.sh
mkdir -p _build/ubuntu-e2e
cc -std=c11 -Wall -Wextra -Werror ${GPUI_TEST_CFLAGS:-} tests/ubuntu/backend_test.c ubuntu/xdg-shell-protocol.c \
  -o _build/ubuntu-e2e/backend-test $(pkg-config --cflags --libs wayland-client wayland-egl egl glesv2 xkbcommon) -lpthread -lm
runtime=$(mktemp -d)
chmod 700 "$runtime"
compositor_pid=
cleanup() {
  if [ -n "$compositor_pid" ]; then kill "$compositor_pid" 2>/dev/null || true; wait "$compositor_pid" 2>/dev/null || true; fi
  rm -rf "$runtime"
}
trap cleanup EXIT HUP INT TERM
export XDG_RUNTIME_DIR="$runtime" XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=gpui-e2e
export LIBGL_ALWAYS_SOFTWARE=1
for scale in 1 2; do
  weston --backend=headless-backend.so --use-gl --shell=kiosk-shell.so \
    --width=1024 --height=768 --scale="$scale" --socket="$WAYLAND_DISPLAY" \
    --no-config --idle-time=0 --log="$PWD/_build/ubuntu-e2e/weston-scale-$scale.log" &
  compositor_pid=$!
  python3 - "$runtime/$WAYLAND_DISPLAY" <<'PY'
import pathlib, sys, time
socket = pathlib.Path(sys.argv[1])
for _ in range(200):
    if socket.exists():
        break
    time.sleep(.05)
else:
    raise SystemExit('Weston socket did not become ready; see _build/ubuntu-e2e logs')
PY
  set +e
  GPUI_UBUNTU_E2E=1 timeout 120 moon test ubuntu --target native --deny-warn --no-parallelize
  moon_status=$?
  set -e
  if [ "$moon_status" -ne 0 ]; then
    if kill -0 "$compositor_pid" 2>/dev/null; then
      echo "GPUI_WESTON_STATUS alive_after_moon_failure=true" >&2
    else
      set +e
      wait "$compositor_pid"
      weston_status=$?
      set -e
      echo "GPUI_WESTON_STATUS exit=$weston_status" >&2
      compositor_pid=
    fi
    tail -n 120 "$PWD/_build/ubuntu-e2e/weston-scale-$scale.log" >&2 || true
    exit "$moon_status"
  fi
  GPUI_UBUNTU_SMOKE=1 timeout 30 moon run examples/ubuntu --target native
  # Last test terminates this isolated compositor and checks disconnect handling.
  GPUI_EXPECT_SCALE="$scale" timeout 120 _build/ubuntu-e2e/backend-test "$compositor_pid"
  wait "$compositor_pid" || true
  compositor_pid=
done
