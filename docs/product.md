# Product charter and core behavior contract

Status: M1 headless core implemented; native UI and platform milestones remain planned.

This document fixes the product boundary and behavioral baseline. M1 implements the headless app/entity/context/scheduler slice described below. The complete GPUI concept inventory and evidence status live in [compatibility.md](compatibility.md); the package and dependency boundary lives in [architecture.md](architecture.md).

## Product promise

gpui.mbt is an independent MoonBit implementation of the GPUI programming model for native desktop applications. It will preserve useful GPUI concepts where they fit MoonBit, while defining MoonBit-native APIs and explicit behavior. It does not promise Rust source compatibility, binary compatibility, matching upstream bugs, or compatibility with Zed application crates.

The framework runtime is implemented in MoonBit. M1 delivers a headless `core/` package for app/entity/context lifetimes, subscriptions, and deterministic scheduling. A desktop backend may use a small repository-owned native FFI layer. An application using gpui.mbt must not need to ship a Rust GPUI runtime, browser runtime, or third-party MoonBit framework runtime.

The supported behavioral contract has four requirements:

- the same valid input and operation sequence produces the same observable order;
- core state and element behavior can be exercised without a window server or GPU;
- invalid lifetime, ownership, and backend operations produce diagnosable errors;
- the compatibility table reports evidence and deviations per concept instead of claiming global compatibility.

## App, Entity, and Context

### App lifecycle

An `App` is the authority for its live entities, subscriptions, and tasks. M1 has no window API yet. Each instance has a distinct identity; handles created by one app cannot be used with another. Application state is serialized on one foreground executor, called the app executor below. A future backend owns the native event loop and wakes this executor, but backend types do not appear in the core API.

The lifecycle is `New -> Running -> Stopping -> Stopped`. M1 exposes a reserved `Failed` enum case but does not produce it: initialization failure is not modeled by this headless slice. `Running` is entered once. `request_stop` is idempotent. From `New`, it transitions directly to `Stopped`. From `Running`, it rejects new work immediately, cancels queued app-owned tasks, asks a running task to cancel cooperatively, and releases entities before reaching `Stopped`. If called inside a callback, it invalidates contexts immediately and queues entity release after that callback. Calling an operation that requires `Running` in any other state returns `AppNotRunning` with the lifecycle name in its message; it does not silently enqueue work.

M1 tasks are synchronous app-executor callbacks; there is no background executor. A running task receives a cancellation token and must cooperate. Queued tasks are canceled before user code runs. Backend teardown and late-native-callback handling are future platform responsibilities.

### Entity identity and lifetime

`Entity[T]` is an opaque, value-like handle to app-owned state of type `T`. Copying a handle copies access to the same entity; it does not copy the state. The `EntityId` combines app identity with a monotonically allocated entity number; compare IDs rather than handles because M1 does not define `Entity[T]` equality. IDs are never reused during one app lifetime; allocation returns `ResourceExhausted` before the numeric counter can wrap.

An entity moves through `Live -> Destroying -> Dead`. Destruction is irreversible. The app marks the entity unavailable before it delivers release callbacks, so a callback cannot read or update the dying entity. A stale, destroyed, or foreign-app handle returns a typed error. It never recreates an entity or falls back to a different one. The app releases the stored `T` and its owned subscriptions after release callbacks finish.

Entity state is accessed through app callbacks, not through a public mutable pointer. A read callback sees one serialized state. An update callback may replace state synchronously; callbacks do not overlap, suspend, or yield halfway through an update. MoonBit generic values cannot be deeply copied or made immutable by this package. M1 therefore requires callers to use immutable or copy-on-write `T` values: a caller that retains and mutates a shared `Array`, `Map`, `Ref`, or mutable structure can change observed state outside `App::update`, bypassing revision and notification rules. `get`, `set`, and `read` do not prevent such aliases; this is an explicit compatibility deviation, not an ownership guarantee.

### Context lifetime and authority

`Context[T]` is the scoped capability passed to an entity update callback. It provides the current entity identity, scoped entity access, and explicit notification/observation operations. M1 has no app-wide context or cross-entity mutation API.

