# Platform boundary contract (M0)

This document defines the M0 backend design target and core/backend conformance
boundary. Its host/window/quad subset now has a first Ubuntu/Wayland implementation,
without a platform support claim. See [Ubuntu implementation and limits](ubuntu.md).
R0 now has both the
provisional command stream and a versioned SceneSnapshot v1 subset, but the
snapshot is not yet the complete schema described below.

## Boundary and first backend

Framework code talks to a platform-neutral backend interface. The interface
owns the event loop, native windows and surfaces, input translation, display
metadata, clipboard, cursor, text-input/IME bridge, accessibility adapter, and
native menu service when exposed. Concrete native types and handles stay inside
the backend. Core, element, scene, and public application APIs use repository-
owned values and errors only.

The first backend target is macOS, using a thin repository-owned C ABI shim over
AppKit, Core Animation, and Metal. AppKit supplies the application loop,
windows, events, clipboard, cursor, menus, text-input client, and accessibility
integration; a `CAMetalLayer` backed by Metal supplies the GPU surface and
device lifecycle. This target can exercise the full M0 contract on the
project’s initial development platform.
Windows remains planned and will map the same contract to Win32, native
text/accessibility services, and a GPU surface. Ubuntu now uses Wayland/xdg-shell
and EGL/GLES for its initial native slice; complete text/accessibility services
and other Linux configurations remain implementation work. At M0 no backend has a support claim; a
build alone is Tier 0, and Tier 1 requires every gate in issue 0004 and the
production-readiness packet.

## Operations and lifecycle

The backend exposes these logical operations. Calls return a typed result and
do not terminate the process for an ordinary platform failure.

| Area | Operations | Contract |
| --- | --- | --- |
| Host | `start`, `run`, `wake`, `request_exit`, `stop` | `start` returns only after initialization succeeds. `wake` may coalesce, but cannot lose a queued command. `stop` is idempotent and releases owned native resources. |
| Window | `create_window`, `show`, `set_size`, `set_title`, `request_close`, `destroy_window` | Creation is atomic from the caller’s view: success returns a live logical ID; failure returns no half-live window. Destruction is idempotent. |
| Surface | `create_surface`, `resize_surface`, `present`, `release_surface`, `recover_renderer` | A surface is tied to one live window generation. Resize and device-loss recovery may invalidate native resources without invalidating the logical window. |
| Input/focus | translated pointer, keyboard, focus, and close events | Events carry a window ID, monotonic sequence within that window, logical coordinates, and the scale factor observed with the event. Ordering from the native queue is preserved. |
| Display | `displays`, `window_scale` | Geometry is in logical points; scale is finite and positive. A display change updates scale before later input and frame events use the new value. |
| Services | `read/write_clipboard`, `set_cursor`, `set_menus`, `accessibility_action` | Unsupported services return `UnsupportedCapability`; they do not silently report success. |
| Text input | `begin/update/commit/cancel_composition`, `set_candidate_rect` | Composition is scoped to the focused text target and its live window generation. |

The host state machine is `Uninitialized -> Running -> Quiescing -> Stopped`.
Initialization failure leaves it `Uninitialized`; `request_exit` moves it to
`Quiescing`; no new windows are accepted after that transition. `stop` drains
queued destruction work, unregisters callbacks, releases surfaces, then windows,
then the application object. Repeated `stop` calls have no effect.

Each window moves through `Creating -> Alive -> Closing -> Destroyed`. The
backend assigns a core-owned `WindowId` before native creation, but publishes it
only after creation succeeds. `request_close` emits a close-request event; core
policy decides whether to destroy. Once destruction starts, later native
callbacks for that window generation are dropped. No event is delivered after
the final `Destroyed` notification.

Renderer state is `Unavailable -> Ready -> Recovering -> Ready` or
`Unavailable`. Surface/device loss enters `Recovering`, invalidates frame-local
resources, and coalesces duplicate loss notifications into one recovery
episode. An episode makes at most three creation attempts at 0 ms, 50 ms, and
250 ms, all within a one-second deadline. There is no busy
loop. Exhaustion enters `Unavailable` and emits one error; a later explicit
`recover_renderer` request or a new native device-reset event may start a new
episode. Recovery failure is reported as a recoverable renderer error; the
application remains alive so it can show or log the failure. Window destruction
releases its surface before its native window. Stale surface operations return
`StaleHandle`.

