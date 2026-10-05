# Status, limits, and roadmap

This document keeps project-state, support boundaries, and future work out of the user-facing README.

## Current position

The module version is `0.1.0`. The repository contains usable headless UI foundations, experimental native slices for macOS, Ubuntu/Wayland, and Windows, and the Weekboard browser demo alongside an interaction lab. It does not currently make a production-support claim for any platform.

The portable codebase provides application/entity lifetimes, deterministic scheduling, flex layout, element trees, hit testing, capture/bubble event dispatch, focus, scroll state, drag gestures, quad scene generation, bounded text snapshot items, clip validation, transforms, opacity, and canonical scene snapshots. The native/browser examples exercise subsets of that shared model.

The CI suite checks portable MoonBit packages across configured targets, builds the macOS native bundle and test runner, runs the Ubuntu 24.04 Wayland/Weston workflow, and runs the real-Chromium browser proof. The hosted Ubuntu workflow has passed its configured compositor checks. The experimental Windows slice also has a successful [Windows Server 2025 run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37189457500) for PR head `a1f6e523dc41317064c5657179baa20456dcf6b1`; its scope and remaining support limits are recorded in [the Windows guide](windows-native.md).

## Current limits

### Core ownership

`Entity[T]` relies on immutable or copy-on-write payload discipline. MoonBit cannot deeply copy an arbitrary `T`, so mutating a retained `Array`, `Map`, `Ref`, or other mutable alias outside `App::update` can bypass revision and notification tracking.

Application-owned capability registries now share the app's portable lifetime.
Stop invalidates direct/GUI/adapter handles and rejects cached or late results.
The synchronous API does not interrupt or roll back a handler already running;
reference dropping has no destructor guarantee. See
[capability owner lifecycle](capability-lifecycle.md).

### Rendering

The shared scene path provides quads, rectangle clip chains, affine transforms, opacity, and canonical snapshots. `SceneItem::TextItem` adds one bounded plain-text run without changing the v1 envelope or existing quad serialization. Canvas 2D presents it using a system sans font, with a maximum font size of 1024 logical pixels and 65,536 UTF-16 code units per run. Native renderers return `UnsupportedCapability` for text. Portable shaping, wrapping, caret/selection layout, rich text, paths, images, and broader resource rendering remain incomplete. See [the scene implementation](../scene/snapshot.mbt) and [text validation tests](../scene/snapshot_text_test.mbt).

### Native services

The macOS and Ubuntu backends implement native window/render/input slices. macOS also has clipboard, cursor, and renderer surface recovery/rebuild/rebind paths, but recovery is not advertised until a real Metal end-to-end run verifies it. Ubuntu now has bounded nonblocking clipboard and cursor services, and its configured Wayland/Weston checks pass in hosted CI. Local Wayland end-to-end verification remains blocked by AF_UNIX socket availability. Production text shaping, Japanese IME coverage, semantic accessibility, sustained-resource evidence, and production performance gates remain incomplete.

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
- Ubuntu / Wayland: native Wayland/EGL/GLES2 slice implemented and exercised in hosted CI; production desktop gates remain open.
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
| M2 | Element system, layout, hit testing, event dispatch and focus | Bounded recursive flex layout and headless Render/IntoElement request-layout/prepaint/paint lifecycle implemented; invalidation and broader style/text behavior remain open |
| M3 | Stable scene data, primitives and renderer abstraction | In progress; quad/clip/transform/opacity snapshots and bounded plain-text items with Canvas 2D presentation implemented |
| M4 | First native platform slices | macOS and Ubuntu/Wayland slices implemented; experimental Windows slice added; initial Ubuntu and Windows hosted checks pass, while broader service and production evidence remain incomplete |
| M5 | Text and interaction completeness | In progress; portable scroll/drag state and bounded browser text implemented, while text editing/shaping/IME and general accessibility remain open |
| M6 | Multi-platform support gates, including Windows | Planned |
| M7 | Production-ready 1.0 gates and sustained non-demo use | Planned |

M7 does not require implementing every upstream GPUI feature. It requires a stable documented API, explicit supported-platform matrix, reproducible builds/tests/releases, no release-blocking correctness issues, performance and accessibility evidence, diagnostics, and an audited dependency/provenance boundary.

## Application driven qualification plan

[MZed's native island roadmap](../issues/open/0018-mzed-native-island-roadmap.md)
uses a Zed-derived application to qualify framework capabilities incrementally.
The [first native coexistence proof](../issues/open/0019-mzed-native-coexistence-proof.md)
starts with Linux, preserves a working pinned Zed baseline, and requires a
same-window boundary decision before product slices. These are planning packets,
not implemented native embedding or production-support claims.

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
