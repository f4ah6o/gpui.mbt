# First macOS native slice

The first native slice implements issue 0006 packets A/B and part of C/F/G.
It runs a MoonBit executable against repository-owned AppKit, Core Animation,
and Metal code. Platform support and production release gates remain pending.

## Build and run

On macOS 13 or newer, install the pinned MoonBit toolchain from
`.github/workflows/contracts.yml` and Xcode command-line tools, then run:

```sh
./script/build_and_run.sh          # launch the interactive quad demo
./script/build_and_run.sh --build  # build _build/macos/GpuiNative.app
./script/build_and_run.sh --smoke  # MoonBit lifecycle + frame smoke
./script/build_and_run.sh --test-hooks # build opt-in native E2E host hooks
./script/test_macos.sh             # native GPU/input/lifecycle E2E + smoke
```

Moon runs the module pre-build configuration for native and LLVM builds, so
Python 3 is required to build GPUI for either backend. The hook emits CoreText
framework link flags only for macOS native builds; built executables do not
depend on Python at runtime.

Click the quad or press Space to toggle its color; Escape requests close.
The window's close button emits `CloseRequested`; application policy then calls
`destroy_window`, which emits exactly one terminal `Destroyed` event. The demo
always calls `stop` after its event loop returns, including typed failures.
`--debug`, `--logs`, `--telemetry`, and `--verify` support local development.
The Run action points at the same script.

The bundle contains both the MoonBit executable and shim dylib. The C loader
resolves the bundled library relative to the executable, or uses the explicit
`GPUI_MACOS_LIBRARY` development override. It verifies ABI version and function
table size before calling native code. No Rust, JavaScript, browser, or external
runtime dependency is needed at runtime. Non-native MoonBit targets and
non-macOS native builds return `UnsupportedCapability`; portable tests do not
load AppKit.

## Implemented boundary

`platform.Backend` is the portable initial interface. `platform/macos.Host`
implements it, with a target-specific startup factory. `require_capability` returns UnsupportedCapability for text input, accessibility,
menus, renderer recovery, and cross-thread commands. A target-specific
`recover_renderer` operation can rebuild Metal device/queue/pipeline state and
rebind live layers; recovery capability remains unadvertised until hosted Metal
E2E confirms the path. Core, element, layout,
scene, and application event values contain no OS or GPU pointers.

| Operation | Behavior |
| --- | --- |
| start / stop | Main-thread only; duplicate start is Busy; stop is idempotent; failed GPU setup rolls back; a host epoch rejects handles from earlier starts. |
| create / title / size | Atomic logical token publication, owned UTF-8 title including embedded NUL, finite bounded content size, multiple windows. |
| close / destroy | Close requests await application policy. Destruction drops pending callbacks for the token, releases the surface before the window, and enqueues a terminal event. Tokens are monotonic and never reused. |
| next_event | Bounded 0–250 ms wait; per-window monotonic sequence, captured scale, logical pointer positions, focus/move/resize/backing-scale notifications, portable control/character keys and AppKit scroll-wheel events. Scroll deltas preserve `NSEvent.scrollingDeltaX/Y`: precise values are points and non-precise values are line/row counts; the backend does not normalize units. |
| wake / request_exit | UI-owner wake event and quiescing transition; new windows are rejected after exit is requested. Cross-thread enqueue is still pending. |
| present | SceneSnapshot v1 quads plus bounded single-line `text` and `text_run` items, affine transforms, opacity, ordered rectangle clip chains, paint order and alpha blending. Text uses CoreText system sans and CoreGraphics grayscale coverage at the drawable scale; font sizes are limited to 32 points, multiline, bidirectional, unsupported/color glyphs and unknown item kinds return typed errors. |
| text measurement | `platform/macos_text.measure` copies CoreText logical/ink bounds, ascent and scalar caret geometry into `TextMeasurement`. Use the system sans family (`"sans"`) at the same logical size used for rendering. |
| metrics | Current logical size and backing scale; sampled before presenting to avoid using old queued resize metadata for a current drawable. |
| clipboard / cursor | UTF-8 string clipboard and arrow/pointing-hand/text cursors. Clipboard busy/conversion failures are typed. Native E2E uses a unique private pasteboard for roundtrip checks and dispatches each supported cursor kind; it does not read or replace the user's General Pasteboard. |
| renderer recovery | Explicitly rebuilds the shared Metal device, queue and pipeline and rebinds every live `CAMetalLayer`, preserving logical window identities. Automatic recovery remains unimplemented. |

