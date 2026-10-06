# Status, limits, and roadmap

This document keeps project-state, support boundaries, and future work out of the user-facing README.

## Current position

The module version is `0.1.0`. The repository contains usable headless UI foundations, experimental native slices for macOS, Ubuntu/Wayland, and Windows, and the Weekboard browser demo alongside an interaction lab. It does not currently make a production-support claim for any platform.

The portable codebase provides application/entity lifetimes, deterministic scheduling, flex layout, element trees, hit testing, pointer and focused key/text capture/bubble dispatch, focus, scroll state, drag gestures, quad scene generation, bounded text snapshot items, clip validation, transforms, opacity, and canonical scene snapshots. The native/browser examples exercise subsets of that shared model.

The CI suite checks portable MoonBit packages across configured targets, builds the macOS native bundle and test runner, runs the Ubuntu 24.04 Wayland/Weston workflow, and runs the real-Chromium browser proof. The hosted Ubuntu workflow has passed its configured compositor checks. The experimental Windows slice also has a successful [Windows Server 2025 run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37189457500) for PR head `a1f6e523dc41317064c5657179baa20456dcf6b1`; its scope and remaining support limits are recorded in [the Windows guide](windows-native.md).

## Current limits

### Core ownership

`Entity[T]` relies on immutable or copy-on-write payload discipline. MoonBit cannot deeply copy an arbitrary `T`, so mutating a retained `Array`, `Map`, `Ref`, or other mutable alias outside `App::update` can bypass revision and notification tracking.

Application-owned capability registries now share the app's portable lifetime.
Stop invalidates direct/GUI/adapter handles and rejects cached or late results.
The synchronous API does not interrupt or roll back a handler already running;
reference dropping has no destructor guarantee. See
[capability owner lifecycle](capability-lifecycle.md).

### Input routing and snapshot storage

`ElementTree::dispatch_input` and `dispatch_input_with` route pointer variants
through existing hit testing and key/text variants through the current focused
focusable node. Capture runs root-to-target, then bubble target-to-root; no
focus means no callbacks. Routes are fixed before callbacks, errors abort and
stop-propagation suppresses later calls. Clearing/removing focus affects the
next dispatch; a saved earlier context cannot stop it. This does not choose
focus, interpret shortcuts, convert `Key::Character` to text, edit a document,
or provide native text input/IME. See [routing tests](../element/input_dispatch_test.mbt).

Validated backing arrays are now private: use `ElementTree::nodes()`,
`SceneSnapshot::resources()/clip_chains()/items()` and `ClipChain::rects()`.
These existing methods return detached copies, including nested clip
rectangles. Direct array-field access no longer compiles. This is a narrow
source-API tightening to preserve routing/clip validation after construction;
the SceneSnapshot v1 schema and canonical serialization are unchanged. Other
array-bearing types and generic `Entity[T]` alias discipline are not changed.

### Rendering

The shared scene path provides quads, rectangle clip chains, affine transforms, opacity, and canonical snapshots. `SceneItem::TextItem` adds one bounded plain-text run without changing the v1 envelope or existing quad serialization. Canvas 2D presents it using a system sans font, with a maximum font size of 1024 logical pixels and 65,536 UTF-16 code units per run. Ubuntu's experimental Wayland/GLES host now advertises `platform.Capability::GrayscaleTextFrames` and draws a bounded text subset using logical-resolution PangoFT2 grayscale masks; macOS and Windows retain their text rejection behavior. The capability is a discovery hint, not a guarantee for every frame and not text input/IME. Color glyphs reject the whole frame during preflight. Portable wrapping policy, caret/selection presentation, rich text, paths, images, and broader resource rendering remain incomplete. See [the Linux text guide](linux-text.md#ubuntu-grayscale-scene-text), [the Ubuntu guide](ubuntu.md#grayscale-text-frame-subset), [the scene implementation](../scene/snapshot.mbt), and [text validation tests](../scene/snapshot_text_test.mbt).

### Native services

