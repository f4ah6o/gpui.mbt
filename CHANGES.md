# Changes

## Unreleased

### Added

- Added 41 capability/MCP mutation regression tests, independently reviewed per-operator baselines, survivor-identity checks, and retained CI reports. Bounded semantic conformance closes on verified merge after final-head stability and CI gates; async endpoint lifecycle/topology remains open in 0016. See the [semantic mutation contract](docs/semantic-mutation.md).

- Added portable `AppLifetime` tokens and app-owned capability registry creation/adoption. Stop now invalidates registered typed, GUI, and adapter handles and rejects cached or late results. See the [owner lifecycle contract](docs/capability-lifecycle.md).

- Added the first macOS AppKit/Metal backend and MoonBit quad demo, with a portable backend interface, logical input/scale events, typed failures, native frame/lifecycle/input E2E, app-bundle build script, and macOS CI build/evidence workflows. See [issue 0006](issues/open/0006-macos-native-backend.md). Text/IME, accessibility, automatic renderer recovery, and production support gates remain pending.

- Added the headless M1 `core/` API for app and entity lifetimes, scoped contexts, subscriptions, structured errors, and deterministic foreground tasks. See [issue 0001](issues/open/0001-product-charter-and-compatibility.md).
- Added MoonBit `primitives/` and `diagnostics/` packages and an executable package-boundary check for the runtime graph. See [issue 0002](issues/open/0002-architecture-and-dependency-policy.md).
- Added the first M2 `layout/` package: deterministic row/column flex-line layout with points/percent/auto child dimensions, gap, padding/border, grow/shrink, one-pass min/max clamping, alignment, overflow reporting, unit tests, and a seeded QuickCheck invariant.
- Added the M2 `element/` foundation with flat pre-order tree validation, reverse-paint hit testing, capture/bubble route planning, focus state, layout-box bridging, and deterministic element-to-scene generation.
- Added the M3 `scene/` foundation with ordered platform-neutral quad and clip commands and headless ordering/data tests.

### Changed

- Defined deterministic FIFO event delivery, explicit `notify`, one revision per entered update (including failure), release cleanup, cooperative cancellation, and manually advanced timer semantics for the M1 core.
- Extended the executable package-boundary policy with approved `layout -> primitives`, `scene -> primitives`, and `element -> core/primitives/layout/scene` runtime edges; all remain third-party-runtime-free.

### Fixed

### Deprecated

### Removed

### Security

### Migration

- A typed capability now belongs to at most one registry. Create fresh typed instances for independent registries; all copies of a registered handle follow its registry's irreversible lifetime. App-owned registries use `Registry::new_owned(app)` or `attach_owner(app)`.

- Entity payloads of generic type `T` must use immutable or copy-on-write values. Mutating a retained `Array`, `Map`, `Ref`, or other mutable alias outside `App::update` can bypass revision and notification tracking; M1 cannot enforce deep-copy ownership.


## Unreleased M2/M3 dispatch and snapshot slice

- Add callback-driven capture/bubble pointer dispatch with shared stop-propagation state and deterministic visited-path results.
- Add provisional `CommandSnapshot` values with validated positive scale, owned command storage, and canonical compact serialization while reserving `SceneSnapshot` v1 for the full R0 contract.
- Extend headless tests and implementation evidence without changing any platform support or release-gate claim.


## 2026-10-03 — M2 focus and M3 clip invariants

- add immutable element subtree removal that clears focus when the focused node dies
- add seeded event/focus properties for route reversal, stop-propagation, and focus validity
- validate scene clip stacks with typed underflow/mismatch/unclosed errors
- reject invalid clip structure before creating provisional command snapshots
- add seeded scene clip-stack properties

## 2026-10-03 — first Ubuntu Wayland native slice

- Add shared backend/window/event contracts and an owned Wayland/xdg-shell host.
- Add an EGL/GLES2 SceneSnapshot v1 quad renderer, ordered basic input, integer scale, frame completion, and explicit renderer recreation.
- Add the native MoonBit example, shared host conformance gate, GPU readback/lifecycle/FD tests, and Ubuntu 24.04 Weston CI at 1×/2×.
- Keep clipboard, IME/accessibility, fractional scale and production support gates open; see [Ubuntu evidence and limits](docs/ubuntu.md).
