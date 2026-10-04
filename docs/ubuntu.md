# Ubuntu Wayland native slice

Issue [0007](../issues/open/0007-ubuntu-native-backend.md) now has a first native
implementation, not a complete Ubuntu support claim. `platform/` defines the
shared host/window/event/presentation contract. `ubuntu/` implements it with a
repository-owned C boundary, Wayland xdg-shell, and EGL/OpenGL ES 2. Core,
element, scene, and primitives do not import native code.

## Run a native MoonBit app

On Ubuntu 24.04 x86-64, install the system toolchain:

```sh
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libwayland-dev wayland-protocols \
  libegl1-mesa-dev libgles2-mesa-dev libxkbcommon-dev libgl1-mesa-dri \
  adwaita-icon-theme weston
sh scripts/prepare_ubuntu.sh
moon run examples/ubuntu --target native
```

Use MoonBit `0.10.14+7d59c7ec9`, as pinned in CI. Run from a Wayland session
with `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` set by the desktop. If
`XDG_SESSION_TYPE` is present it must be `wayland`; an X11 session is explicitly
rejected even if it exports a Wayland socket. Missing session/protocol support
returns `UnsupportedCapability`. Connection failure returns `NativeFailure`.
The demo shows a dark background and blue quad; Escape or a compositor close
request exits. `GPUI_UBUNTU_SMOKE=1` exits after a completed native frame.

System xdg-shell bindings are generated locally, never copied from GPUI or
vendored. Run preparation before any native build/test. `moon check --target all`
checks the backend only for native; portable targets keep using the shared
packages. Native builds currently require the Ubuntu system libraries; the
backend is not a native macOS/Windows build target.

## Implemented behavior

- One UI-owner host and one live window at a time. A second host/window returns
  `Busy`. Startup and initial configure wait at most roughly three seconds each.
  Failed initialization/creation cleans partial resources before returning.
- The shared `platform.Backend` uses `wake`, `next_event(timeout_ms?)`,
  `request_exit`, and idempotent `stop`. `ubuntu.Host::dispatch(timeout_ms)` is
  a target-specific batch convenience built over the same copied event queue.
  The owner thread can wake before dispatch; wakeups coalesce in an eventfd. UI operations
  reject other threads. Cross-thread command enqueue is still pending.
- Logical window IDs are monotonically allocated and never reused. They live in
  `platform/` until a higher-level core window API exists. Stale surface/title/
  size operations return `StaleHandle`. Explicit destroy is idempotent, drains
  one outstanding compositor frame callback with a bounded wait before releasing
  EGL/Wayland resources, drops queued callbacks for that generation, and emits
  one final `Destroyed` event.
- xdg toplevel configure/ack, UTF-8 titles, client logical size updates, close
  requests, and surface-before-window teardown. Wayland compositors control
  maximized/fullscreen dimensions; `set_size` does not force compositor policy.
- The EGLDisplay associated with the externally owned Wayland display is kept
  initialized for the host lifetime. Window destruction releases only the
  per-window EGLSurface/wl_egl_window; explicit renderer recovery recreates the
  context/surface without repeatedly terminating the shared EGLDisplay.
- SceneSnapshot v1 quads, affine transforms, opacity, paint order, and intersected
  rectangle clips in logical viewport coordinates. Resources and nonzero
  viewport origins return `UnsupportedCapability`; text/path/image rendering is
  pending. Rendering uses premultiplied alpha with sRGB channel values; advanced
  color management is pending.
- Presentation dispatches available protocol events, then verifies snapshot
  size/scale against the latest acknowledged configuration. A stale snapshot or
  outstanding frame returns `Busy`. Frame callbacks produce the shared `FrameCompleted`
  (compositor readiness, not a hardware presentation timestamp).
- Basic logical pointer movement/buttons/scroll, xkb logical keys/modifiers, and
  keyboard focus. Key repeat, committed text, IME and input-method composition
  are pending; keyboard events must not be interpreted as IME commits.
- Output enter/leave and maximum entered-output integer buffer scale. Scale is
  queued before later input/frame events and EGL buffers resize to physical
  pixels. Fractional scale, public display metadata and multi-display E2E are
  pending. Output tracking is bounded to 16 outputs; this slice targets one CI
  output and does not claim broader desktop coverage.
- Bounded 1024-event FIFO. Overflow returns `ResourceExhausted` and quiesces the
  host instead of silently losing input. Sequence exhaustion also fails closed.
- Clipboard uses the core Wayland data-device protocol for UTF-8 plain text.
  Reading consumes the compositor's current selection through a bounded
  nonblocking pipe transfer (16 MiB, three-second timeout); writing requires a
  real pointer-button or keyboard-press serial from this seat. Missing offers,
  unsupported MIME types, or a missing recent input serial return
  `UnsupportedCapability`. No process-local clipboard cache is used.
- Cursor selection uses `libwayland-cursor` and the installed Xcursor theme for
  arrow, pointing-hand and text cursors. Applying a cursor requires a current
  pointer-enter serial; absent theme assets or pointer focus are reported as
  `UnsupportedCapability`. The standard Ubuntu Adwaita cursor theme is used by
  the headless E2E image. Clipboard and cursor are optional seat services: a
  headless compositor may not expose a seat, data device, or pointer. The E2E
  records each service as available or unsupported and checks that unavailable
  services fail with `UnsupportedCapability`; this does not skip window,
  rendering, resize, recovery, or lifecycle checks.
- Explicit `recover_renderer` recreates EGL resources without replacing the
  logical window. Surface/device errors are typed. Automatic three-attempt
  recovery and compositor reconnection remain pending. A display disconnect is
  terminal for that host: dispatch reports `NativeFailure`, quiesces, and the
  caller stops it and can start a new host once a session is available.

