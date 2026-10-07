# First macOS native slice

The first native slice implements issue 0006 packets A/B and parts of C/D/F/G.
It runs a MoonBit executable against repository-owned AppKit, Core Animation,
Metal and CoreText/CoreGraphics code. Platform support and production release
gates remain pending.

## Build and run

On macOS 13 or newer, install the repository's pinned MoonBit toolchain and
Xcode command-line tools, then run:

```sh
./script/build_and_run.sh          # launch the interactive quad demo
./script/build_and_run.sh --build  # build _build/macos/GpuiNative.app
./script/build_and_run.sh --smoke  # MoonBit lifecycle + frame smoke
./script/test_macos.sh all --target-dir /private/tmp/gpui-macos-checks
                                   # native E2E + smoke + field checks
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
| present | SceneSnapshot v1 quads and admitted grayscale text, affine transforms, opacity, ordered rectangle clip chains, paint order and alpha blending. Other resources and unknown item kinds return UnsupportedCapability. |
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
(layer), Metal (device/queue/GPU presentation), and CoreText/CoreGraphics text
shaping and rasterization, owned by `platform/macos` and `platform/macos_text`
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
is recorded per run in the external actrun artifacts; capability negotiation
stays disabled pending release-tier evidence. The tests do not establish bounded
memory over sustained churn.

The MoonBit smoke executable uses the portable Backend interface and checks
creation, two completed GPU frames, resize, close request, destruction and event
sequence ordering. Headless tests verify portable key and error adapters on all
four MoonBit targets. Clipboard/cursor smoke, real display movement,
accessibility, cross-thread command completion, automated renderer recovery,
sustained resource growth and performance remain pending. The bounded text
field's native CoreText/Metal and Japanese input checks are described below.

## Experimental single-line text field

`examples/macos_text_field/` is a bounded experimental control built on the
shared immutable `controls/text_field` model. It supports directional
selection, editing, horizontal scrolling, clipboard commands, undo/redo,
accepted-frame rollback and caret-synchronized candidate geometry. CoreText
provides copied measurement/hit values and monochrome scene rasterization;
AppKit's resolved `insertText:` callback is the default committed-text path.
The opt-in per-window composition owner is enabled with
`GPUI_FIELD_MACOS_IME=1`. It does not advertise a global portable TextInput
capability. Multiline text, bidi, color glyphs, reconversion ranges outside the
current mark/selection and unsupported marked styles fail with typed errors.
The bounded preedit renderer maps AppKit's single- and thick-underline hints
to the same generic full-range marker; it does not reproduce native underline
weight or pattern fidelity, and other style values remain unsupported.
Interactive mode begins after a real native key-focus transition and keeps its
accepted frame open while waiting; the finite acceptance run has a bounded
focus wait and cleanup path.
The example uses a fixed 18 px system sans font. The shared field and scene
admission cap text at 4096 UTF-8 bytes, font size at 32 px, and logical bounds at
2048 by 128 points. CoreText additionally caps a raster mask at 16384 by 2048
pixels and 8 MiB per text run; the renderer caps retained cropped text masks at
8 MiB total per frame. The native scene parser caps one scene at 16 MiB and
65536 items. Its draw staging allocation is bounded by those items at 328
bytes per item (about 20.5 MiB), and native window dimensions remain capped at
8192 logical points. The 4096-point limit applies to candidate-caret
rectangles, not windows.

Run the field interactively with `./script/build_and_run.sh --demo text-field`.
For deterministic source/provider checks and a test-hook app build, use
`./script/test_macos.sh --text-field --target-dir <fresh-external-directory>`.
For the native GPU runner and real Kotoeri flow, provision the public pinned
tooling profile once, then execute the local actrun matrix:

```sh
export GPUI_MACOS_PROFILE_ROOT=/private/tmp/gpui-macos-quality-profile
python3 infra/macos-desktop/profile.py --root "$GPUI_MACOS_PROFILE_ROOT" bootstrap
RUN_DIR="$(mktemp -d /private/tmp/gpui-macos-native.XXXXXX)"
python3 infra/macos-desktop/actrun-feedback.py \
  --root "$GPUI_MACOS_PROFILE_ROOT" --mode native --run-dir "$RUN_DIR/native"
```

The runner builds native checks and the text-field test-hooks app under the
provided run directory. Its qualified host profile records macOS 26.5.2 arm64
with Xcode 26.6 and SDK 26.5; each run retains the exact host and toolchain
fingerprint. The runner requires a logged-in desktop with Kotoeri enabled,
drives AppKit through app-owned key events, waits for accepted composition and
commit frames, and retains screenshots, frame identity, source/binary identity
and strict JSON evidence. For a saved profile, `profile.py ... doctor` checks
readiness. `--mode quality` runs the broader approved matrix. Runtime outcomes
are recorded in each external actrun summary and its retained artifacts; source
configuration alone does not establish a pass. No support tier or production
release gate changes here.

To run the full approved local quality matrix, including portable/schema,
proof, mutation, hot-path and native IME stages, use the same profile and a
separate fresh run directory:

```sh
python3 infra/macos-desktop/actrun-feedback.py \
  --root "$GPUI_MACOS_PROFILE_ROOT" --mode quality --run-dir "$RUN_DIR/quality"
```
