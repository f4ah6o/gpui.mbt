# Platform, rendering, and native-boundary roadmap

Status: design only

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