Text-input/IME, semantic accessibility, menus, background enqueue, timers,
fractional scaling, and broader service capability negotiation remain roadmap
work. Native clipboard and cursor protocols are implemented, while a
cross-client clipboard roundtrip and visible cursor smoke under an input-capable
desktop remain unverified. Native handles and borrowed buffers do not escape
the backend. Call `stop` explicitly; dropping a MoonBit Host is not an implicit
native shutdown.

## Test and support matrix

Run the native gates with:

```sh
sh scripts/test_ubuntu.sh
```

The runner starts isolated Weston GL headless sessions at integer scales 1 and
2, runs opt-in MoonBit E2E plus the native executable, and runs a strict-warning
C harness. The harness verifies GPU pixels before swap for paint order,
translation, clip exclusion and opacity, input source ordering, wrong-thread
rejection, clipboard transfer chunking and closed-reader handling, clipboard
and cursor protocol discovery, typed clipboard rejection before an input
serial, 40 window cycles, resize rejection, renderer recreation, stable file
descriptor counts after warmup, injected surface loss, bounded input-storm
overflow, and compositor termination handling. It does not claim an actual
external clipboard selection/read roundtrip or visible cursor change; the
headless compositor has no automated physical input source. The MoonBit
E2E performs 24 window cycles and resize bursts plus the reusable shared host
conformance gate in `testing/backend/`. Normal `moon test` does not run native
E2E unless `GPUI_UBUNTU_E2E=1`; its pass count alone is not E2E evidence. Logs are
written to `_build/ubuntu-e2e/`.

Set `GPUI_BENCH_UBUNTU=1` when invoking the runner to emit 30
`GPUI_BENCH_SAMPLE` records per scale. They measure first-frame completion after
injected EGL renderer recovery, with the current `GL_RENDERER` value included;
the reporter parses test stdout separately and stores test stderr in a sidecar
log referenced by the JSON report. This keeps compositor diagnostics out of the
strict sample records. The samples measure a headless llvmpipe recovery path, not
a desktop frame-rate claim.

| Evidence path | Distro / compositor | Graphics / session | Evidence state |
| --- | --- | --- | --- |
| Configured native CI | Ubuntu 24.04 x86-64; Ubuntu Weston 13 package | Weston headless GL kiosk shell; Mesa llvmpipe; integer scales 1/2 | Hosted rerun 2026-10-04: MoonBit E2E passed 4/4 with 24 window cycles; C E2E passed lifecycle, readback, input-order, scale, recovery and resource checks at both scales, emitting 30 timing samples per scale. Report collection failed when merged stderr split a sample record; the collector now keeps stderr in a sidecar log and parses stdout separately. Reporter rerun pending |
| Local implementation validation | Debian 13 x86-64; Weston 14.0.2; Wayland 1.23.1; wayland-protocols 1.44; xkbcommon 1.7.0; Mesa 25.0.7 | Strict C compile and clipboard transfer helper passed; Weston headless launch blocked | Full native E2E unrun: the runner observed Weston fail to add its socket with `No such file or directory`; a separate AF_UNIX bind diagnostic was denied with `EPERM` in this environment |
| Real Ubuntu desktop | Ubuntu 24.04 GNOME Wayland/Mutter | Desktop GPU, IME and assistive technology | Pending |

CI pins the distro and MoonBit release; Ubuntu archive package patch versions
are recorded by `dpkg-query` on each run, not frozen. CI's Weston package major
is 13. The headless kiosk compositor does not provide automated physical input;
MoonBit and C E2E report clipboard/cursor availability instead of assuming
those seat services exist. A successful headless GL
software rendering does not prove physical GPU performance or real desktop
IME/accessibility behavior. File descriptor stability and owned-object checks
do not prove bounded driver memory in a sustained production run.

No Tier 1/Tier 2 claim is made. Ubuntu-native Tier 0 evidence still requires an
observed Ubuntu build. X11 and XWayland remain unimplemented and untested. Issue
0007 stays open for C's remaining services, D/E, full F, and real Ubuntu/Tier 1
G gates.

## Native dependency inventory and exception

This is the narrow native system-library exception for the first Ubuntu slice.
There are no new third-party MoonBit runtime packages or Rust GPUI dependencies.
All native libraries are introduced and owned by `ubuntu/`; their headers and
shared libraries come from the Ubuntu system package archive. Development tools
(Weston, wayland-scanner, pkg-config, C compiler) are not application runtime
imports. Generated protocol code inherits the installed protocol XML's license.

| Library / API | License | Purpose | Upgrade source / failure behavior |
| --- | --- | --- | --- |
| Wayland client, wayland-cursor, wayland-egl, xdg-shell | MIT | Display, native window, cursor assets, EGL window wrapper | Ubuntu libwayland/wayland-protocols and installed Xcursor theme; typed startup/dispatch/service errors |
| EGL, GLESv2 dispatch; Mesa implementation | MIT / Mesa component licenses | GPU context, surface, quad draw and swap | Ubuntu GLVND/Mesa; typed SurfaceLost/DeviceLost, explicit recreation |
| xkbcommon | MIT | System keymap and logical key/modifier translation | Ubuntu libxkbcommon; typed map/allocation errors |
| libc, pthread, poll, eventfd, mmap | LGPL-2.1-or-later (glibc) | Owned buffers, owner-thread checks, loop wake and keymap mapping | Ubuntu glibc; typed NativeFailure/ResourceExhausted |

The local and CI dependency/package graph must be recorded again for release,
along with resolved patch versions and license evidence. This inventory is not
an audited production-release graph or approval of unrelated native libraries.
