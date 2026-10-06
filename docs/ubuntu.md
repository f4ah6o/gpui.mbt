# Ubuntu Wayland native slice

Issue [0007](../issues/open/0007-ubuntu-native-backend.md) now has a first native
implementation, not a complete Ubuntu support claim. `platform/` defines the
shared host/window/event/presentation contract. `ubuntu/` implements it with a
repository-owned C boundary, Wayland xdg-shell, and EGL/OpenGL ES 2. Core,
element, scene, and primitives do not import native code.

## Run a native MoonBit app

For a Debian 13 amd64 cloud desktop with an X11 outer session, the
[reproducible desktop profile](../infra/linux-desktop/README.md) records pinned
official packages, the matching MoonBit/core, reset recovery, diagnostics,
nested Weston launch, and separate native-key/GTK Japanese smoke procedures.
Its prefix-only Mozc relocation limit is explicit; a GTK baseline does not
implement or qualify GPUI host IME support.

On Ubuntu 24.04 x86-64, install the system toolchain:

```sh
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libwayland-dev wayland-protocols \
  libegl1-mesa-dev libgles2-mesa-dev libxkbcommon-dev libgl1-mesa-dri \
  libpango1.0-dev libfontconfig1-dev fonts-dejavu-core fonts-noto-cjk \
  fonts-noto-color-emoji adwaita-icon-theme weston wayland-utils
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

`platform/linux_text/` provides the PangoFT2/Fontconfig measurement adapter and
private grayscale-mask raster ABI used by Ubuntu text-frame drawing. The
PangoFT2/Fontconfig development packages are now also required to build the
Ubuntu native renderer. See the [Linux text guide](linux-text.md) for the
measurement contract, raster scope, and separate headless test command.

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
  rectangle clips in logical viewport coordinates. Supported text items draw in
  order with quads using grayscale A8 masks; per-frame unsupported and resource
  checks still apply. Other unsupported resources, nonzero viewport origins,
  paths, and images return `UnsupportedCapability`. Rendering uses premultiplied
  alpha with sRGB channel values; advanced color management is pending.
- Presentation dispatches available protocol events, then verifies snapshot
  size/scale against the latest acknowledged configuration. A stale snapshot or
  outstanding frame returns `Busy`. Frame callbacks produce the shared `FrameCompleted`
  (compositor readiness, not a hardware presentation timestamp).
- Basic logical pointer movement/buttons/scroll, xkb logical keys/modifiers, and
  keyboard focus. The separate opt-in `DirectKeyboardText` route supplies locale
  Compose commits and bounded key repeat from a version-4 `repeat_info` policy;
  seats below v4, missing policy and rate 0 do not repeat. Ordinary keyboard
  events are not IME commits. Public `TextInput`/IME and input-method composition
  remain pending.
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

### Grayscale text-frame subset

The Ubuntu host advertises the new
`platform.Capability::GrayscaleTextFrames` discovery flag. This means the host
implements a bounded subset of `SceneSnapshot` v1 text drawing; it does not
promise that every frame is supported and does not imply committed text input,
an editable control, caret or selection UI, composition, or IME. Color glyphs
are detected during preflight and reject the entire frame with a typed
unsupported result before presentation. The Linux text adapter exposes
`require_grayscale_raster() -> Result[Unit, LinuxTextError]`; Ubuntu calls it
to admit only a linked private raster ABI with Pango >= 1.50 glyph-color
metadata. An unavailable ABI/runtime returns `UnsupportedRaster` at the
adapter boundary and maps to typed `UnsupportedCapability` for the host.
macOS and Windows keep their existing text rejection behavior.

The legacy `TextItem` uses the generic `sans` font at its supplied size; its
public schema has no font-family field. Caret/hit measurements used by an
editable control must request the same `sans` family, size, and context to
match this drawing path. Measurements of another explicit family do not imply
geometry parity. Text is shaped and rasterized into grayscale A8 masks at
logical resolution; the packed, top-down masks upload as `GL_ALPHA` with
`GL_UNPACK_ALIGNMENT=1`, clamp-to-edge and no mipmaps. GLES uses `GL_LINEAR`
filtering to apply existing scene transforms/scaling to those masks and blends
the premultiplied text color using the existing `ONE,
ONE_MINUS_SRC_ALPHA` mode. Enlarged text can be softer than device-resolution
rasterization because this slice does not use device-resolution hinting.
Legacy `TextItem` bounds clip in item-local coordinates, while viewport clip
chains continue to use viewport-space scissors. The separate plain
`TextRunItem` adds an item-local `text_origin` independent of its exact local
`bounds` clip; clipping is performed before the affine transform. The scene
envelope remains schema v1, and legacy `TextItem` meaning/JSON remain
unchanged. ABI3 is the 25-double origin-aware frame record: it retains ABI2's
23-field prefix, appends origin x/y, and uses kind 2 for `TextRunItem`; quad and
legacy text records must use zero origin values. Raster ABI v2 returns the
legacy mask plus UV crop coordinates in a separate v2 result, preserving the
v1 mask struct and entry semantics. The v2 tile includes one sampling texel at
interior crop edges, clipped to full pixel ink; exact visible geometry and UV
crop stay independent of that halo. All tile and A8 budgets include it before
allocation. The v1/legacy renderer explicitly keeps no-halo storage and
filtering. V2 rejects clip/ink endpoint or extent roundtrip error above a fixed
1/4096 logical pixel before allocating, including huge origins later cancelled
by a transform. Consumers that do not understand the new
item must reject it, and public exhaustive matches need an explicit
`TextRunItem` arm. This remains a narrow plain run, not portable shaping or a
richer general text contract.

The per-frame bounds are at most 256 text runs, 16,384 UTF-8 bytes per run,
1 MiB total UTF-8 bytes per frame, 512 logical pixels per font size, 2,048 by
2,048 pixels per mask tile, and 16 MiB of mask storage, also limited by the
actual `GL_MAX_TEXTURE_SIZE`. A private geometry guard also rejects with
`ResourceExhausted` when `(Unicode scalar count + 1) * font_size_px` exceeds
1,048,576 before rasterization. The existing total item cap remains. Invalid
UTF-16 containing a lone surrogate is rejected as `UnsupportedCapability`
during preflight, before UTF-8 encoding; it is neither replaced nor allowed to
panic. Inputs are rejected rather than truncated. All items and resources are
checked before the frame is cleared/submitted; the remaining 16 MiB mask budget
is checked before each next mask allocation. Unsupported, invalid, and
resource-limit failures preserve the previously displayed frame. Staged masks
are released on all exit paths. Actual surface/device loss still follows the
backend's typed recovery path; preflight preservation does not guarantee a
prior image across device loss. The `SceneSnapshot` envelope version remains
v1 and permits this item-variant extension. See
[the full Linux text boundary](linux-text.md#ubuntu-grayscale-scene-text).

This renderer slice merged in [PR28](https://github.com/gpui-mbt/gpui.mbt/pull/28) as
`3cc72f548dc6138e17f949efad8eae92c70a1cb0`. The headless C mask
consumer passes normally and under ASan+UBSan with leak detection disabled on
Debian 13/PangoFT2 1.56.3/Fontconfig 2.15.0. The leak-enabled LeakSanitizer
run reports that it does not work under ptrace in this environment; this is
not a leak pass or a product leak failure. The [PR28 Ubuntu run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37346110201)
passed real Weston/llvmpipe text and quad readback, clipping/transform/order,
late invalid/color/resource frame preservation, empty text, recovery and
cleanup at 1x/2x; MoonBit E2E passed 5/5 per scale. Its reviewed tree is
`14b8ce67796bcb08e08b60d8fcdb495afb7257b4`. Test-only Latin/Japanese clipping/
overlap PPM artifacts retain exact executed commit/scale/renderer context.
Local GPU execution remains unrun because AF_UNIX stream socket creation
returns `EPERM`. This software-rendered proof does not establish broader
platform support or text performance qualification.

The bounded field and origin-aware drawing are merged in
[PR30](https://github.com/gpui-mbt/gpui.mbt/pull/30) and
[PR31](https://github.com/gpui-mbt/gpui.mbt/pull/31). The current baseline is main
`73e70822841024a7131c54fb4529cd40186d529c`, tree `108cf4e9`. The
[PR31 Ubuntu run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37392223946)
passed real `Host.present` and injected control-to-renderer text/caret/selection/
scroll/overhang checks under Weston/llvmpipe at 1x/2x. Actual-font headless field
and negative-mask tests also pass, including composed/decomposed accents and
scrolling. The shared geometry uses one outward-rounded logical/ink union with
carets contained in the logical line for admission, paint, hit test, and scroll.
The current undo/redo addition has local model/provider and transaction coverage;
its new hosted rendering cases remain pending for this change. The field remains
single-line LTR, rejects unknown/color glyphs and reflow/resource-limit cases,
and uses logical-resolution masks that may soften under scaling. Direct native
committed-text ingress exists, but actual compositor-delivered typing, Japanese
IME, held-key repeat timing, general bidi and drag selection remain unqualified.
The bounded direct-repeat implementation has deterministic mocked callback/queue
and model/controller coverage only; actual compositor repeat is **UNRUN**. The
[known hosted-compositor observation](#known-hosted-compositor-observation)
retains the unchanged-main first failure and successful retry without assigning
a cause. See the [field guide](linux-text-field.md) for full limits and evidence
tiers.

### Private direct-repeat limits

The seat bind is capped at v4. In active direct mode, a fresh repeatable physical
press caches its logical key and optional UTF-8 commit only when Compose did
not consume it. Synthetic `KeyPressed` records set `repeat=true`, while physical
presses set it false; release records are never synthesized. Available native
callbacks are dispatched first. Only an empty event queue admits a repeat, with
at most one atomic key/text group per native dispatch and no overdue catch-up.
The interval rounds up to milliseconds with a 1 ms minimum, including rates
above 1,000 Hz.

An unchanged compositor policy preserves the candidate; changed policy,
modifiers or layout cancel it until a fresh physical press. Focus, mode/epoch,
device/seat loss, matching release, close/release and fatal host failure also
cancel repeat. Compose is never fed by the timer. ABI2 slot 7 accepts exactly
0/1 for press tag 11 and requires 0 for release tag 12 and text tag 13; malformed
flags return typed `InvalidInput`. Pointer slot 7 remains y. Legacy input is
unchanged. This feature does not provide a general timer API, IME, coalesced
typing history or qualification of desktop repeat accuracy. See the
[field repeat contract](linux-text-field.md#bounded-direct-keyboard-repeat).

The bounded experimental field now paints visible caret/selection and scrolls,
but it is not a general control. Public TextInput/IME, semantic accessibility, menus,
background enqueue, timers, fractional scaling, and broader service capability
negotiation remain roadmap work. Native clipboard
and cursor protocols are implemented, while a
cross-client clipboard roundtrip and visible cursor smoke under an input-capable
desktop remain unverified. Native handles and borrowed buffers do not escape
the backend. Call `stop` explicitly; dropping a MoonBit Host is not an implicit
native shutdown.

## Test and support matrix

Run the native gates with:

```sh
sh scripts/test_ubuntu.sh
```

The E2E test tooling requires `wayland-utils` (`wayland-info`) in addition to
Weston and the native build dependencies above. `scripts/wait_wayland_ready.py`
allows up to 30 monotonic seconds for compositor startup and requires both a
live child and a successful protocol roundtrip; a socket alone is insufficient.
Missing probe, process exit, absent socket timeout and failed roundtrip timeout
are reported separately. This is test tooling, not an application runtime
dependency.

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
| Configured native CI | Ubuntu 24.04 x86-64; Ubuntu Weston 13 package | Weston headless GL kiosk shell; Mesa llvmpipe; integer scales 1/2 | Hosted run 2026-10-04 passed MoonBit E2E (4/4), C lifecycle/render/recovery checks at both scales, and 30 timing samples per scale. Measurement report completed with `no_baseline`; see [run and diagnostic results](performance.md#hosted-ubuntu-observation-2026-10-04). |
| PR28 grayscale text CI | Ubuntu 24.04 x86-64; Weston 13; PangoFT2 1.52.1; Fontconfig 2.15.0 | Weston headless GL kiosk shell; llvmpipe (LLVM 20.1.2); integer scales 1/2 | [Run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37346110201) passed headless raster, 5/5 MoonBit E2E per scale and C mixed-scene/preservation assertions; readback PPMs retained. Recovery timing report is `captured_live` + `no_baseline`, not text performance qualification. |
| PR30/31 field and origin CI | Ubuntu 24.04; Weston 13; declared sans/Pango fixture profile | Headless GL kiosk shell; llvmpipe; scales 1/2 | [PR31 exact-head run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37392223946) passed actual Host.present and nine injected accepted field frames plus origin/preflight preservation checks. Real keyboard delivery remains unrun; see compositor observation below. |
| Local implementation validation | Debian 13 x86-64; Weston 14.0.2; Wayland 1.23.1; wayland-protocols 1.44; xkbcommon 1.7.0; Mesa 25.0.7 | Strict C compile and clipboard transfer helper passed; Weston headless launch blocked | Full native E2E unrun: the runner observed Weston fail to add its socket with `No such file or directory`; a separate AF_UNIX socket-creation diagnostic returned `EPERM` in this environment |
| Real Ubuntu desktop | Ubuntu 24.04 GNOME Wayland/Mutter | Desktop GPU, IME and assistive technology | Pending |

### Known hosted-compositor observation

The merged field/origin main source `73e7082` was checked in
[Ubuntu run37393518087](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37393518087).
Attempt1 passed scale1, then scale2 lifecycle/stress dispatch reported native
failure with compositor exit139 and client reset/broken-pipe diagnostics.
The Weston log ended without a backtrace; the cause is unknown. One authorized
failed-job retry on the unchanged source passed both scales in attempt2.
Both artifacts/first-failure diagnostics were retained separately. This
establishes the declared profile's acceptance after retry, not a causal fix or
production stability. Device/surface/display loss retains the existing typed
recovery/stop behavior and does not promise prior pixels survive loss.

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

This is the narrow native system-library exception for the Ubuntu slice. There
are no new third-party MoonBit runtime packages or Rust GPUI dependencies.
Wayland/GLES libraries are introduced and owned by `ubuntu/`; the Linux text
adapter's PangoFT2/Fontconfig calls are owned by `platform/linux_text/` and are
used by `ubuntu/` only through its private raster ABI. Their headers and shared
libraries come from the Ubuntu system package archive. Development tools
(Weston, wayland-scanner, pkg-config, C compiler) are not application runtime
imports. Generated protocol code inherits the installed protocol XML's license.

| Library / API | License | Purpose | Upgrade source / failure behavior |
| --- | --- | --- | --- |
| Wayland client, wayland-cursor, wayland-egl, xdg-shell | MIT | Display, native window, cursor assets, EGL window wrapper | Ubuntu libwayland/wayland-protocols and installed Xcursor theme; typed startup/dispatch/service errors |
| EGL, GLESv2 dispatch; Mesa implementation | MIT / Mesa component licenses | GPU context, surface, quad draw and swap | Ubuntu GLVND/Mesa; typed SurfaceLost/DeviceLost, explicit recreation |
| PangoFT2 / Pango, Fontconfig | LGPL-2.1-or-later / MIT-style permissive license | Linux text shaping/measurement and grayscale A8 masks for Ubuntu scene text | Ubuntu `libpango1.0-dev`, `libfontconfig1-dev`; typed unsupported/invalid/resource outcomes; renderer remains experimental |
| xkbcommon | MIT | System keymap and logical key/modifier translation | Ubuntu libxkbcommon; typed map/allocation errors |
| libc, pthread, poll, eventfd, mmap | LGPL-2.1-or-later (glibc) | Owned buffers, owner-thread checks, loop wake and keymap mapping | Ubuntu glibc; typed NativeFailure/ResourceExhausted |

The local and CI dependency/package graph must be recorded again for release,
along with resolved patch versions and license evidence. This inventory is not
an audited production-release graph or approval of unrelated native libraries.
