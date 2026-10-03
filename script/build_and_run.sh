#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The native macOS demo requires macOS and the Xcode command-line tools.' >&2
  exit 2
fi
case "$MODE" in run|--smoke|--build|--debug|--logs|--telemetry|--verify) ;; *) echo "usage: $0 [--build|--smoke|--debug|--logs|--telemetry|--verify]" >&2; exit 2;; esac
APP_BUNDLE="$ROOT_DIR/_build/macos/GpuiNative.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/GpuiNative"
# Stop only a process launched from this worktree, avoiding other checkouts.
if [[ -f _build/macos/demo.pid ]]; then
  PREVIOUS_PID="$(cat _build/macos/demo.pid)"
  if [[ "$PREVIOUS_PID" =~ ^[0-9]+$ ]] && ps -p "$PREVIOUS_PID" -o command= | rg -F "$APP_BINARY" >/dev/null; then
    kill "$PREVIOUS_PID" || true
  fi
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks"
xcrun clang -dynamiclib -fobjc-arc -Wall -Wextra -Werror \
  platform/macos/native.m -framework AppKit -framework QuartzCore -framework Metal \
  -o "$APP_BUNDLE/Contents/Frameworks/libgpui_macos.dylib"
moon build --target native --deny-warn
cp _build/native/debug/build/examples/native_macos/native_macos.exe "$APP_BINARY"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GpuiNative</string>
<key>CFBundleIdentifier</key><string>org.gpui.mbt.native-demo</string>
<key>CFBundleName</key><string>GpuiNative</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
export GPUI_MACOS_LIBRARY="$APP_BUNDLE/Contents/Frameworks/libgpui_macos.dylib"
case "$MODE" in
  --build) echo "$APP_BUNDLE" ;;
  --smoke) "$APP_BINARY" --smoke ;;
  --debug) lldb -- "$APP_BINARY" ;;
  run|--verify|--logs|--telemetry)
    "$APP_BINARY" > _build/macos/demo.log 2>&1 &
    echo "$!" > _build/macos/demo.pid
    if [[ "$MODE" == --verify ]]; then sleep 1; kill -0 "$(cat _build/macos/demo.pid)";
    elif [[ "$MODE" == --logs || "$MODE" == --telemetry ]]; then tail -f _build/macos/demo.log; fi
    ;;
esac
