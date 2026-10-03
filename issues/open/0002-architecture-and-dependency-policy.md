# Architecture and dependency policy

Status: design only
Model: gpt-6-luna
Updated: 2026-10-03

## Dependency rule

The gpui.mbt runtime/library dependency budget is:

- MoonBit language/runtime
- MoonBit standard/core functionality
- platform APIs reached through repository-owned FFI/backend code

No third-party MoonBit package is a production runtime dependency by default.

When standard functionality is insufficient:

1. define the missing capability as a narrow internal contract;
2. implement the minimum required behavior in-repo;
3. test it independently;
4. avoid growing it into an unrelated general-purpose library inside gpui.mbt;
5. reconsider extraction only after the API is proven by gpui.mbt.

## Explicit tooling/test exceptions

The dependency rule does not prohibit external development tools.

Allowed initially:

- moonbitlang/quickcheck for property-based tests
- f4ah6o/turtles for mutation testing
- mizchi/vlmkit as optional black-box visual/UX verification tooling
- GitHub Actions and platform-native CI tooling

These must not be imported by the public runtime packages shipped to application users.

## Package layering

Target dependency direction:

```
app-facing API
    |
    v
core state/lifecycle
    |
    +--> element/layout/input
    |        |
    |        v
    |      scene
    |        |
    |        v
    +---- renderer contracts
             |
             v
       platform backend
             |
             v
          native FFI
```

Higher layers may not import concrete native backend implementation details.

## Core

Core owns:

- stable IDs
- App lifecycle
- Entity[T]
- Context[T]
- observation/subscriptions
- action dispatch contracts
- deterministic scheduler abstraction
- errors and diagnostics contracts

Core must run headlessly.

## Element/UI

Owns:

- Render
- IntoElement
- Element
- style values
- layout input/output
- hit-testing metadata
- event propagation
- focus traversal

It produces platform-neutral scene/input structures.

## Scene

Owns an immutable or frame-bounded representation of paint output:

- quad
- path
- clip
- image
- text run
- stacking/order
- transforms

Scene serialization for tests should be stable and versioned.

## Renderer

Renderer consumes scene data and platform resources.

Public application code must not depend on Metal, Direct3D, Vulkan, OpenGL, wgpu, or any specific renderer vocabulary.

Backend choice remains replaceable.

## Platform boundary

Platform backend owns:

- window creation/destruction
- event loop integration
- displays/scale factor
- mouse/keyboard
- IME
- clipboard
- cursor
- menus
- accessibility bridge
- timers/wakeup
- native surface creation

Use a repository-owned narrow FFI layer. Prefer C ABI boundaries where that reduces coupling.

## Async model

Do not import a general-purpose async runtime solely because upstream Rust GPUI uses async Rust.

Define the semantics required by GPUI first:

- spawn task
- cancel/drop task
- foreground/UI dispatch
- background work
- timer/sleep
- wake application loop
- deterministic test executor

Then implement the minimum substrate needed by those semantics.

## Layout

Do not add a production dependency on Taffy merely to mirror upstream.

Specify required flex/layout semantics as tests and implement the supported subset in-repo. Unsupported CSS-like behavior must be explicit rather than accidentally divergent.

The layout engine needs property tests for invariants such as:

- non-negative resolved sizes where required
- containment after padding/border application
- monotonicity under available-size increases for applicable modes
- stable result for identical inputs
- no NaN/invalid geometry propagation

## Text

Text is a platform-quality subsystem, not a string-to-pixels helper.

Separate:

- font discovery
- font fallback
- shaping
- glyph metrics
- line breaking
- bidi
- selection/caret mapping
- raster/cache
- accessibility text mapping

Native libraries may be accessed through backend FFI when reimplementing them would be unreasonable, but the decision must be documented per platform and must not leak through public API.

## Unsafe and FFI policy

Every unsafe/native boundary must document:

- ownership
- lifetime
- threading requirements
- nullability
- encoding
- callback/reentrancy rules
- failure mapping
- cleanup behavior

A platform backend cannot be promoted to production tier while undocumented FFI boundaries remain.

## API stability

Before 1.0:

- breaking changes allowed
- compatibility notes required after public examples depend on an API

At 1.0:

- semantic versioning
- deprecation before removal except for security/correctness emergencies
- migration notes for breaking major versions

## Rejected architecture

Do not make these permanent foundations:

- embedding Rust GPUI and exposing it through FFI
- shipping Node/browser runtime as the desktop renderer
- using vlmkit as an application runtime dependency
- accepting platform-specific types in the framework's core API


## Incremental delivery record — 2026-10-03

The M0 architecture and dependency contracts are in [docs/architecture.md](../../docs/architecture.md). The MoonBit module is `f4ah6o/gpui`; M1 runtime packages are `primitives/`, `diagnostics/`, and `core/`. Current runtime imports contain no third-party MoonBit package. Their allowed dependency boundaries and current actual edges are stated in the architecture document and are checked by the repository's executable package-boundary validation.

The deterministic `core/` scheduler is synchronous and headless: zero-delay work enters the FIFO at submission, timers use a manual monotonic clock, and cancellation is cooperative for running callbacks. No GPU, window, native FFI, or external runtime dependency is present in M1. Platform-specific dependency/license inventories, native boundary records, M2+ package edges, and release-candidate transitive audits remain future work. This increment does not complete the long-term policy packet or change its design-only status.

Validation: `moon fmt --check`, `moon check --deny-warn --target all`, `moon test --deny-warn --target all` (30/30 each on wasm, wasm-gc, js, and native), `python3 scripts/check_contracts.py`, and `python3 -m unittest discover -s tests` (20 tests) all pass.


## M2/M3 dependency update — 2026-10-03

The executable dependency policy now recognizes `scene -> primitives` and `element -> core/primitives/layout/scene` in addition to the existing layers. `scripts/check_contracts.py` requires both new runtime packages and rejects unapproved internal or third-party runtime edges; its Python tests cover these boundaries. The new packages use repository-owned MoonBit code only and add no production runtime dependency.
