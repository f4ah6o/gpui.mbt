#!/bin/sh
# Headless PangoFT2 geometry tests for the Linux-only text adapter.
set -eu
cd "$(dirname "$0")/.."

pkg_config=${PKG_CONFIG:-pkg-config}
if ! "$pkg_config" --exists pangoft2 fontconfig; then
  echo "PangoFT2 and Fontconfig development files are required (pkg-config modules: pangoft2 fontconfig)" >&2
  exit 1
fi
printf 'pkg-config versions: '
"$pkg_config" --modversion pangoft2 fontconfig | tr '\n' ' '
printf '\n'
printf 'pkg-config cflags/libs: '
"$pkg_config" --cflags --libs pangoft2 fontconfig

fontconfig_file=${GPUI_LINUX_TEXT_FONTCONFIG_FILE:-"$PWD/tests/linux_text/fonts.conf"}
if [ ! -r "$fontconfig_file" ]; then
  echo "Fontconfig fixture configuration is not readable: $fontconfig_file" >&2
  exit 1
fi
if ! command -v fc-match >/dev/null 2>&1; then
  echo "fontconfig's fc-match utility is required to verify test fixtures" >&2
  exit 1
fi

build_dir=${GPUI_LINUX_TEXT_BUILD_DIR:-_build/linux-text}
case "$build_dir" in
  /*) build_root=$build_dir ;;
  *) build_root="$PWD/$build_dir" ;;
esac
mkdir -p "$build_root/xdg-cache"
export FONTCONFIG_FILE="$fontconfig_file"
FONTCONFIG_PATH=$(dirname "$fontconfig_file")
export FONTCONFIG_PATH
export XDG_CACHE_HOME="$build_root/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"

check_font() {
  requested=$1
  expected_family=$2
  actual=$(fc-match -f '%{family}|%{file}\n' "$requested")
  actual_family=${actual%%|*}
  actual_file=${actual#*|}
  case "$actual_family" in
    "$expected_family"|"$expected_family,"*) ;;
    *)
      echo "Font fixture mismatch for '$requested': expected family '$expected_family', got '$actual_family' ($actual_file)" >&2
      exit 1
      ;;
  esac
  if [ -z "$actual_file" ]; then
    echo "Font fixture path is empty for '$requested'" >&2
    exit 1
  fi
  printf 'font fixture: %s -> %s [%s]\n' "$requested" "$actual_family" "$actual_file"
}
check_font 'DejaVu Sans' 'DejaVu Sans'
check_font 'Noto Sans CJK JP' 'Noto Sans CJK JP'
check_font 'Noto Color Emoji' 'Noto Color Emoji'

# Exercise the private raster ABI directly as well as its MoonBit provider.
# The same compiler wrapper used by native packages supplies real distro
# PangoFT2/Fontconfig cflags and link libraries to this consumer harness.
script/linux_text_cc.py -std=c11 -Wall -Wextra -Werror \
  tests/linux_text/raster_test.c platform/linux_text/linux_text.c \
  -o "$build_root/raster-test" -pthread -lm
env -u DISPLAY -u WAYLAND_DISPLAY "$build_root/raster-test"

script/linux_text_cc.py -std=c11 -Wall -Wextra -Werror \
  tests/linux_text/field_admission_test.c platform/linux_text/linux_text.c \
  -o "$build_root/field-admission-test" -pthread -lm
env -u DISPLAY -u WAYLAND_DISPLAY "$build_root/field-admission-test"

# A private XDG cache keeps concurrent jobs isolated.
env -u DISPLAY -u WAYLAND_DISPLAY \
  moon test --package f4ah6o/gpui/platform/linux_text --target native \
    --deny-warn --no-parallelize
