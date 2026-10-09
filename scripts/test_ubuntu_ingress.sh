#!/bin/sh
# Headless private callback/queue tests, including the opt-in IME transport.
# GPUI_TEST_CFLAGS can select sanitizers. This is not native IME acceptance.
set -eu
cd "$(dirname "$0")/.."
sh scripts/prepare_ubuntu.sh
build_dir=${GPUI_UBUNTU_INGRESS_BUILD_DIR:-_build/ubuntu-ingress}
mkdir -p "$build_dir"
for fixture in direct_text key_repeat ime_transport output_metadata; do
  script/linux_text_cc.py -std=c11 -Wall -Wextra -Werror ${GPUI_TEST_CFLAGS:-} \
    "tests/ubuntu/${fixture}_test.c" ubuntu/xdg-shell-protocol.c \
    ubuntu/text-input-v1-protocol.c platform/linux_text/linux_text.c \
    -o "$build_dir/$fixture-test" \
    $(pkg-config --cflags --libs wayland-client wayland-cursor wayland-egl egl glesv2 xkbcommon) \
    -lpthread -lm
  env -u DISPLAY -u WAYLAND_DISPLAY "$build_dir/$fixture-test"
done
