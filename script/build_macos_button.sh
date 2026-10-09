#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
MODE="run"
TARGET_DIR="$ROOT_DIR/_build/macos-button"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --build)
      MODE="build"
      shift
      ;;
    --run)
      MODE="run"
      shift
      ;;
    --e2e)
      MODE="e2e"
      shift
      ;;
    --target-dir)
      if [[ "$#" -lt 2 ]]; then
        echo '--target-dir requires a path.' >&2
        exit 2
      fi
      TARGET_DIR="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--build|--run|--e2e] [--target-dir PATH]" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The native macOS Button fixture requires macOS and Xcode command-line tools.' >&2
  exit 2
fi

case "$TARGET_DIR" in
  /*) ;;
  *) TARGET_DIR="$ROOT_DIR/$TARGET_DIR" ;;
esac
APP_BUNDLE="$TARGET_DIR/GpuiMacButton.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/GpuiMacButton"
APP_LIBRARY="$APP_BUNDLE/Contents/Frameworks/libgpui_macos.dylib"
PID_FILE="$TARGET_DIR/button.pid"
LOG_FILE="$TARGET_DIR/button.log"
MOON_TARGET_DIR="$TARGET_DIR/moon"

mkdir -p "$TARGET_DIR"
if [[ -f "$PID_FILE" ]]; then
  PREVIOUS_PID="$(cat "$PID_FILE")"
  if [[ "$PREVIOUS_PID" =~ ^[0-9]+$ ]] &&
    ps -p "$PREVIOUS_PID" -o command= | grep -F "$APP_BINARY" >/dev/null; then
    kill "$PREVIOUS_PID"
  fi
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks"
if [[ "$MODE" == e2e ]]; then
  xcrun clang -dynamiclib -DGPUI_TESTING -fobjc-arc -Wall -Wextra -Werror \
    platform/macos/native.m platform/macos_text/core_text.c \
    -framework AppKit -framework QuartzCore -framework Metal \
    -framework CoreText -framework CoreGraphics -framework CoreFoundation \
    -o "$APP_LIBRARY"
else
  xcrun clang -dynamiclib -fobjc-arc -Wall -Wextra -Werror \
    platform/macos/native.m platform/macos_text/core_text.c \
    -framework AppKit -framework QuartzCore -framework Metal \
    -framework CoreText -framework CoreGraphics -framework CoreFoundation \
    -o "$APP_LIBRARY"
fi

moon build --target native --deny-warn --target-dir "$MOON_TARGET_DIR" \
  examples/macos_button
cp "$MOON_TARGET_DIR/native/debug/build/examples/macos_button/macos_button.exe" \
  "$APP_BINARY"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GpuiMacButton</string>
<key>CFBundleIdentifier</key><string>org.gpui.mbt.macos-button</string>
<key>CFBundleName</key><string>GpuiMacButton</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

if [[ "$MODE" == build ]]; then
  echo "$APP_BUNDLE"
elif [[ "$MODE" == e2e ]]; then
  GPUI_NATIVE_E2E=1 GPUI_MACOS_LIBRARY="$APP_LIBRARY" "$APP_BINARY" --e2e
else
  GPUI_MACOS_LIBRARY="$APP_LIBRARY" "$APP_BINARY" >"$LOG_FILE" 2>&1 &
  APP_PID="$!"
  echo "$APP_PID" > "$PID_FILE"
  echo "Launched $APP_BUNDLE (pid $APP_PID); log: $LOG_FILE"
fi
