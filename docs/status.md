# Status, limits, and roadmap

This document keeps project-state, support boundaries, and future work out of the user-facing README.

## Current position

The module version is `0.1.0`. The repository contains usable headless UI foundations, experimental native slices for macOS, Ubuntu/Wayland, and Windows, and a browser proof. It does not currently make a production-support claim for any platform.

The portable codebase provides application/entity lifetimes, deterministic scheduling, flex layout, element trees, hit testing, capture/bubble event dispatch, focus, quad scene generation, clip validation, transforms, opacity, and canonical scene snapshots. The native/browser examples exercise subsets of that shared model.

The CI suite checks portable MoonBit packages across configured targets, builds the macOS native bundle and test runner, runs the Ubuntu 24.04 Wayland/Weston workflow, and runs the real-Chromium browser proof. A Windows native workflow is configured for the new experimental slice, but it still needs a hosted run before its result counts as evidence.

## Current limits

### Core ownership

`Entity[T]` relies on immutable or copy-on-write payload discipline. MoonBit cannot deeply copy an arbitrary `T`, so mutating a retained `Array`, `Map`, `Ref`, or other mutable alias outside `App::update` can bypass revision and notification tracking.

### Rendering

The shared scene path currently centers on quads, rectangle clip chains, affine transforms, opacity, and canonical snapshots. Rich text, path, image, and broader resource rendering are not yet complete across the backends.

### Native services

The macOS and Ubuntu backends implement native window/render/input slices. macOS also has clipboard, cursor, and renderer surface recovery/rebuild/rebind paths, but recovery is not advertised until a real Metal end-to-end run verifies it. Ubuntu now has bounded nonblocking clipboard and cursor services; portable/C helper checks pass, while local Wayland end-to-end verification is blocked by AF_UNIX socket availability and hosted compositor evidence remains pending. Production text shaping, Japanese IME coverage, semantic accessibility, sustained-resource evidence, and production performance gates remain incomplete.

macOS currently has the broader service slice, including clipboard and cursors. Ubuntu's clipboard and cursor APIs have bounded buffers and typed failure paths; see [the Ubuntu guide](ubuntu.md) for the host boundary and validation status.

### Browser

The browser implementation is a JavaScript-target proof hosted by Canvas 2D. It shares the MoonBit application/layout/event/scene model, normalizes pointer/keyboard/wheel input, schedules only requested frames, and has a fixture-specific semantic DOM focus/action layer plus a legacy DOM island with explicit focus ownership. The browser counter's GUI, direct, and in-process MCP calls update the same observed state and are checked through a canvas redraw seam. These fixtures are not a general accessibility bridge or MCP transport. WebGPU, text/IME, full accessibility, clipboard/cursor services, worker command support, renderer recovery, and production browser gates remain future work.

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
- Browser / JavaScript: Canvas 2D proof implemented and exercised in Chromium.
- Windows: experimental one-window Win32/D3D11 hardware-or-WARP slice and example implemented; the hosted workflow is configured but has not yet produced evidence.
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
| M3 | Stable scene data, primitives and renderer abstraction | In progress; quad/clip/transform/opacity snapshot slice implemented |
| M4 | First native platform slices | macOS and Ubuntu/Wayland slices implemented; experimental Windows slice added; native evidence and service coverage remain incomplete |
| M5 | Text and interaction completeness | Planned |
| M6 | Multi-platform support gates, including Windows | Planned |
| M7 | Production-ready 1.0 gates and sustained non-demo use | Planned |

M7 does not require implementing every upstream GPUI feature. It requires a stable documented API, explicit supported-platform matrix, reproducible builds/tests/releases, no release-blocking correctness issues, performance and accessibility evidence, diagnostics, and an audited dependency/provenance boundary.

## Where future work lives

- [`issues/open/`](../issues/open/) contains implementation packets.
- [`testing.md`](testing.md) defines validation strategy and broader gates.
- [`release.md`](release.md) and [`release-gates.json`](release-gates.json) define release evidence.
- [`platform.md`](platform.md) defines the platform boundary.
- [`compatibility.md`](compatibility.md) records behavioral comparison status.