A context is valid only for the dynamic extent of its callback. M1 backs this with a shared runtime token, so a copied context used after callback return returns `ContextExpired`. It cannot be stored for later work, used from a background task, or used after the callback returns. Async code must retain an entity handle or immutable input and dispatch a new foreground callback to obtain a fresh context. The implementation rejects wrong-app, dead-entity, stopped-app, and expired-context access with a typed error at the boundary where that misuse can be detected.

### Update, revision, and notification

An update callback is one serialized observation boundary: no other app callback can observe intermediate writes. It is not a rollback transaction. If a callback fails after making in-place writes, those writes remain; the error is reported and diagnostics identify the entity and operation. Callers that need all-or-nothing state changes must validate and construct replacement state before assigning it. Every callback that was entered advances the entity revision exactly once when it exits, whether it returns or fails, because any partial writes are visible. A request rejected before the callback begins does not advance the revision.

The callback explicitly marks an entity dirty with `notify`. Zero or more calls to `notify` for the same entity inside one update coalesce to one notification. If a callback marked the entity dirty and then fails, one notification still follows the callback because the partial writes remain visible. If no notification was requested, no observer event is synthesized, even though readers can see the new revision. The event carries the revision after that callback attempt.

Notifications are delivered after the update callback returns, after the updated state is readable, and never reentrantly inside the mutating callback. M1 coalesces repeated `notify` calls per update and queues one `Changed` event for that entity. Active subscribers run in registration order. `observe` is change-only: on `Changed`, it queues the owner's update after the source callback; it does not run an update for `Released`. A callback that requests an update while handling a notification or task dispatch schedules that update at the FIFO tail; it cannot interleave with the current callback. Subscriptions created during a batch take effect for later event snapshots only. `App::read` may run during notification/task dispatch and reads the latest committed value; nested read/update callbacks and `run_ready` calls made during read/update callbacks are rejected as `ReentrantUpdate`.

### Observation, subscriptions, and release

Observation means “invalidate this dependent work when this entity changes.” A subscription means “deliver events from this source while this registration remains active.” Both return an opaque `Subscription`; `unsubscribe` is idempotent because MoonBit does not promise a deterministic `drop`. Unsubscribing prevents callbacks that have not started, including deferred observer updates already queued from a source event. A callback already running finishes normally.

Registrations are stored on the source and owned by the observing/subscribing entity. Destroying that owner deactivates its registrations and clears their callback closures. Releasing a source first marks it dead, then invokes active `subscribe` callbacks with one `Released` event in registration order; it does not emit a normal changed notification for destruction. `observe` does not receive a release update. Release subscribers receive identity and revision and can test that the source is no longer live, but cannot read its state. A callback failure is recorded as `CallbackFailure` and does not prevent later callbacks or cleanup. After release callbacks finish, the stored `T`, listener list, and owned-subscription list are cleared. `destroy_entity` returns after queuing release delivery; `request_stop` reaches `Stopped` once the FIFO drains. A release queued during app shutdown can be suppressed for a registration whose owner is itself released before delivery, because owner release deactivates it. The runtime drains callbacks in FIFO order with a caller-provided item budget.

## Error and diagnostics contract

Recoverable failures are returned as typed errors and carry operation context. Initial error categories are:

| Category | Examples | Required result |
|---|---|---|
| `AppNotRunning` | create an entity before start; dispatch or update after stop begins | reject before invoking user callback; include the lifecycle state |
| `WrongApp` | use an entity/context with another app | reject without touching either app |
| `EntityNotLive` | use a released or stale entity | reject without recreating state |
| `ContextExpired` | use a context outside its callback | reject at the context operation |
| `InvalidInput` | negative scheduler budget, malformed future resource descriptor | reject at the boundary with the field identified |
| `ReentrantUpdate` | nested read/update or scheduler drain in a protected callback | reject without changing revision or draining queued work |
| `NativeFailure`, `DeviceLost`, `SurfaceLost` | future window, clipboard, font, image, surface, or GPU operation fails | reserved shared diagnostic categories; M1 has no native operation |
| `CallbackFailure` | user update or listener callback returns an error | preserve cause context, keep defined partial state and revision semantics, continue cleanup |
| `TaskFailure` | non-cancellation task fails | preserve cause context, retain failure on task, and record diagnostics |

