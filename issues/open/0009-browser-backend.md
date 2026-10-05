# Browser backend roadmap

Status: open
Parent: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md)
Updated: 2026-10-05

## Increment — 2026-10-05

- [x] Scoped async plain-text clipboard read/write using the existing
  host-service envelope, typed permission/unsupported failures, and stale
  completion suppression on teardown.
- [x] Opt-in committed-text bridge into shared `InputEvent.TextInput`, with
  composition commit deduplication and cancellation/lifecycle cleanup.
  This is `committedTextInput`; full `textInputIme` remains unsupported.
- [x] Event-driven Canvas 2D context restoration preserves the live application,
  resynchronizes size/DPR, and resumes input after a successful repaint.
- [x] Dedicated service tests and production-artifact Chromium smoke are wired
  into the browser workflow for these increments.
- [ ] Real GPU context loss, native Japanese IME/candidate positioning, a full
  text editing/selection/rendering contract, and cross-browser qualification.

See [the browser guide](../../docs/browser-demo.md#browser-service-increment--2026-10-05)
for the precise scope. The historical triage below predates these additions;
the overall browser backend and production gates remain open.

## Current-head acceptance triage — 2026-10-04

Basis: merged main HEAD `1dea499e34a36a64927791c94f35965a91c305a2`; PR #13
head `d70b1255aa5dc1eaaea04a67a9ea748d29317cbd`.

- [x] The JS Canvas2D host presents the shared MoonBit scene and event model.
  The hosted [browser run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649282)
  passed Vite+ checks/build, dev-watch/source-map checks, and real Chromium
  input/focus/DPR/lifecycle smoke.
- [x] Chromium verifies GUI, direct API, and in-process MCP mutations redraw
  the observed counter; it also covers wheel input and legacy-island focus
  ownership and teardown.
- [x] Browser cursor intent uses the portable `Cursor` enum and maps
  Arrow/PointingHand/Text to CSS default/pointer/text after queued input is
  drained; Chromium covers pointing-hand and arrow transitions.
- [ ] Wasm/WasmGC browser targets, WebGPU, broad text/Japanese IME, general
  accessibility, clipboard services, worker commands, and production browser
  evidence remain open.

The Chromium run proves the experimental JS slice only; it does not promote
browser support.

## Goal

Run the same gpui.mbt application model in a web browser without replacing the
framework's layout, element, scene, focus, or event semantics with DOM-driven UI.

The first browser success criterion is:

`MoonBit app -> browser host -> canvas viewport -> SceneSnapshot frame -> pointer/keyboard input -> clean teardown`.

The browser backend is a platform backend, not a separate web UI framework.
Application-facing code should continue to use gpui.mbt concepts and portable
SceneSnapshot data. DOM, Canvas, WebGPU, browser events, and browser-only handles
must remain below the platform/backend boundary.

## Target strategy

Bring the backend up in this order:

1. `--target js` as the initial browser integration target
2. `--target wasm-gc` with the same observable backend contract
3. `--target wasm` with the same observable backend contract

The existing platform-neutral core/layout/element/scene packages must continue
to compile and test on all configured MoonBit targets. Browser support is not
established by compilation alone: each browser target requires executable
browser smoke/E2E evidence.

Use MoonBit standard/core plus narrow repository-owned browser FFI. Do not add a
third-party JavaScript UI/runtime framework merely to host gpui.mbt.

## Browser development toolchain

Standardize browser development and packaging on Vite+ through the `vp` CLI,
with `vite-plugin-moonbit` as the MoonBit/Vite integration. This is a tooling
choice only: it must not introduce a JavaScript UI/runtime framework or move
portable gpui.mbt semantics into Vite.

The current manual `moon build` + static-file copy proof remains transitional
until the Vite+ path reproduces the existing production-build Chromium smoke and
GitHub Pages artifact. The migration, dependency/CI policy, source-map
requirements, and removal gates are tracked in
[0010-browser-vite-plus-toolchain.md](0010-browser-vite-plus-toolchain.md).

## Browser host model

A gpui.mbt `WindowId` is a logical framework window. For the first browser
slice, one logical window maps to one owned canvas viewport inside the host page;
it does not mean a separately opened browser top-level window.

The backend owns:

- host-page/bootstrap integration
- canvas creation or attachment
- browser event listeners and lifecycle
- frame scheduling
- logical-size/device-pixel conversion
- renderer/device/context lifetime
- clipboard/cursor/browser services
- text-input/IME bridge
- accessibility bridge

Core, layout, element, scene, and application APIs must not expose
`Window`, `Document`, `HTMLElement`, `HTMLCanvasElement`,
`GPUDevice`, JavaScript references, or Wasm/JS host handles.

## Event-loop contract change

The current portable `Backend::next_event(timeout_ms?)` shape is a
pull/blocking model and cannot be the browser's fundamental integration
primitive. Browser event delivery is callback/push based and frame scheduling is
driven by the host.

Before browser support is considered implemented, define a common event
ingress/drain contract that can express both native and browser hosts without
busy polling or synchronous waiting in browser code.

Required properties:

- browser callbacks translate events and enqueue framework-owned values
- callbacks do not re-enter core dispatch while a backend call is active
- core drains events in deterministic queue order
- wakeups may coalesce but cannot lose accepted work
- frame requests use browser scheduling rather than a blocking loop
- the revised contract remains implementable by macOS, Windows, and Linux
- headless scheduler/event ordering stays deterministic

Do not emulate a blocking native event loop with a browser busy loop.

## Capability model

Browser support must report capabilities honestly.

The existing `NativeWindow` capability must not be reported merely because a
logical browser window/canvas exists. Add or refine portable capability
vocabulary as needed so applications can distinguish:

- logical window/viewport availability
- quad/frame presentation
- pointer/keyboard input
- clipboard
- cursor
- text input/IME
- accessibility
- renderer recovery
- cross-thread/worker command support

Browser-only restrictions such as permission, secure-context, or user-gesture
requirements must map to typed framework errors rather than silent success.

## Work packets

### A. JS browser host and one viewport

Implement:

- browser entry/bootstrap for `--target js`
- one logical `WindowId`
- owned or explicitly attached canvas
- title where meaningfully supported
- logical-size and scale tracking
- host teardown/listener cleanup
- typed JS/browser boundary errors

Acceptance:

- a clean checkout builds an executable browser example
- one visible canvas-backed gpui.mbt viewport starts successfully
- logical size is independent from backing-store pixel size
- teardown removes listeners/resources without leaving a live logical window
- no DOM/browser handle leaks into portable package APIs

### B. Browser event ingress and frame scheduling

Implement:

- callback-to-framework event translation
- pointer events
- keyboard events
- focus/blur
- resize
- visibility/lifecycle handling needed by the backend
- `requestAnimationFrame`-driven frame scheduling
- a common queue/drain boundary replacing browser dependence on blocking
  `next_event`

Acceptance:

- callback delivery never directly re-enters active core dispatch
- event ordering is stable and covered by conformance tests
- pointer coordinates are logical coordinates
- device-pixel-ratio changes take effect before later frame/input use
- hidden/background tab behavior does not create a busy loop

### C. SceneSnapshot rendering

Bootstrap rendering may use Canvas 2D where it provides the shortest
deterministic path to visible browser evidence. WebGPU is the preferred browser
GPU renderer for the production path.

Implement:

- the currently supported SceneSnapshot v1 subset
- quad rendering
- transforms
- opacity
- rectangle clips
- viewport resize
- typed invalid-resource/render failures
- renderer/context/device loss handling appropriate to the selected path

Acceptance:

- the same deterministic quad fixture used by native/headless validation renders
  in a real browser
- scene ordering, transforms, opacity, and clipping preserve the portable scene
  contract
- resizing cannot render using stale backing dimensions
- renderer loss/failure is surfaced through framework diagnostics
- no browser renderer object enters SceneSnapshot

Canvas 2D success alone is browser execution evidence, not a claim that the
WebGPU/production renderer is complete.

### D. Input, focus, DPI, clipboard, and cursor

Implement:

- pointer move/down/up and pointer identity needed by the shared model
- keyboard/code/modifier translation
- focus transitions
- cursor mapping
- clipboard read/write
- devicePixelRatio and viewport changes

Acceptance:

- hit testing remains based on logical coordinates
- scale changes are reflected before subsequent input/frame use
- clipboard permission/user-gesture failures are typed and recoverable
- unsupported cursor/clipboard behavior does not silently report success
- browser E2E covers input, focus, resize, and scale behavior

### E. Text and Japanese IME

Keep visible text rendering inside the gpui.mbt scene/renderer model. Use a
minimal hidden/native browser text-input surface only as the bridge to browser
IME and editing events; do not turn application UI into DOM controls.

Implement:

- focus synchronization between gpui.mbt and the browser text-input bridge
- composition start/update/commit/cancel
- selection/caret mapping
- candidate-position strategy where the browser permits it
- text-input bridge cleanup on blur/window destruction

Acceptance:

- Japanese composition smoke passes
- commit occurs exactly once
- cancel does not commit provisional text
- focus loss/destruction cancels or resolves composition according to the shared
  text contract
- Latin, Japanese, emoji, combining-mark, and bidi fixtures are covered
- the hidden input bridge is an implementation detail, not a public UI model

### F. Accessibility

Preserve the internal semantic accessibility tree as the source of truth.

Implement a browser accessibility adapter that mirrors the semantic tree into a
minimal DOM/ARIA representation sufficient for browser accessibility APIs while
keeping visual rendering canvas/GPUI-driven.

Acceptance:

- role/name/value/state/focus/action baseline maps from the shared semantic tree
- browser accessibility nodes do not become layout/rendering authority
- actions route back to current framework `NodeId` values
- stale nodes cannot target newly created logical objects
- automated semantic checks plus a manual/screen-reader smoke procedure exist

### G. WasmGC and Wasm parity

After the JS backend is stable, add browser execution for `wasm-gc` and
`wasm` without creating a second application API.

Acceptance for each target:

- build succeeds with warnings denied
- the browser example boots
- deterministic core/layout/scene tests retain parity
- quad/frame smoke passes
- pointer/keyboard/resize smoke passes
- target-specific FFI/glue remains inside the browser backend
- application source does not need target-specific branches for normal gpui.mbt
  usage

Document any browser feature that cannot be implemented equivalently on one
MoonBit target and expose the difference through capabilities.

### H. Browser CI and release evidence

Add reproducible browser automation for the supported browser baseline.

Required evidence:

- JS browser build and smoke
- WasmGC browser build and smoke
- Wasm browser build and smoke
- real browser E2E for frame/input/resize
- deterministic screenshot or pixel/readback fixture where practical
- IME test strategy, with manual evidence where browser automation cannot
  faithfully drive native IME
- accessibility semantic checks
- retained failure artifacts
- repeated create/destroy/navigation or remount stress

A headless-browser pass is useful CI evidence but does not by itself establish
all user-agent, GPU, IME, or accessibility support claims.

## Async browser APIs

Browser APIs such as WebGPU initialization, clipboard access, font loading, and
permission-gated operations may complete asynchronously.

Do not hide asynchronous browser operations behind fake synchronous success.
Use the common command/event completion model or another explicit framework
contract that:

- owns copied inputs across the async boundary
- returns one terminal completion
- drops stale completions safely after logical destruction
- preserves deterministic ordering where the public contract requires it
- maps rejection/permission/device-loss outcomes into typed diagnostics

## Renderer and compatibility policy

The browser backend consumes the same SceneSnapshot contract as native
renderers. It must not introduce browser-only layout semantics.

Cross-platform compatibility is semantic:

- layout/focus/event behavior follows the shared contracts
- scene ordering and resource identity remain deterministic
- exact text pixels need not match native platforms
- pixel goldens are renderer/browser specific unless produced by a shared
  deterministic raster path

DOM/CSS layout is not a compatibility oracle for gpui.mbt layout.

## Testing

Required layers:

1. existing all-target headless core/layout/element/scene tests
2. shared backend conformance tests
3. browser event-translation tests
4. real browser frame/input/resize E2E
5. JS/WasmGC/Wasm parity fixtures
6. Japanese IME smoke
7. accessibility semantic and integration smoke
8. renderer/context/device-loss fault coverage
9. repeated mount/create/destroy lifecycle stress

Use browser automation and vlmkit only as external black-box evidence where they
add value. Neither replaces deterministic framework tests.

## Support tiers

Browser support uses the same evidence-first principle as native platforms, but
its production gates are browser-specific.

- **Tier 0 — builds:** a target/browser bundle compiles; not a runtime support
  claim.
- **Tier 2 — experimental:** real browser execution works but one or more
  production gates remain.
- **Tier 1 — production supported:** browser E2E, supported-target matrix,
  input/focus, DPI, Japanese IME, accessibility, renderer recovery, performance,
  and sustained lifecycle/resource evidence all pass for the documented browser
  baseline.

The README must name the exact MoonBit targets and browser baseline for any
support claim.

## Non-goals for the first browser slice

Do not block first visible browser execution on:

- full SceneSnapshot v1 completion
- DOM-based application UI
- CSS layout compatibility
- every browser engine
- every MoonBit target on day one
- complete accessibility/text shaping
- browser top-level multi-window/pop-up support
- worker/off-main-thread rendering
- Tier 1 production support

These may be added after the one-viewport JS path establishes the backend
contract and browser event model.

## Definition of done

The packet is complete only when gpui.mbt can run a non-trivial shared example
in the documented browser baseline with no browser-specific application fork,
and the supported JS/WasmGC/Wasm targets have the declared build/runtime
evidence.

The final evidence must demonstrate that browser support reuses the same
portable core, layout, element, scene, event, text, accessibility, and
diagnostic contracts rather than maintaining a parallel web framework.

## First JavaScript proof slice — 2026-10-03

The repository now contains a JavaScript-only Canvas 2D host and a separate
host-neutral MoonBit app fixture. The fixture uses the shared app/entity,
flex-tree layout, element hit testing, focus, common event ingress, and
`SceneSnapshot` v1 quad data. The host owns the canvas, CSS-pixel/DPR measurement,
pointer and keyboard callbacks, focus/visibility/lifecycle listeners, and
on-demand `requestAnimationFrame` presentation. Its current capability report
keeps native top-level windows, clipboard, IME, a general accessibility
bridge, renderer recovery, and worker commands unavailable; it separately
reports the fixture-only ARIA adapter.

The local build and all-target check/test suites pass. A pinned Chromium smoke
test covers rendered Canvas 2D output, pointer/focus input, live viewport/DPR
updates, hidden-page scheduling, context-loss diagnostics, and repeated
teardown. GitHub Actions run `37132433860` passed the all-target suites and real
Chromium smoke test and uploaded the Pages artifact. The deployment job is
restricted to `main`; the first live deployment follows merge and initial Pages
Actions configuration. Local Chromium was unavailable in the implementation
environment. Build and test instructions are in
[`docs/browser-demo.md`](../../docs/browser-demo.md).

This is the first JavaScript proof slice only. This packet remains open for CI
browser evidence, WasmGC and Wasm browser targets, broader input and text
services, WebGPU, accessibility, renderer recovery, native/backend conformance,
and the production gates above.

## Browser migration bridge slice — 2026-10-04

The browser proof now includes wheel-to-scroll event translation, a
fixture-specific ARIA proxy for the app-provided button descriptions, and a
migration-only DOM editor placed from the app's reserved logical region. The
island host reports input ownership, preserves legacy ownership while focus
moves between its controls, and returns focus to the canvas when hidden or
disposed. The app fixture registers one External counter write; GUI, direct,
and in-process MCP adapter calls reach that same typed handler and app-owned
entity, while the normal `Context.observe` path updates the rendered counter
quad. The MCP call is only a local semantic adapter seam, not wire transport.

The portable host-service package and JS Electron/Tauri adapters are default
deny, use decimal-string request/scope IDs, validate copied bounded values, and
discard stale/cancelled completions. Electron and Tauri examples have empty
operation/command grants. Contract tests use fake IPC/invoke functions; no real
Electron main process or Tauri runtime is part of this change. The expanded
Chromium smoke is configured to check pointer/wheel/focus, visible redraw from
GUI/direct/MCP calls, island focus ownership and teardown, DPR/lifecycle, and
repeated remount. Its first hosted run
([37186910745](https://github.com/f4ah6o/gpui.mbt/actions/runs/37186910745))
installed Chromium and completed the Vite build and watcher check, then failed
the direct-counter pixel assertion. This was a test timing race: it observed
the synchronous app-model update before the scheduled animation-frame paint.
The smoke now waits for the actual sampled canvas pixel to change before
checking both direct and MCP redraws. Corrected run
([37187979407](https://github.com/f4ah6o/gpui.mbt/actions/runs/37187979407))
at head [`1dfad6a`](https://github.com/f4ah6o/gpui.mbt/commit/1dfad6a) passed
the `verify-and-package` job, including all-target
checks/tests, Vite+ checks, dev-watch and source-map exercise, browser build,
and the real Chromium smoke. The smoke passed Canvas2D snapshot rendering,
DPR updates, pointer/wheel/focus input, GUI/direct/MCP redraw, ARIA and island
focus ownership, resize and hidden-page scheduling, context-loss handling, and
repeated teardown. It packaged the Pages artifact; the deploy job was skipped
for the pull request.

This is execution evidence for the experimental JavaScript Canvas 2D slice,
not production browser support. WasmGC/Wasm browser targets, WebGPU, Japanese
IME and broader text input, general accessibility, clipboard services,
renderer recovery, native/backend conformance, and worker commands remain
open.
