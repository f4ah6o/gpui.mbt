#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The native macOS demos require macOS and the Xcode command-line tools.' >&2
  exit 2
fi

MODE=run
DEMO=quad
TARGET_DIR="$ROOT_DIR/_build"
TEST_HOOKS=0
while (($#)); do
  case "$1" in
    run|--smoke|--build|--debug|--logs|--telemetry|--verify)
      MODE="$1"
      shift
      ;;
    --demo)
      if (($# < 2)); then
        echo 'usage: $0 [--demo quad|text-field] [--build|--smoke|--debug|--logs|--telemetry|--verify] [--test-hooks] [--target-dir PATH]' >&2
        exit 2
      fi
      DEMO="$2"
      shift 2
      ;;
    --target-dir)
      if (($# < 2)); then
        echo 'missing path after --target-dir' >&2
        exit 2
      fi
      TARGET_DIR="$2"
      shift 2
      ;;
    --test-hooks)
      TEST_HOOKS=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo 'usage: $0 [--demo quad|text-field] [--build|--smoke|--debug|--logs|--telemetry|--verify] [--test-hooks] [--target-dir PATH]' >&2
      exit 2
      ;;
  esac
done

case "$DEMO" in
  quad)
    PACKAGE=examples/native_macos
    APP_NAME=GpuiNative
    BINARY_NAME=native_macos
    ;;
  text-field)
    PACKAGE=examples/macos_text_field
    APP_NAME=GpuiTextField
    BINARY_NAME=macos_text_field
    ;;
  *)
    echo "unsupported demo: $DEMO (expected quad or text-field)" >&2
    exit 2
    ;;
esac
if [[ "$TEST_HOOKS" == 1 && "$DEMO" != text-field ]]; then
  echo '--test-hooks is available only for --demo text-field.' >&2
  exit 2
fi

if [[ "$TARGET_DIR" != /* ]]; then
  TARGET_DIR="$ROOT_DIR/$TARGET_DIR"
fi
mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"

MACOS_BUILD_DIR="$TARGET_DIR/macos"
APP_BUNDLE="$MACOS_BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
if [[ "$DEMO" == quad ]]; then
  PID_FILE="$MACOS_BUILD_DIR/demo.pid"
  LOG_FILE="$MACOS_BUILD_DIR/demo.log"
  BUNDLE_ID=org.gpui.mbt.native-demo
else
  PID_FILE="$MACOS_BUILD_DIR/text-field.pid"
  LOG_FILE="$MACOS_BUILD_DIR/text-field.log"
  BUNDLE_ID=org.gpui.mbt.text-field-demo
fi

mkdir -p "$MACOS_BUILD_DIR"
# Stop only an instance launched from this worktree, avoiding other checkouts.
if [[ -f "$PID_FILE" ]]; then
  PREVIOUS_PID="$(cat "$PID_FILE")"
  if [[ "$PREVIOUS_PID" =~ ^[0-9]+$ ]] && ps -p "$PREVIOUS_PID" -o command= | rg -F "$APP_BINARY" >/dev/null; then
    kill "$PREVIOUS_PID" || true
  fi
fi

mkdir -p "$FRAMEWORKS_DIR" "$(dirname "$APP_BINARY")"
# Bash 3.2 treats an empty array as unset under nounset. Keep the common
# arguments in the array so normal builds never expand an empty array.
CLANG_FLAGS=(-dynamiclib -fobjc-arc -Wall -Wextra -Werror)
if [[ "$TEST_HOOKS" == 1 ]]; then
  CLANG_FLAGS+=(-DGPUI_TESTING)
fi
xcrun clang "${CLANG_FLAGS[@]}" \
  platform/macos/native.m platform/macos_text/core_text.c \
  -framework AppKit -framework QuartzCore -framework Metal \
  -framework CoreText -framework CoreGraphics \
  -o "$FRAMEWORKS_DIR/libgpui_macos.dylib"
moon build --target native --deny-warn --target-dir "$TARGET_DIR" "$PACKAGE"
BUILT_BINARY="$TARGET_DIR/native/debug/build/$PACKAGE/$BINARY_NAME.exe"
if [[ ! -x "$BUILT_BINARY" ]]; then
  echo "MoonBit build did not produce executable: $BUILT_BINARY" >&2
  exit 1
fi
cp "$BUILT_BINARY" "$APP_BINARY"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>${MACOSX_DEPLOYMENT_TARGET:-13.0}</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

export GPUI_MACOS_LIBRARY="$FRAMEWORKS_DIR/libgpui_macos.dylib"
BUILT_BINARY_SHA256="$(shasum -a 256 "$APP_BINARY" | awk '{print $1}')"
if [[ -n "${GPUI_FIELD_MACOS_BINARY_SHA256:-}" && "$GPUI_FIELD_MACOS_BINARY_SHA256" != "$BUILT_BINARY_SHA256" ]]; then
  echo 'GPUI_FIELD_MACOS_BINARY_SHA256 does not match the freshly built executable.' >&2
  exit 1
fi
export GPUI_FIELD_MACOS_BINARY_SHA256="${GPUI_FIELD_MACOS_BINARY_SHA256:-$BUILT_BINARY_SHA256}"
export GPUI_FIELD_MACOS_SOURCE_REVISION="${GPUI_FIELD_MACOS_SOURCE_REVISION:-$(git rev-parse HEAD)}"
export GPUI_FIELD_MACOS_SOURCE_TREE="${GPUI_FIELD_MACOS_SOURCE_TREE:-$(git rev-parse 'HEAD^{tree}')}"

case "$MODE" in
  --build)
    echo "$APP_BUNDLE"
    ;;
  --smoke)
    "$APP_BINARY" --smoke
    ;;
  --debug)
    lldb -- "$APP_BINARY"
    ;;
  run|--verify|--logs|--telemetry)
    "$APP_BINARY" > "$LOG_FILE" 2>&1 &
    APP_PID=$!
    echo "$APP_PID" > "$PID_FILE"
    if [[ "$MODE" == --verify ]]; then
      sleep 1
      kill -0 "$APP_PID"
    elif [[ "$MODE" == --logs || "$MODE" == --telemetry ]]; then
      tail -f "$LOG_FILE"
    fi
    ;;
esac
