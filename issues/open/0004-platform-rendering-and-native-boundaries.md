# Platform, rendering, and native-boundary roadmap

Status: design only
Model: gpt-6-luna
Updated: 2026-10-03

## M0 resolution

The backend lifecycle, UI-thread and FFI ownership rules, event/error behavior,
versioned headless scene shape, text/IME contract, and semantic accessibility
contract are recorded in [docs/platform.md](../../docs/platform.md). macOS is
the first planned backend target; Windows and Linux remain planned. No native
backend or renderer is implemented by this M0 packet, and no platform has a
support claim. R0 is scene generation only. Native E2E, IME, accessibility,
multi-DPI, GPU recovery, performance, and resource-lifetime gates remain future
Tier 1 requirements.

## M1 evidence

Headless core lifecycle/scheduler and diagnostic contracts are implemented;
the four-package local test command
`moon test primitives diagnostics core testing/core_model --target native --deny-warn`
passes 29 tests. This is MoonBit native-target headless evidence only. No
platform API, GUI backend, native renderer, or platform support claim exists;
all native E2E, IME, accessibility, multi-DPI, renderer recovery, performance,
and resource-lifetime gates remain pending.

## Platform-specific child packets

Implementation is split into concrete backend packets so that "native" is
proven per operating system rather than inferred from MoonBit's native target:

- [0006 — macOS native backend](0006-macos-native-backend.md)
- [0007 — Ubuntu native backend](0007-ubuntu-native-backend.md)
- [0008 — Windows native backend](0008-windows-native-backend.md)

Each packet owns its native window/event-loop, rendering surface, input,
text/IME, accessibility, teardown/recovery, and OS-specific E2E evidence.
This parent issue continues to own the cross-platform contracts and support-tier
definitions.

## Goal

Reach native production quality while keeping the framework core platform-neutral and dependency-light.

## Backend strategy

Define framework contracts before selecting concrete APIs.

Each backend implements:

- application loop/wakeup
- window/surface
- input
- clipboard
- cursor
- display metadata
- text system hooks
- accessibility
- native menus if exposed
- GPU/render surface lifecycle

Backends must be replaceable behind the same conformance suite.

## Platform tiers

### Tier 0: builds

Compiles. Not a support claim.

### Tier 1: production supported

Must pass:

- native E2E
- IME baseline
- accessibility baseline
- multi-DPI behavior
- renderer recovery
- release performance budgets
- sustained-run leak/resource checks

### Tier 2: experimental

Useful for development but missing one or more Tier 1 requirements.

The README/support matrix must use these terms consistently.

## First backend selection

Choose the first platform based on ability to validate the full contract, not on minimizing demo effort.

The first backend should exercise:

- high-DPI
- IME
- accessibility
- real GPU surface lifecycle
- clipboard/input/focus
- multi-window

A backend is not done when a colored rectangle appears.

## Rendering contracts

Separate four things:

1. element/layout semantics
2. scene semantics
3. renderer/backend semantics
4. pixel output

This permits strong headless testing before native GPU work.

## Scene design

Scene records should be suitable for:

- deterministic tests
- batching
- clipping
- transforms
- text runs
- image resources
- incremental optimization later

Do not expose internal GPU handles in scene records.

## Renderer evolution

### R0

Headless scene only.

### R1

Reference software/headless raster path if needed for deterministic correctness tests.

### R2

One native GPU renderer sufficient for production backend.

### R3

Performance work:

- batching
- atlas/cache policy
- damage/invalidation strategy
- frame pacing
- resource lifetime
- device-loss recovery

Optimization must preserve scene-level oracle tests.

## Text boundary

The public text API should be platform-neutral.

Per-platform implementation can rely on platform text/font services through FFI if needed.

Conformance fixtures must cover:

- Latin
- Japanese
- mixed scripts
- emoji
- combining marks
- bidi examples
- fallback across fonts
- selection/caret positions

Do not declare production readiness with ASCII-only text confidence.

## IME

IME is a release gate.

Required behavior includes:

- composition start/update/commit/cancel
- caret/range mapping
- focus transitions during composition
- candidate-window positioning contract where platform exposes it
- Japanese input smoke coverage on supported platforms

## Accessibility

Build an internal semantic/accessibility tree independent from rendering.

Backend adapters translate it to native accessibility APIs.

Required baseline:

- role
- label/name
- value/state
- focus
- enabled/disabled
- actionable controls
- text where applicable

Accessibility must be testable headlessly at the semantic-tree layer and natively at backend integration layer.

## Error handling

Production backend contracts must define behavior for:

