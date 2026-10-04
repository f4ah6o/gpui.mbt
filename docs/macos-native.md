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
./script/test_macos.sh             # native GPU/input/lifecycle E2E + smoke
```

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
runtime dependency is needed. Non-native MoonBit targets and non-macOS native
builds return `UnsupportedCapability`; portable tests do not load AppKit.

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
| next_event | Bounded 0–250 ms wait; per-window monotonic sequence, captured scale, logical pointer positions, focus/move/resize/backing-scale notifications and portable control/character keys. |
| wake / request_exit | UI-owner wake event and quiescing transition; new windows are rejected after exit is requested. Cross-thread enqueue is still pending. |
| present | SceneSnapshot v1 quads, affine transforms, opacity, ordered rectangle clip chains, paint order and alpha blending. Resources and unknown item kinds return UnsupportedCapability. |
| metrics | Current logical size and backing scale; sampled before presenting to avoid using old queued resize metadata for a current drawable. |
| clipboard / cursor | UTF-8 string clipboard and arrow/pointing-hand/text cursors. Clipboard busy/conversion failures are typed. |
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
(layer), and Metal (device/queue/GPU presentation), all owned by `platform/macos`
and upgraded with the host OS/SDK. No third-party library is added. Implementation,
shaders, and fixtures are independently authored from local contracts and Apple
API documentation; no GPUI source or assets were adapted.

Metal ownership follows Apple's [CAMetalLayer documentation](https://developer.apple.com/documentation/quartzcore/cametallayer).
The synchronous completion path uses [waitUntilCompleted](https://developer.apple.com/documentation/metal/mtlcommandbuffer/waituntilcompleted%28%29?language=objc).

## Evidence and remaining gates

`tests/native/macos_e2e.m` exercises actual AppKit windows, window-dispatched
pointer and application-queued keyboard input, logical coordinates, resize,
close policy, wrong-thread rejection, failed initialization payloads, restart
and stale-host checks, stale callback rejection, and 32 create/destroy cycles.
A test-only Metal blit reads frame pixels to verify transform/clip/alpha/paint
order and backing-pixel dimensions. Fault injection verifies DeviceLost reporting.
The test source also removes device/queue/pipeline state, invokes explicit
recovery and checks the following frame through pixel readback. Hosted execution
of this path remains pending, so capability negotiation stays disabled. The
tests do not establish bounded memory over sustained churn.

The MoonBit smoke executable uses the portable Backend interface and checks
creation, two completed GPU frames, resize, close request, destruction and event
sequence ordering. Headless tests verify portable key and error adapters on all
four MoonBit targets. Clipboard/cursor smoke, real display movement, Japanese
IME, accessibility, text shaping, cross-thread command completion, hosted
automated renderer recovery, sustained resource growth and performance remain
pending.

Hosted macOS CI builds the app/E2E runner and executes headless tests. The
manual `macos-native-e2e.yml` workflow requires a logged-in self-hosted desktop
with label `gpui-native` and a Metal device. It archives revision/toolchain/logs
and app artifacts; these are inputs to future release evidence, not sufficient
Tier 1 evidence. A native test binary printing success does not update
`docs/release-gates.json` automatically.
