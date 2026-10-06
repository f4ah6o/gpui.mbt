#!/bin/sh
# Isolated Wayland/GLES E2E. Works with Ubuntu 24.04's Weston 13 and Weston 14.
set -eu
cd "$(dirname "$0")/.."
sh scripts/prepare_ubuntu.sh
mkdir -p _build/ubuntu-e2e
fontconfig_file=${GPUI_LINUX_TEXT_FONTCONFIG_FILE:-"$PWD/tests/linux_text/fonts.conf"}
if [ ! -r "$fontconfig_file" ]; then
  echo "Fontconfig fixture configuration is not readable: $fontconfig_file" >&2
  exit 1
fi
export FONTCONFIG_FILE="$fontconfig_file"
FONTCONFIG_PATH=$(dirname "$fontconfig_file")
export FONTCONFIG_PATH
export XDG_CACHE_HOME="$PWD/_build/ubuntu-e2e/font-cache"
mkdir -p "$XDG_CACHE_HOME"
script/linux_text_cc.py -std=c11 -Wall -Wextra -Werror ${GPUI_TEST_CFLAGS:-} \
  tests/ubuntu/backend_test.c ubuntu/xdg-shell-protocol.c platform/linux_text/linux_text.c \
  -o _build/ubuntu-e2e/backend-test \
  $(pkg-config --cflags --libs wayland-client wayland-cursor wayland-egl egl glesv2 xkbcommon) \
  -lpthread -lm
_build/ubuntu-e2e/backend-test --clipboard-unit
script/linux_text_cc.py -std=c11 -Wall -Wextra -Werror ${GPUI_TEST_CFLAGS:-} \
  tests/ubuntu/direct_text_test.c ubuntu/xdg-shell-protocol.c platform/linux_text/linux_text.c \
  -o _build/ubuntu-e2e/direct-text-test \
  $(pkg-config --cflags --libs wayland-client wayland-cursor wayland-egl egl glesv2 xkbcommon) \
  -lpthread -lm
env -u DISPLAY -u WAYLAND_DISPLAY _build/ubuntu-e2e/direct-text-test
script/linux_text_cc.py -std=c11 -Wall -Wextra -Werror ${GPUI_TEST_CFLAGS:-} \
  tests/ubuntu/key_repeat_test.c ubuntu/xdg-shell-protocol.c platform/linux_text/linux_text.c \
  -o _build/ubuntu-e2e/key-repeat-test \
  $(pkg-config --cflags --libs wayland-client wayland-cursor wayland-egl egl glesv2 xkbcommon) \
  -lpthread -lm
env -u DISPLAY -u WAYLAND_DISPLAY _build/ubuntu-e2e/key-repeat-test
env -u DISPLAY -u WAYLAND_DISPLAY \
  moon test examples/linux_text_field --target native --deny-warn --no-parallelize
# Preserve the original scenes emitted by actual control code with the same
# real-font provider used by the renderer. GPF1/GPF2 replay is test-only injected
# control-to-renderer gate, distinct from actual compositor keyboard ingress.
field_run=$(sh scripts/create_field_fixture_run.sh _build/ubuntu-e2e)
printf 'GPUI_FIELD_RUN evidence_dir=%s source_head=%s\n' "$field_run" "$(git rev-parse HEAD)"
env -u DISPLAY -u WAYLAND_DISPLAY GPUI_FIELD_FIXTURES=1 \
  moon run examples/linux_text_field --target native > "$field_run/fixtures.jsonl"
{
  printf 'source_head=%s\n' "$(git rev-parse HEAD)"
  printf 'fontconfig=%s\n' "$FONTCONFIG_FILE"
  for requested_font in sans 'sans:charset=65e5'; do
    printf 'fc_match_request=%s\n' "$requested_font"
    fc-match -f '%{family}|%{file}\n' "$requested_font"
    font_file=$(fc-match -f '%{file}' "$requested_font")
    if [ -n "$font_file" ] && [ -r "$font_file" ]; then
      sha256sum "$font_file"
    else
      printf 'font_content_hash=unavailable\n'
    fi
  done
  sha256sum examples/linux_text_field/field.mbt controls/text_field/model.mbt \
    controls/text_field/history.mbt controls/text_field/paint.mbt \
    platform/linux_text/linux_text.c "$FONTCONFIG_FILE"
} > "$field_run/font-profile.txt"
python3 scripts/encode_field_fixtures.py "$field_run/fixtures.jsonl" \
  --output-dir "$field_run/encoded" --source-head "$(git rev-parse HEAD)"
script/linux_text_cc.py -std=c11 -Wall -Wextra -Werror ${GPUI_TEST_CFLAGS:-} \
  tests/ubuntu/field_gpu_test.c ubuntu/xdg-shell-protocol.c platform/linux_text/linux_text.c \
  -o _build/ubuntu-e2e/field-gpu-test \
  $(pkg-config --cflags --libs wayland-client wayland-cursor wayland-egl egl glesv2 xkbcommon) \
  -lpthread -lm
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
  # The Wayland socket appears before Weston has necessarily completed shell
  # initialization. In CI, require one successful protocol roundtrip before
  # starting the stress test so a just-created socket is not treated as ready.
  if ! python3 scripts/wait_wayland_ready.py --pid "$compositor_pid" \
      --socket "$runtime/$WAYLAND_DISPLAY" --timeout-seconds 30; then
    echo "Weston did not become protocol-ready; see _build/ubuntu-e2e logs" >&2
    tail -n 120 "$PWD/_build/ubuntu-e2e/weston-scale-$scale.log" >&2 || true
    exit 1
  fi
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
  GPUI_FIELD_E2E=1 timeout 120 moon test examples/linux_text_field \
    --target native --deny-warn --no-parallelize
  GPUI_FIELD_SMOKE=1 timeout 30 moon run examples/linux_text_field --target native
  GPUI_FIELD_FIXTURES_DIR="$field_run/encoded" \
    GPUI_FIELD_CAPTURE="$field_run/field-frame-scale-$scale.ppm" \
    GPUI_EXPECT_SCALE="$scale" timeout 120 _build/ubuntu-e2e/field-gpu-test
  # Last test terminates this isolated compositor and checks disconnect handling.
  GPUI_UBUNTU_CAPTURE="$PWD/_build/ubuntu-e2e/grayscale-frame-scale-$scale.ppm" \
    GPUI_EXPECT_SCALE="$scale" timeout 120 _build/ubuntu-e2e/backend-test "$compositor_pid"
  wait "$compositor_pid" || true
  compositor_pid=
done