- GPU device/surface failure
- allocation/resource failure
- missing font
- invalid image resource
- window creation failure
- clipboard failure
- backend callback after logical object destruction
- FFI conversion failure

Do not convert recoverable backend errors into unconditional process aborts.

## Diagnostics

Provide enough structured information to identify:

- backend/platform
- operation
- entity/window identity where safe
- renderer/device state category
- source subsystem

Diagnostics must not require enabling an unrelated third-party logging runtime.

## Performance measurement

Track at least:

- time to first window/frame
- steady-state frame time for representative scenes
- layout time
- text shaping time
- scene build time
- GPU submit/present time where measurable
- memory after repeated create/destroy cycles
- input-to-frame latency proxy

Budgets are defined before 1.0 in the production-readiness packet.

## Cross-platform consistency

Exact pixels need not match across native text/rendering stacks.

Semantic contracts must match:

- layout within documented tolerances
- input/event ordering
- lifecycle
- accessibility semantics
- focus
- action dispatch

Pixel goldens are platform-specific unless a deterministic common raster backend is used.


## R0 foundation update — 2026-10-03

A platform-neutral `scene/` package now provides the first R0 implementation slice: stable ordered quad and clip commands with no native/GPU handles, and `element/` can emit background quads deterministically. This is intentionally smaller than the contracted versioned SceneSnapshot: resources, transforms, paths, images, text runs, canonical serialization, renderer API, rasterization, GPU surfaces, and every native backend remain pending. No platform support tier changes.


## R0 command snapshot update — 2026-10-03

`scene/` now exposes an unversioned provisional `CommandSnapshot` with logical viewport, finite positive scale validation, owned ordered commands, and canonical compact serialization. It is deliberately distinct from and does not consume the full contracted R0 `SceneSnapshot` schema version 1: resource tables, clip-chain tables, flat rich `SceneItem` data, transforms, paths, images, text runs, and renderer/native surfaces remain pending. No platform support tier changes.


## Event/focus and clip invariant update — 2026-10-03

The next headless correctness slice is implemented. M2 now has immutable
`ElementTree::without_subtree`, which removes a complete subtree and clears
focus when the focused node is removed, plus seeded QuickCheck properties for
capture/bubble route reversal, global stop-propagation, and live focus after
subtree removal. M3 now validates clip pushes/pops as a strict LIFO stack and
rejects underflow, ID mismatch, and unclosed clips before a provisional
`CommandSnapshot` is emitted; a seeded clip-stack property accompanies the
deterministic cases.

This does not complete the packet. Render/IntoElement lifecycle, recursive auto
layout, the reserved `SceneSnapshot` v1 resource/clip-chain/item schema,
mutation baselines, visual/native evidence, renderer/backend work, and later
production gates remain open.


## R0 versioned snapshot subset update — 2026-10-03

R0 now includes a `SceneSnapshot` envelope with `schema_version: 1` alongside
the provisional unversioned `CommandSnapshot`. The implemented subset converts
ordered quad and rectangle-clip commands into flat items and deterministic
clip-chain references, carries finite affine transform/opacity fields, exposes
the resource/clip-chain/item table shape, and serializes canonically.

This does not complete the contracted v1 scene. Quad border/corner data, path
clips, paths, images, text runs and their resources are still pending, as are
R1/R2/R3 renderer work, native surfaces/backends, text/IME, accessibility,
device-loss recovery, and every platform support gate. No platform tier changes.


## Headless element lifecycle update — 2026-10-04

The portable element package now supplies a bounded `Render`/`IntoElement`
surface and an executable request-layout → prepaint → paint sequence. Layout
uses the recursive flex tree under a definite root viewport and measures auto
container dimensions from child bases, gaps, min/max constraints, and insets;
percentages on an auto-measured axis are rejected as indefinite. Prepaint
builds the live hit-test tree with absolute logical bounds; paint returns the
platform-neutral quad scene. `paint_snapshot(scale)` freezes those quads into
the current SceneSnapshot v1 subset for a renderer boundary. The lifecycle
contains no backend or GPU type and does not change any platform support tier.

The current layout tree has an explicit maximum nesting depth of 64. The
renderer interface/implementation, non-quad scene items and resources,
invalidation/damage, software raster oracle, GPU surfaces/recovery, and native
platform conformance remain pending. The lifecycle and rendering compatibility
rows remain `planned` until the behavior is compared with the pinned GPUI
revision and the renderer gates have evidence.

The recursive layout path scans the flat preorder node array per container and
may repeat scans while measuring nested auto dimensions. Worst-case work grows
quadratically with node count; the depth limit protects stack use only.