The macOS and Ubuntu backends implement native window/render/input slices. macOS also has clipboard, cursor, and renderer surface recovery/rebuild/rebind paths, but recovery is not advertised until a real Metal end-to-end run verifies it. Ubuntu now has bounded nonblocking clipboard and cursor services plus the grayscale text-frame implementation; its bounded grayscale mixed-scene checks passed at 1x/2x in the [PR28 Ubuntu run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37346110201). Local Wayland end-to-end verification remains blocked by AF_UNIX socket availability. PR30/31 add an experimental single-line LTR field with qualified 1x/2x caret/selection/scroll and negative-bearing drawing; actual compositor typing, Japanese IME, general editable controls, semantic accessibility and production/resource gates remain open. Bounded undo/redo is being added with separate local and hosted evidence; see the [field guide](linux-text-field.md).

macOS currently has the broader service slice, including clipboard and cursors. Ubuntu's clipboard and cursor APIs have bounded buffers and typed failure paths; see [the Ubuntu guide](ubuntu.md) for the host boundary and validation status.

### Browser

The JavaScript-target entry page is **Weekboard**, a website-launch board with 12 initial tasks in three lanes. Its [portable model and view](../examples/task_board/) own task state, filtering, bounded additions, the last 32 add/move undo actions, flex layout, clipped hit testing, per-lane scrolling, drag cancellation, and responsive lane selection. [The JS adapter](../examples/browser_board/) only exposes copied input and scene/status/layout values. The browser host draws quad/text snapshots and projects visible cards to stable DOM buttons. Search and add fields are ordinary HTML inputs. The demo holds at most 100 tasks with titles of at most 80 UTF-16 code units, and keeps data only in the current page session.

The original interaction lab remains at `proof.html`. It retains the observed counter's GUI/direct/in-process MCP redraw seam, four fixed ARIA proxies, legacy DOM island, portable cursor mapping, scoped async plain-text clipboard services, opt-in committed `TextInput` ingress, and event-driven Canvas 2D restoration. The counter adapter is an in-process semantic seam, not MCP transport. Weekboard uses the shared clipboard service for explicit task-summary copying and has its own context-restoration lifecycle.

Bounded browser text and dynamic card proxies do not complete text editing, Japanese IME/caret integration, portable shaping, native text presentation, or a shared semantic accessibility tree. WebGPU, Wasm/WasmGC browser execution, screen-reader and cross-browser qualification, worker commands, real GPU fault evidence, and production browser gates remain open. [The browser guide](browser-demo.md) links the model/gesture/scroll/scene tests, DOM-contract tests, and separate Weekboard and interaction-lab Chromium checks; historical hosted proof runs do not establish execution evidence for later increments.

### Electron and Tauri migration

The portable `migration/host_services/` package now defines bounded service
requests/completions, per-service default-deny grants, logical scopes,
cancellation, stale-completion dropping, and copied transport-safe values. JS
leaf adapters and fake-host tests exercise the envelope. No real Electron or
Tauri application has been migrated or launched; focus/input ownership and
host-specific security integration remain open.

### Platform coverage

- macOS: native AppKit/Metal slice implemented; production gates remain open.
- Ubuntu / Wayland: native Wayland/EGL/GLES2 slice with an experimental, bounded grayscale text-frame renderer; quad and bounded grayscale mixed-scene checks passed in hosted CI; production desktop gates remain open.
- Browser / JavaScript: Canvas 2D Weekboard and interaction lab implemented; exact execution and test scope is recorded in [the browser guide](browser-demo.md).
- Windows: experimental one-window Win32/D3D11 hardware-or-WARP slice and example implemented; the hosted Windows Server 2025 run passed the MSVC shim build, portable tests, native GPU E2E, shared backend conformance, and example smoke. See [the Windows guide](windows-native.md); this does not establish a support tier or production claim.
- X11 / XWayland: no backend yet.

These statements describe implementation and evidence, not a compatibility or support tier unless the release evidence ledger explicitly assigns one.

## GPUI compatibility boundary

Compatibility is tracked feature-by-feature against the pinned GPUI reference in [`compatibility.md`](compatibility.md). Implementing a similar API or behavior does not automatically mark a compatibility row complete. Rust source compatibility and binary compatibility are out of scope.

The project is independently implemented. Provenance rules and the pinned upstream reference are recorded in [`provenance.md`](provenance.md) and [`upstream.json`](upstream.json).

