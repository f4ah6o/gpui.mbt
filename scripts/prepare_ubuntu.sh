#!/bin/sh
# Generate protocol bindings from the installed system wayland-protocols package.
set -eu
cd "$(dirname "$0")/.."
protocol_dir=${WAYLAND_PROTOCOLS_DIR:-$(pkg-config --variable=pkgdatadir wayland-protocols)}
wayland-scanner client-header "$protocol_dir/stable/xdg-shell/xdg-shell.xml" ubuntu/xdg-shell-client-protocol.h
wayland-scanner private-code "$protocol_dir/stable/xdg-shell/xdg-shell.xml" ubuntu/xdg-shell-protocol.c
wayland-scanner client-header "$protocol_dir/unstable/text-input/text-input-unstable-v1.xml" ubuntu/text-input-v1-client-protocol.h
wayland-scanner private-code "$protocol_dir/unstable/text-input/text-input-unstable-v1.xml" ubuntu/text-input-v1-protocol.c
