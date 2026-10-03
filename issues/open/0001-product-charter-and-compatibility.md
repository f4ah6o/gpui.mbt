# gpui.mbt product charter and compatibility goal

Status: design only
Model: gpt-6-luna
Updated: 2026-10-03

## Goal

Build a production-ready, MoonBit-native implementation of the GPUI programming model.

The project is not a source-to-source translation of Rust GPUI. It is an independent implementation that preserves the useful behavioral and API concepts of GPUI while fitting MoonBit's ownership, type system, runtime, FFI, and build model.

Production-ready means that a real desktop application can depend on gpui.mbt without carrying a second application framework or a Rust-side GPUI runtime.

## Product principles

1. MoonBit is the implementation language for framework logic.
2. Application-facing APIs should feel GPUI-like where that improves portability and learning.
3. Runtime/library dependencies should be MoonBit standard functionality only.
4. If a required primitive is missing, implement it in this repository rather than adding a general third-party runtime dependency.
5. Tooling and test-only dependencies are allowed when they do not become dependencies of applications using gpui.mbt.
6. Platform integration may use the smallest necessary native FFI surface.
7. No Rust compatibility shim is a permanent architectural requirement.
8. Headless behavior must be testable without a window server or GPU where practical.
9. Determinism, reproducibility, accessibility, and failure diagnosis are production requirements, not post-MVP polish.

## Compatibility target

Compatibility is behavioral and conceptual, not Rust source compatibility.

Track these GPUI concepts explicitly:

- Application / App lifecycle
- Entity[T] identity and state ownership
- Context[T] updates, notifications, observation, subscriptions
- Render and IntoElement
- Element lifecycle: request layout, prepaint, paint
- Window lifecycle and focus
- input/event dispatch and propagation
- actions and key bindings
- styling and layout
- scene primitives
- text shaping and text system contracts
- async tasks integrated with application lifecycle
- platform services such as clipboard, cursor, menus, display information, accessibility, and IME

For each tracked concept keep a compatibility matrix with one of:

- compatible
- compatible with documented deviation
- planned
- intentionally unsupported

Do not claim GPUI compatibility globally while required production surfaces remain unclassified.

## Non-goals

- Rust source compatibility
- binary compatibility with upstream GPUI
- reproducing Zed application-specific UI crates
- depending on Zed GPL components
- matching upstream bugs
- introducing ecosystem dependencies merely to shorten implementation

## Milestones

### M0: contracts

No UI implementation.

- public conceptual model
- upstream provenance policy
- compatibility matrix format
- dependency policy
- test strategy
- platform boundary
- production readiness gates

### M1: deterministic core

- geometry, color, IDs, event model
- App / Entity / Context semantics
- subscriptions and lifecycle
- deterministic scheduling model suitable for tests
- headless tests for all state transitions

### M2: element system

- Render / IntoElement / Element
- layout contract
- hit testing
- event dispatch
- focus model
- headless scene generation

### M3: rendering core

- retained/transient scene representation as required by the GPUI model
- quads, paths, clipping, images, text runs
- deterministic headless scene snapshots
- renderer/backend abstraction without leaking backend types into application code

### M4: first native platform

- real windows
- mouse, keyboard, focus
- clipboard
- timers/tasks
- text input and IME baseline
- GPU rendering
- production diagnostics

### M5: text, accessibility, interaction completeness

- shaping, font fallback, line layout
- accessibility tree
- IME composition correctness
- menus, cursors, drag/drop where required
- high-DPI and multi-display behavior

### M6: multi-platform

At minimum define supported tiers for macOS, Windows, and Linux.

A platform is not "supported" until its Tier 1 gate passes; compiling is insufficient.

### M7: production-ready 1.0

All release gates in 0005 are green, compatibility/deviation docs are current, and at least one non-demo application has exercised the framework under sustained use.

## 1.0 definition

1.0 is not "all of upstream GPUI is implemented." It is:

- stable documented public API policy
- supported-platform matrix
- no known correctness bug rated release-blocking
- reproducible CI and release process
- deterministic test suite
- PBT and mutation-testing quality gates
- visual regression path
- performance budgets with tracked regressions
- accessibility baseline
- panic/crash diagnostics
- documented unsafe/FFI boundaries
- upstream provenance and license audit
- migration/deprecation policy

