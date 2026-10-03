# Status, limits, and roadmap

This document keeps project-state, support boundaries, and future work out of the user-facing README.

## Current position

The module version is `0.1.0`. The repository already contains usable headless UI foundations plus native macOS and Ubuntu/Wayland slices and a browser proof, but it does not currently make a production-support claim for any platform.

The portable codebase provides application/entity lifetimes, deterministic scheduling, flex layout, element trees, hit testing, capture/bubble event dispatch, focus, quad scene generation, clip validation, transforms, opacity, and canonical scene snapshots. The native/browser examples exercise subsets of that shared model.

Current main CI checks the portable MoonBit packages across configured targets, builds the macOS native bundle and native test runner, runs the Ubuntu 24.04 Wayland/Weston native workflow, and runs the real-Chromium browser proof.

## Current limits

### Core ownership

`Entity[T]` relies on immutable or copy-on-write payload discipline. MoonBit cannot deeply copy an arbitrary `T`, so mutating a retained `Array`, `Map`, `Ref`, or other mutable alias outside `App::update` can bypass revision and notification tracking.

### Rendering

The shared scene path currently centers on quads, rectangle clip chains, affine transforms, opacity, and canonical snapshots. Rich text, path, image, and broader resource rendering are not yet complete across the backends.

### Native services

The macOS and Ubuntu backends implement useful native window/render/input slices, but production text shaping, Japanese IME coverage, semantic accessibility, automated renderer recovery, sustained-resource evidence, and production performance gates remain incomplete.

macOS currently has the broader service slice, including clipboard and cursors. Ubuntu still has narrower service coverage; its detailed boundary is tracked in [the Ubuntu guide](ubuntu.md).

### Browser

The browser implementation is a JavaScript-target proof hosted by Canvas 2D. It shares the MoonBit application/layout/event/scene model, but it is not a complete browser backend. WebGPU, text/IME, accessibility, clipboard/cursor services, worker command support, and production browser gates remain future work.

### Platform coverage

- macOS: native AppKit/Metal slice implemented; production gates remain open.
- Ubuntu / Wayland: native Wayland/EGL/GLES2 slice implemented and exercised in hosted CI; production desktop gates remain open.
- Browser / JavaScript: Canvas 2D proof implemented and exercised in Chromium.
- Windows: no native backend yet.
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
| M2 | Element system, layout, hit testing, event dispatch and focus | In progress; substantial headless foundation implemented |
| M3 | Stable scene data, primitives and renderer abstraction | In progress; quad/clip/transform/opacity snapshot slice implemented |
| M4 | First native platform slices | In progress; macOS and Ubuntu/Wayland slices implemented |
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