Geometry remains logical until the native boundary. `CAMetalLayer.drawableSize`
is logical size multiplied by backing scale; clips become device-pixel scissors.
Each frame uses an autorelease pool. This initial renderer waits for command
completion and has at most one synchronous frame in flight. A missing drawable
returns `SurfaceLost`; absent renderer resources or failed commands return
`DeviceLost`. Explicit recovery recreates shared GPU objects and rebinds active
windows; no automatic recovery or performance claim is made.

## Native ownership and ABI

`abi.h` defines a v1 function table with `abi_version` and `struct_size`,
fixed-width op/status tags and integer tokens. `loader.c` is the only MoonBit
native stub. `native.m` is compiled separately against OS frameworks. The loaded
library is retained for process lifetime; repeated host starts do not load new
copies. All calls and getters verify the main thread.

Input byte buffers are borrowed only for the duration of a call. Scene JSON is
created from the validated SceneSnapshot, parsed within the call, and converted
to owned native scalar vertices. Native event dictionaries own key text bytes;
MoonBit copies them before the next FFI operation. Output getters are valid only
until the next operation. Callbacks enqueue values and never invoke MoonBit or
retain MoonBit objects. Window delegates and views are detached during teardown.
Event storage is capped at 4096; destruction returns ResourceExhausted and
keeps the window live if no terminal-event slot can be reserved. Detached views
drop delayed input. Overflow returns ResourceExhausted rather than
silently claiming success. Titles/scene/clipboard payloads are capped at 16 MiB;
windows at 64, scene items at 65536, dimensions at 8192 logical points.

Native runtime inventory: Apple AppKit (host/windows/input/services), QuartzCore
(layer), Metal (device/queue/GPU presentation), CoreText (system font metrics and
glyphs), and CoreGraphics (bounded grayscale masks), all owned by GPUI and
upgraded with the host OS/SDK. No third-party library is added. Implementation,
shaders, and fixtures are independently authored from local contracts and Apple
API documentation; no GPUI source or assets were adapted.

Metal ownership follows Apple's [CAMetalLayer documentation](https://developer.apple.com/documentation/quartzcore/cametallayer).
The synchronous completion path uses [waitUntilCompleted](https://developer.apple.com/documentation/metal/mtlcommandbuffer/waituntilcompleted%28%29?language=objc). Scroll handling follows Apple's [`scrollingDeltaY` unit contract](https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay): non-precise events report lines or rows, while precise events report points.

## Evidence and remaining gates

`tests/native/macos_e2e.m` exercises actual AppKit windows, window-dispatched
pointer and keyboard input, logical coordinates, resize, close policy,
wrong-thread rejection, failed initialization payloads, restart and stale-host
checks, stale callback rejection, and 32 create/destroy cycles. It renders
CoreText grayscale text and text runs into Metal and checks non-background
pixels. The opt-in `GPUI_NATIVE_E2E=1` frame seam copies the completed drawable
as bounded top-left RGBA8. `Host::post_test_click` and
`Host::post_test_escape` send scoped NSEvents through the owned NSWindow for
autonomous app-loop validation; they require the `--test-hooks` dylib and are
not physical hardware input. A test-only Metal blit also checks
transform/clip/alpha/paint order and backing-pixel dimensions. Fault injection verifies DeviceLost reporting.
The test source also removes device/queue/pipeline state, invokes explicit
recovery and checks the following frame through pixel readback. Hosted execution
of this path remains pending, so capability negotiation stays disabled. The
scroll smoke invokes `GPView.scrollWheel:` with a responder probe whose deltas,
modifiers, and precision flag come from an AppKit `NSEvent` created from Core
Graphics line- and pixel-unit scroll events. This verifies native delta
extraction, event encoding, and portable decoding, but does not verify
window-system delivery or physical-device scrolling. Clipboard smoke
round-trips UTF-8 through a unique private pasteboard; cursor smoke exercises
the three supported native cursor selections and unsupported-tag handling.
General Pasteboard exchange and visible cursor confirmation remain open. The
tests do not establish bounded memory over sustained churn.

The MoonBit smoke executable uses the portable Backend interface and checks
creation, two completed GPU frames, resize, close request, destruction and event
sequence ordering. Headless tests verify portable key, scroll, and error
adapters on all four MoonBit targets. Real display movement, physical scroll
input, General Pasteboard exchange, visible cursor confirmation, Japanese IME,
accessibility, shaping beyond bounded system-sans single lines,
cross-thread command completion, hosted automated renderer recovery, sustained
resource growth and performance remain pending.

Hosted macOS CI builds the app/E2E runner and executes headless tests. The
manual `macos-native-e2e.yml` workflow requires a logged-in self-hosted desktop
with label `gpui-native` and a Metal device. It archives revision/toolchain/logs
and app artifacts; these are inputs to future release evidence, not sufficient
Tier 1 evidence. A native test binary printing success does not update
`docs/release-gates.json` automatically.