## Roadmap

| Milestone | Goal | Current state |
| --- | --- | --- |
| M0 | Product, architecture, compatibility, dependency, testing and release contracts | Delivered |
| M1 | Deterministic App/Entity/Context core and scheduler | Implemented |
| M2 | Element system, layout, hit testing, event dispatch and focus | Bounded recursive flex layout, headless Render/IntoElement lifecycle and pointer/focused input routing implemented; invalidation, reusable controls and broader style/text behavior remain open |
| M3 | Stable scene data, primitives and renderer abstraction | In progress; quad/clip/transform/opacity snapshots and bounded plain-text items are implemented; Canvas 2D presents browser text and Ubuntu implements an experimental grayscale subset |
| M4 | First native platform slices | macOS and Ubuntu/Wayland slices implemented; experimental Windows slice added; initial Ubuntu and Windows hosted checks pass, while broader service and production evidence remain incomplete |
| M5 | Text and interaction completeness | In progress; portable text model, PR27 measured-text contract/adapter, and Ubuntu grayscale drawing are present; an experimental Linux field with caret/selection is present; bounded undo/redo is added here, while live typing, IME, broader controls and general accessibility remain open |
| M6 | Multi-platform support gates, including Windows | Planned |
| M7 | Production-ready 1.0 gates and sustained non-demo use | Planned |

M7 does not require implementing every upstream GPUI feature. It requires a stable documented API, explicit supported-platform matrix, reproducible builds/tests/releases, no release-blocking correctness issues, performance and accessibility evidence, diagnostics, and an audited dependency/provenance boundary.

## Application driven qualification plan

[MZed's native island roadmap](../issues/open/0018-mzed-native-island-roadmap.md)
uses a Zed-derived application to qualify framework capabilities incrementally.
The roadmap now orders the next Linux-facing work around a usable text field,
then picker/collection controls, app execution and reference-consumer
qualification. The grayscale text renderer and merged PR27 measurement are
foundation capabilities. The merged PR30/31 field joins them in a reusable
single-line LTR control; bounded history follows here, while actual keyboard
delivery/IME and broader input qualification remain open.
The initial same-window interaction proof is now in [MZed PR3](https://github.com/gpui-mbt/MZed/pull/3),
merged as `59a4a2b6daa48967c79de114a9de2ed119115c7b`; its [Linux run](https://github.com/gpui-mbt/MZed/actions/runs/37273659532)
demonstrated bounded 1x/2x mouse interaction, teardown/remount, and saving the
original editor. This does not complete the remaining [0019 proof gates](../issues/open/0019-mzed-native-coexistence-proof.md),
or establish text/IME, accessibility, broad platform support, or release
readiness. The roadmap returns to MZed when an actual reusable component can
migrate, while bounded framework work continues in parallel.

MZed supplies the functional and practical proof axis toward production
readiness. The roadmap's
[complementary Yami-kumo track](../issues/open/0018-mzed-native-island-roadmap.md#complementary-qualification-familiar-cross-platform-ux)
adds familiar SaaS-style task structure and predictable UX across applications,
devices and supported platforms, based on
[Yami-kumo PR 3](https://github.com/f4ah6o/Yami-kumo/pull/3). That draft is a
shared-UX design plan, not an implemented generator or native component library.
Yami-kumo owns Kumo-specific generation/adapters and conformance; gpui.mbt owns
the reusable primitives. Real text/input, focus, IME and accessibility evidence
remain prerequisites, and neither application track replaces M7 release gates.

The roadmap includes formal Linux native vlmkit support with explicit X11 and
Wayland capability profiles. The eventual goal is macOS/Linux/Windows across
applications and tools; new Windows-specific work is deferred while macOS/Linux
work remains and until a user-provided Windows environment is available. Existing
Windows functionality and checks stay intact.

## Where future work lives

- [`issues/open/`](../issues/open/) contains implementation packets.
- [`testing.md`](testing.md) defines validation strategy and broader gates.
- [`release.md`](release.md) and [`release-gates.json`](release-gates.json) define release evidence.
- [`platform.md`](platform.md) defines the platform boundary.
- [`compatibility.md`](compatibility.md) records behavioral comparison status.
