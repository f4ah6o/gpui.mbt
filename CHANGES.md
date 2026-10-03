# Changes

## Unreleased

### Added

- Added the headless M1 `core/` API for app and entity lifetimes, scoped contexts, subscriptions, structured errors, and deterministic foreground tasks. See [issue 0001](issues/open/0001-product-charter-and-compatibility.md).
- Added MoonBit `primitives/` and `diagnostics/` packages and an executable package-boundary check for the runtime graph. See [issue 0002](issues/open/0002-architecture-and-dependency-policy.md).

### Changed

- Defined deterministic FIFO event delivery, explicit `notify`, one revision per entered update (including failure), release cleanup, cooperative cancellation, and manually advanced timer semantics for the M1 core.

### Fixed

### Deprecated

### Removed

### Security

### Migration

- Entity payloads of generic type `T` must use immutable or copy-on-write values. Mutating a retained `Array`, `Map`, `Ref`, or other mutable alias outside `App::update` can bypass revision and notification tracking; M1 cannot enforce deep-copy ownership.