## Identity, threading, and ownership

Core owns monotonically allocated, generational `WindowId`, `EntityId`,
`TaskId`, and accessibility `NodeId` values. IDs are values, not pointers, and
are not reused while an event or callback for that generation could still be
observed. A backend may maintain a private native-object map keyed by
`(WindowId, generation)`, but native pointers never escape that map. A stale
generation is rejected or dropped and cannot target a newly created window.

Each backend has one UI-owner thread. Host, window, focus, clipboard, cursor,
menu, and accessibility operations execute on that thread. A synchronous
operation called from another thread returns `WrongThread`. The only
cross-thread entry point is `enqueue(command)`: it copies/owns the command,
allocates a `CommandId`, wakes the event loop, and returns that ID immediately.
The backend later emits exactly one `CommandCompleted(CommandId, Result)` on
the UI event stream. Commands accepted before quiescing complete or fail during
drain; submissions after quiescing return `HostStopping`. Native callbacks are
serialized onto the UI thread and translated into backend-neutral events.
Callbacks do not re-enter core while core is making a backend call: callbacks
enqueue events, and core dispatch starts after the current FFI call unwinds.
Destroy requests made during event dispatch take effect logically at once;
native teardown is deferred until dispatch returns. This makes callback-after-
destroy and re-entrant destruction safe and gives the later core scheduler a
single ordering contract.

The backend owns native objects and native allocations. Core owns logical
records, scene values, and copied event/text payloads. No pointer into a moving
MoonBit value may be retained by native code or across an asynchronous call.
Native callbacks borrow payload buffers only until the callback returns; core
copies data it needs afterward. Every registration has an unregister operation
whose completion guarantees that no future callback for that registration will
run.

## C ABI and error shape

The macOS bridge uses a versioned, repository-owned C ABI. ABI records use
fixed-width integers, explicit enum tags, `u8` booleans, and opaque integer
tokens; they do not expose Objective-C objects, Swift values, Rust types, or
native pointers. Every structure starts with `abi_version` and `struct_size`
so additions can be detected. Text is `(const uint8_t *bytes, uint32_t len)` in
UTF-8; it is length-delimited, may contain NUL, and is never read with
`strlen`. Input pointers are borrowed for the call only. Output buffers are
caller-owned, or have a matching backend release function. Callback userdata is
an opaque token resolved by the backend, not a MoonBit heap address.

Every operation returns a status code plus an optional operation/object token.
The status identifies a stable category (`AppNotRunning`, `WrongApp`,
`EntityNotLive`, `ContextExpired`, `InvalidInput`, `ReentrantUpdate`,
`CallbackFailure`, `TaskFailure`, `UnsupportedCapability`, `StaleHandle`,
`PermissionDenied`, `Busy`, `ResourceExhausted`, `WindowUnavailable`,
`SurfaceLost`, `DeviceLost`, `ConversionFailed`, `WrongThread`,
`HostStopping`, or `NativeFailure`). A diagnostic record adds backend,
operation, logical object IDs when safe, and subsystem. Human-readable native
text is best-effort diagnostic context, not a programmatic discriminator.
Recoverable errors are returned to the caller; they are not converted to
unconditional abort or panic.

The MoonBit representation is `diagnostics.FrameworkError`: it carries the
stable code and operation plus optional logical app/entity/window/task IDs and
optional subsystem, backend, and message strings. Operation is capped at 96
Unicode scalars, subsystem/backend at 48 each, and message at 256. The
single-owner `DiagnosticSink` stores at most 256 records in FIFO order and
tracks saturating lifetime counts by code, total records, and evictions. It
adds no clock or thread-dependent data, so the same call sequence produces the
same snapshot and counters. Platform error adapters map native outcomes into
these framework categories at the boundary.