Cancellation is a terminal task result, not an error. M1 `App::diagnostics()` returns the bounded chronological diagnostic snapshot; there is no user error-hook callback yet. Diagnostics contain subsystem, operation, app/entity/task identity when safe, and a stable error category. Recoverable backend failures must not become unconditional process aborts. A final process panic is reserved for an internal invariant violation that cannot be recovered safely and must retain the originating subsystem information.

## GPUI-facing surface and current boundaries

The conceptual surface includes `App`, `Entity[T]`, `Context[T]`, `Render`, `IntoElement`, elements, windows, actions, events, style/layout, scenes, text, tasks, and platform services. M1 implements the headless app/entity/context/subscription/task slice in [`core/`](../core/) and shared value/error packages in [`primitives/`](../primitives/) and [`diagnostics/`](../diagnostics/). These rows remain `planned` in the compatibility matrix until behavior is compared to the pinned upstream revision and evidence supports a compatibility claim. See [compatibility.md](compatibility.md).

### M1 public core slice

`core/` exports opaque `App`, `Entity[T]`, `Context[T]`, `Subscription`, and `Task` handles; logical `AppId`, `EntityId`, and `TaskId`; lifecycle and event enums; and `Result`-based operations. The main entry points are `App::new/start/request_stop`, `create_entity`, `read`, `update`, `revision`, `destroy_entity`, `dispatch`, `schedule_after`, `advance_time_by`, `run_ready`, and `pending_work`. `Context` provides `get/set/notify/observe/subscribe`; `TaskContext` exposes cooperative cancellation. This package contains no renderer, window, OS handle, GPU, or background-thread API.

Every entered update advances revision once, including one returning `Err`; rejected calls do not. A callback failure preserves partial writes, wraps the cause as `CallbackFailure`, records it, and continues event delivery. A caller that invokes `update` from notification/task dispatch receives `Ok(())` when the update is accepted into the queue; a later failure is available in diagnostics. `run_ready(budget)` executes no more than `budget` FIFO items, returns the count processed, and rejects negative budgets. Zero-delay tasks join the queue when submitted. Timers use a manually advanced monotonic `UInt64` clock, are promoted when time advances, and order by deadline then registration sequence. `Task::cancel` clears queued callback state immediately; running cancellation is cooperative. Cancellation is task status, not a diagnostic error.

M1 implementation and headless tests are evidence that this package works according to this document on the local MoonBit target. They do not demonstrate GPUI parity or native desktop support. The deliberate mutable-alias limitation above remains a documented deviation until the API can require immutable payload types.

The first useful slice is headless core state and deterministic scheduling. Native windows, GPU presentation, IME, accessibility adapters, and platform services are later milestones. A MoonBit package test is core evidence only; the support policy and current native-platform state are in [README.md](../README.md).

## Independence and provenance

Upstream behavior reference is `zed-industries/zed` revision [`d9afb21688e04f89d9e94d96d33eb530aef90886`](https://github.com/zed-industries/zed/tree/d9afb21688e04f89d9e94d96d33eb530aef90886). The upstream GPUI crate manifest declares Apache-2.0 in [`crates/gpui/Cargo.toml`](https://github.com/zed-industries/zed/blob/d9afb21688e04f89d9e94d96d33eb530aef90886/crates/gpui/Cargo.toml). This pins the comparison target; it does not grant blanket permission to copy files from the Zed repository. Before adapting any source, verify the exact file context and license, record the paths and changes, and preserve required notices. M0/M1 documentation and M1 core are independently written; no upstream implementation code has been copied.

The project does not port Zed application-specific UI or depend on Zed's GPL components. Source-influenced implementation work will include the upstream path, local destination, license, and whether it is an adaptation or an independent behavior-based implementation. The full release audit policy is in [architecture.md](architecture.md).
