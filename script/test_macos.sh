#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The macOS native checks require macOS and the Xcode command-line tools.' >&2
  exit 2
fi

MODE="${1:-all}"
shift || true
TEST_TARGET_DIR="$ROOT_DIR/_build/macos-validation"
while (($#)); do
  case "$1" in
    --target-dir)
      if (($# < 2)); then
        echo 'missing path after --target-dir' >&2
        exit 2
      fi
      TEST_TARGET_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
if [[ "$TEST_TARGET_DIR" != /* ]]; then
  TEST_TARGET_DIR="$ROOT_DIR/$TEST_TARGET_DIR"
fi
mkdir -p "$TEST_TARGET_DIR"
case "$MODE" in
  all|--build-only|--text-field) ;;
  *)
    echo "usage: $0 [all|--build-only|--text-field] [--target-dir PATH]" >&2
    exit 2
    ;;
esac

build_native_runner() {
  mkdir -p "$TEST_TARGET_DIR/native-e2e"
  xcrun clang -fobjc-arc -Wall -Wextra -Werror \
    -DGPUI_TESTING tests/native/macos_e2e.m platform/macos_text/core_text.c \
    -framework AppKit -framework QuartzCore -framework Metal \
    -framework CoreText -framework CoreGraphics \
    -o "$TEST_TARGET_DIR/native-e2e/macos_e2e"
}

run_text_field_checks() {
  moon test platform/macos --target native --deny-warn \
    --target-dir "$TEST_TARGET_DIR/platform-macos"
  moon test platform/macos_text --target native --deny-warn \
    --target-dir "$TEST_TARGET_DIR/platform-macos-text"
  moon test --package f4ah6o/gpui/examples/macos_text_field \
    --target native --deny-warn --target-dir "$TEST_TARGET_DIR/text-field/model"
  ./script/build_and_run.sh --demo text-field --test-hooks --build \
    --target-dir "$TEST_TARGET_DIR/text-field/build"
}

if [[ "$MODE" == --build-only ]]; then
  build_native_runner
  ./script/build_and_run.sh --demo quad --build \
    --target-dir "$TEST_TARGET_DIR/quad-build"
  run_text_field_checks
  exit 0
fi

if [[ "$MODE" == --text-field ]]; then
  run_text_field_checks
  exit 0
fi

build_native_runner
"$TEST_TARGET_DIR/native-e2e/macos_e2e"
./script/build_and_run.sh --demo quad --smoke \
  --target-dir "$TEST_TARGET_DIR/quad-smoke"
run_text_field_checks