| Failure | Required behavior |
| --- | --- |
| Window creation fails | Return an error, clean partial native state, and keep the host running. |
| Clipboard is busy or denied | Return an error; preserve the last known core state and allow the caller to retry. |
| Surface/device is lost | Enter `Recovering`, invalidate surface resources, report the transition, and attempt recreation. |
| Resource allocation fails | Return `ResourceExhausted`; discard optional caches where safe and keep logical objects valid. |
| Font is missing | Use the selected fallback or missing-glyph representation and emit a diagnostic; do not abort. |
| Invalid UTF-8/native conversion | Reject only that payload or operation with `ConversionFailed`; retain no borrowed buffer. |
| Callback arrives for a destroyed/stale object | Drop it and record a diagnostic counter; do not dereference stale state. |
| Unsupported native capability | Return `UnsupportedCapability` and expose the capability as unavailable. |

## Scene and renderer boundary

R0 produces only platform-neutral scene data; it does not create a native
surface or promise raster output. The current `scene/` package keeps the
provisional unversioned `CommandSnapshot` and now also exposes a versioned
`SceneSnapshot` envelope with `schema_version: 1`, logical viewport/scale,
resource and clip-chain tables, flat ordered items, finite affine transforms,
opacity, and canonical compact serialization with negative-zero normalization.
The implemented v1 subset converts the current quad plus rectangle-clip command
surface, reuses identical active clip chains deterministically, and currently
emits no renderer-facing resources. A bounded `TextItem` can also be added
directly to the v1 item list: it carries a MoonBit string, bounds, font size,
color, transform, opacity, and optional clip-chain ID. Canvas 2D draws one
system-sans run clipped to those bounds; native renderers return
`UnsupportedCapability`. It has no source ranges, shaping/measurement API, or
editor state. See [the implementation](../scene/snapshot.mbt),
[text validation tests](../scene/snapshot_text_test.mbt), and
[browser scope](browser-demo.md#bounded-text-and-visible-card-semantics).
The complete schema below still requires quad border/corner data, path clips,
paths, images, richer text runs, and their logical resources.
R1 may add a reference software raster path for deterministic
correctness checks. R2 adds the native
GPU renderer required by a production backend. R3 covers optimization and
device-loss recovery while preserving scene-level oracles.

The complete R0 design target has `schema_version: 1`, a logical viewport, finite
positive scale, logical resource table, ordered clip-chain table, and a flat
ordered list of `SceneItem` values. The item list is paint stacking order and
is stable for identical inputs. Every item contains a finite 2D affine
transform, opacity, and optional clip-chain ID. `Quad` contains a rectangle,
fill, border, and corner radii; `Path` contains ordered move/line/curve/close
verbs and fill/stroke styles; `Image` contains a logical image-resource ID,
source/destination rectangles, and sampling mode; `TextRun` contains UTF-8
text, style/font tokens, logical origin/baseline, and source ranges needed to
map selection and accessibility back to text. Clip chains contain ordered
rectangle/path intersections. No native GPU handles, mutable renderer caches,
or platform-specific font objects appear in the snapshot.

Geometry is expressed in logical points and represented as finite IEEE-754
binary64 values. Canonical JSON uses schema field order and shortest-round-trip
decimal numbers; negative zero is normalized to zero, item/clip/resource order
is preserved, and NaN/infinity are rejected before a snapshot is emitted.
Breaking envelope changes increment `schema_version`; the current v1 envelope
permits extending item variants, and consumers must reject unsupported variants
explicitly. Bounded text is such an extension and preserves existing quad JSON
bytes. Its canonical string encoding escapes quotes, controls, and non-ASCII
UTF-16 code units, including surrogate pairs, without introducing text-range
semantics. Snapshot equality is structural, not a pixel comparison. These rules
make scene tests reproducible without a window server or GPU.

## Text and IME

The following is the complete design target. The browser's bounded `TextItem`
and the interaction lab's committed-insert bridge do not implement this range,
shaping, selection, or IME contract. Weekboard's search/add fields use ordinary
HTML inputs; they do not establish portable text editing or native IME evidence.

The target public text model is platform-neutral. Text and composition payloads are
UTF-8. All ranges are half-open UTF-8 byte ranges whose endpoints must fall on
Unicode scalar boundaries; conversion to native UTF-16 or platform ranges is
backend work. User-visible caret and selection endpoints must also fall on
extended grapheme-cluster boundaries according to the core’s pinned Unicode
segmentation version, so an edit cannot split a combining sequence or emoji
ZWJ sequence. IME marked ranges may span scalar boundaries within a grapheme
while composing, but the active selection/caret remains grapheme-aligned. A
native range that cannot be preserved reports `ConversionFailed` instead of
moving the caret silently.

For each focused text target, IME state is `Idle -> Composing -> Idle`. Start
creates an empty marked range; update replaces the provisional composition and
reports its marked range and selection; commit emits committed text exactly
once and clears marked state; cancel clears marked state without committing.
Focus loss, target destruction, or window destruction cancels composition
before the corresponding blur/destroy event is delivered. Candidate-window
position is supplied in logical coordinates and converted by the backend. A
backend that cannot position a candidate window reports that capability as
unavailable. The contract suite must cover Japanese composition, mixed script,
selection/caret mapping, commit, cancel, focus changes during composition, and
candidate positioning where exposed.

## Accessibility

The following shared semantic-tree contract remains a design target.
[Weekboard's DOM projection](../examples/browser/site/canvas-accessibility.js)
currently maps a portable application layout DTO into visible-card buttons,
with stable task IDs, clipped bounds, node lifetime/order updates, and
focus/action reconciliation. Its [contract tests](../tests/browser/canvas-accessibility.test.mjs)
and [Chromium checks](../tests/browser/board.mjs) cover that bounded adapter;
they do not qualify a shared generational tree, native accessibility, or
screen-reader behavior.

The target core owns a semantic tree independent of the scene and pixels. Each live node
has a stable generational `NodeId`, parent/child order, role, label/name,
optional value, state, focused/enabled flags, supported actions, and optional
text plus selection/caret ranges. A committed semantic update is sent to the
backend before the next accessibility notification. The backend maps roles,
properties, and actions to the host accessibility API; it never infers them
from rendered pixels. Native actions resolve the current `NodeId` and route to
core; stale or disabled targets return a rejected action result. If native
exposure is unavailable, the backend reports that capability honestly while
the semantic tree remains testable headlessly.

## Conformance boundary

The backend conformance suite will verify lifecycle transitions, identity
generation, event ordering, scale/input mapping, stale callback handling,
resource cleanup, and structured error mapping. Headless tests own semantic
scene/text/accessibility expectations; platform E2E verifies native window,
IME, accessibility, clipboard, focus, DPI, and surface recovery. Exact pixels
may differ by platform; event, lifecycle, text-range, and accessibility
semantics must match.

## M1 implementation evidence

The repository now has headless core lifecycle/scheduler tests and structured
diagnostics. The separate initial Ubuntu platform/window/renderer slice is
described below; it is not part of the M1 core. The local command
`moon test primitives diagnostics core testing/core_model --target native --deny-warn`
passes 29 tests across the four packages. Here `--target native` identifies the
MoonBit test target; it is not native GUI or platform integration evidence.
No platform has a support claim, and the complete Tier 1 platform gates above
remain pending.


## R0 clip-structure validation update — 2026-10-03

At this stage, the provisional command scene validated clip pushes/pops as a strict LIFO
stack before a `CommandSnapshot` can be emitted. Underflow, mismatched IDs, and
unclosed clips are typed scene errors and are covered by deterministic and
seeded property tests. This remains part of the unversioned command foundation;
the contracted `SceneSnapshot` schema version 1 resource/clip-chain/item model
was still pending. The current subset is described above.

## First Ubuntu native implementation — 2026-10-03

The executable subset is `platform.Backend`, implemented by `ubuntu.Host` with
private Wayland/xdg-shell and EGL/GLES resources. It uses copied ordered events
and the existing immutable SceneSnapshot v1 quad subset. The full M0 design
above remains the target: cross-thread enqueue, complete native services, text
and accessibility, fractional scaling and automatic timed recovery are pending.
See [ubuntu.md](ubuntu.md) for exact tested behavior and current evidence.

## First native macOS implementation

The [macOS native slice](macos-native.md) adds the initial `platform.Backend`
interface and its AppKit/Metal implementation. It covers the first visible
window and SceneSnapshot v1 quad frame milestone, with native input/lifecycle
and GPU readback E2E. Cross-thread enqueue, text/IME, accessibility and automatic
renderer recovery remain design targets; the M1 evidence paragraph above is
historical. No Tier 1 or production release gate is promoted by this slice.