M0 established the contract baseline in `docs/`; implementation proceeds milestone by milestone, with remaining design packets tracked as future work.


## Incremental delivery record — 2026-10-03

### M0 contract delivery

- Product and lifecycle semantics: [docs/product.md](../../docs/product.md).
- Package and dependency boundaries: [docs/architecture.md](../../docs/architecture.md).
- Upstream-pinned concept inventory: [docs/compatibility.md](../../docs/compatibility.md).
- Project support, milestones, and validation commands: [README.md](../../README.md).

### M1 deterministic core slice

Implemented the MoonBit `core/` package with opaque logical IDs and handles, App lifecycle, Entity create/read/update/revision/release, scoped Context tokens, change/release subscriptions, FIFO event delivery, deterministic foreground tasks, cooperative cancellation, and a manually advanced timer clock. Headless core tests and a separate reference-model suite cover lifecycle, failure, ordering, cancellation, and release behavior. The actual supported subset and deviations are documented in [docs/product.md](../../docs/product.md) and [docs/compatibility.md](../../docs/compatibility.md).

Generic mutable `T` aliases remain caller-managed: M1 requires immutable or copy-on-write payload discipline and does not claim deep-copy ownership. There is no window, rendering, native backend, or GPUI parity claim. M2 through M7 remain future milestones; this incremental delivery does not complete the long-term charter or change this issue's design-only status.

Validation: `moon fmt --check`, `moon check --deny-warn --target all`, `moon test --deny-warn --target all` (30/30 each on wasm, wasm-gc, js, and native), `python3 scripts/check_contracts.py`, and `python3 -m unittest discover -s tests` (20 tests) all pass.


## M2/M3 foundation update — 2026-10-03

The next headless slice now exists in `layout/`, `element/`, and `scene/`. M2 has deterministic flex-line layout plus a flat pre-order element tree with ID/parent validation, reverse-paint hit testing, root-to-target capture routes, target-to-root bubble routes, focusability/focus state, and deterministic background-quad scene generation. M3 has an ordered platform-neutral scene-command foundation for quads and clip push/pop commands.

This does not complete M2 or M3: Render/IntoElement/request-layout/prepaint/paint lifecycle, stop-propagation callbacks, recursive auto layout, stable scene serialization, paths/images/text/transforms, and renderer contracts remain open. Compatibility rows stay `planned` until comparison with the pinned GPUI revision exists.


## M2/M3 dispatch and snapshot update — 2026-10-03

The headless element foundation now executes capture and bubble callbacks, records the callbacks that actually ran, propagates callback errors, and supports shared stop-propagation state. The scene foundation now freezes ordered commands into an unversioned provisional `CommandSnapshot` carrying logical viewport and validated positive scale metadata, with deterministic compact serialization and negative-zero normalization.

This still does not complete M2 or M3. Render/IntoElement/request-layout/prepaint/paint lifecycle, recursive auto layout, the reserved `SceneSnapshot` v1 envelope with full R0 resource/clip-chain/item tables, paths/images/text/transforms, renderer contracts, and native rendering remain open.


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


## Recursive layout and SceneSnapshot v1 subset update — 2026-10-03

M2 now has a bounded recursive flex-tree layer over the existing flex-line
engine. It validates stable preorder/parent structure, recursively lays out
nested containers from a definite root, produces absolute descendant bounds,
propagates overflow, and has deterministic plus seeded QuickCheck coverage.
Intrinsic auto dimensions work through the existing `FlexItem` contract;
auto container sizing from descendant content remains pending.

M3 now has a versioned `SceneSnapshot` envelope with `schema_version: 1`,
logical viewport/scale, resource and rectangle clip-chain tables, ordered quad
items, finite affine transform/opacity fields, deterministic clip-chain reuse,
and canonical serialization. This is a v1 subset, not completion of the full
contract: quad borders/corners, path clips, paths, images, text runs/resources,
and renderer integration remain open.

`Render`/`IntoElement` and request-layout/prepaint/paint remain intentionally
unfixed because their MoonBit API shape is still undecided. Native platform,
text, accessibility, renderer, mutation/visual evidence, and production gates
also remain open, so this issue stays in `issues/open`.
