# Architecture and dependency contract

Status: M1 core plus M2 layout/element and M3 headless scene package boundaries are implemented; native renderer/platform layers remain planned.

This is the dependency and package boundary for M1 through M5. The module is `f4ah6o/gpui` in [`moon.mod`](../moon.mod), with current runtime packages `primitives/`, `diagnostics/`, `core/`, `layout/`, `scene/`, and `element/`. The lifecycle and entity semantics are in [product.md](product.md), while implementation evidence is tracked in [compatibility.md](compatibility.md).

## Runtime dependency budget

The published gpui.mbt runtime may depend on:

- the MoonBit language runtime and MoonBit standard/core packages;
- packages implemented in this repository;
- native operating-system APIs behind a gpui.mbt-owned backend and narrow FFI boundary.

No third-party MoonBit package is a runtime dependency by default. The current runtime packages import only MoonBit standard/core and repository packages. If a required facility is missing from standard/core, first write a narrow internal contract, implement the minimum behavior here, and test it independently. Reconsider extraction only after gpui.mbt has exercised the API. Do not vendor a general-purpose dependency merely to save initial implementation effort.

Development and CI tools are separate from the runtime graph. The initial allowed tools are `moonbitlang/quickcheck` for properties, `f4ah6o/turtles` for mutation testing, optional `mizchi/vlmkit` for external artifact review, and the required platform CI tools. None may be imported by the published runtime packages. Their exact locked revisions, licenses, and transitive graphs belong in the development dependency audit.

For every release candidate, archive a machine-readable dependency inventory for runtime and development graphs separately. The audit must show direct and transitive MoonBit packages, target-specific native libraries, resolved revisions, license identifiers, and the package that introduced each dependency. Any native library must additionally name its platform, purpose, FFI owner, upgrade source, and failure behavior. A new runtime dependency requires a written exception in this document and a compatibility/release review; there is no implicit exception for the upstream Rust GPUI dependency list.

## Package direction

The intended dependency graph is acyclic and points from application-facing concepts toward lower-level contracts. M1 package names and their allowed imports are fixed as follows:

```text
application API / facade
  ├── core ──────────────> diagnostics ──> primitives
  │       └─────────────────────────────> primitives
  ├── element ──> layout ───────────────> primitives
  │      └──────> scene ────────────────> primitives
  └── platform API ──────> core + diagnostics + primitives
          └──────────────> renderer API ──> scene + primitives

target backend ──> platform API + renderer API + scene
target FFI     ──> native OS / graphics / text APIs

primitives ──> MoonBit standard/core only
diagnostics ─> MoonBit standard/core + primitives
core       ──> MoonBit standard/core + diagnostics + primitives
```

The facade is a re-export surface; it must not contain a second implementation of lower-layer behavior. `core`, `geometry`, `layout`, `element`, `scene`, and renderer/platform contracts remain platform-neutral. A concrete backend may depend on these contracts, but no lower layer may import a concrete backend, renderer, OS handle, or native FFI type. `scene` contains portable draw data, not GPU resources. The renderer API consumes scene data and exposes framework-level resource and failure categories. Only the backend owns windows, event-loop integration, display information, clipboard, cursor, menus, accessibility bridges, text services, GPU surfaces, and native resources.

## Layer responsibilities and allowed edges

| Layer | Owns | May depend on | Must not expose |
|---|---|---|---|
| `primitives/` | IDs-independent geometry, color, input, and event value types | MoonBit standard/core only | app-owned IDs, state, platform handles |
| `diagnostics/` | shared error categories and structured diagnostic values | MoonBit standard/core, `primitives/` | concrete backend types and framework state ownership |
| `core/` | app/entity/task IDs, App/Entity/Context, lifecycle, subscriptions, deterministic foreground scheduler | MoonBit standard/core, `diagnostics/`, `primitives/` | window, OS, GPU, renderer, or concrete backend types |
| `examples/headless/` | consumer usage example and executable API example test | public `core/`, `diagnostics/`, and `primitives/` interfaces | runtime imports, native/platform APIs, private core types |
| `layout/` | style subset, constraints, intrinsic measure interface, layout result | `primitives/` | renderer or platform types |
| `element/` | Render/IntoElement/Element, tree, hit-test and dispatch metadata | `core/`, `primitives/`, `layout/`, `scene/` contract | backend callbacks or OS event structs |
| `scene/` | stable, platform-neutral paint commands and ordering | `primitives/` | live GPU handles or backend resource objects |
| `renderer API` | render submission and resource-lifetime contract | `scene/`, `primitives/` | a concrete renderer vocabulary in public app APIs |
| `platform API` | window, input, display, text, clipboard, timer, accessibility contracts | `core/`, `diagnostics/`, `primitives/`, renderer API | platform-specific types in core/facade signatures |
| target backend / FFI | event loop and native resources/adapters | platform and renderer APIs; native APIs | types that leak upward through the public facade |

The current runtime edges are `primitives -> stdlib`, `diagnostics -> stdlib`, and `core -> stdlib + diagnostics`. The allowed boundary for diagnostics/core also permits imports from `primitives/`; they currently use no primitive value types. The executable dependency check covers these boundaries and test-only imports. The later packages are architectural boundaries for M2 onward and must be checked against the same rule when introduced. The dependency direction must remain acyclic; cross-cutting code belongs in a lower-level contract rather than a reverse import.

## Async and application scheduling

M1 implements a small synchronous app-executor scheduler, not a general asynchronous runtime. It defines the following observable behavior:

1. `App::dispatch` and zero-delay `schedule_after` tasks join one FIFO immediately when submitted. A foreground task receives only a `TaskContext`; entity mutation uses a separate `App::update` callback and scoped `Context`.
2. A task has one terminal state: `Completed`, `Cancelled`, or `Failed`; its observable path is `Queued -> Running -> terminal`, with `Queued -> Cancelled` allowed.
3. Cancellation clears queued callback state before it can run. Cancellation of running work is cooperative; it sets a token and cannot forcibly stop a function. A canceled task cannot deliver a success result.
4. Delayed timers use a manually advanced monotonic `UInt64` clock in tests and in the current core contract. Advancing the clock promotes due timers in deadline order, then registration order, appending them to the FIFO. Wall-clock reads are outside `core/`.
5. M1 has no background worker or executor. A later platform/backend package may add one, but it must accept immutable inputs, carry no `Context`, `Window`, or mutable entity reference across the boundary, and post completion back to the app executor. Tests must inject completion order.
6. `run_ready(budget)` processes no more than the requested count, rejects a negative budget, and cannot be called recursively or from an active read/update callback. Shutdown rejects new tasks, cancels queued tasks, requests cancellation from the running task, and queues entity teardown after the active callback.
7. Cancellation is normal control flow. Other task failures are wrapped as `TaskFailure`, preserve source code/operation/message context, and are available from both `Task::failure` and `App::diagnostics`.

The current executor uses an in-repository FIFO and deterministic timer list. Native loop wakeups, background execution, and timer integration remain future private backend responsibilities. The headless scheduler and state-machine tests run without a window server or GPU.

## Initial layout boundary

The first layout engine supports a deliberately bounded flex subset. It does not claim CSS or full GPUI style compatibility. The initial `layout/` package now implements deterministic layout for one definite row/column flex line, including points/percent/auto child dimensions, gap, padding/border, grow/shrink, one-pass min/max clamping, justification/alignment, stable child order, and explicit overflow reporting. Recursive auto-sized containers, intrinsic measure callbacks, element-tree integration, and the broader style surface remain pending.

### Inputs and outputs

- Coordinates and resolved lengths are finite logical points. Device pixels and scale conversion belong at the renderer/backend edge.
- Each node has a row or column flow direction, fixed or percentage dimensions, `auto` dimensions, gap, padding, border widths, min/max dimensions (with `min <= max` required per axis), flex basis, non-negative flex grow/shrink factors, main-axis justification, and cross-axis start/center/end/stretch alignment.
- Width and height are measured as border-box dimensions. Padding and borders are removed before child layout. An inner dimension never becomes negative; excess insets produce a zero inner dimension.
- A child can supply an intrinsic preferred size through a platform-neutral measure callback. Text intrinsic measurement is provided by the text-system contract; layout does not estimate text from character count.
- Percentage dimensions resolve only when the containing dimension is definite. A percentage against an indefinite dimension is `InvalidInput`; it is not silently treated as zero or auto.
- `auto` on the flow axis takes the sum of child bases and gaps plus insets; `auto` on the cross axis takes the largest child cross size plus insets. Empty auto containers resolve to their insets.

### Distribution and excluded behavior

For a definite main-axis size, layout subtracts gaps and insets, computes each child's basis, then distributes positive free space by grow factors or negative free space by `shrink * basis`. It clamps each result once to min/max. Space left after clamping is handled by the selected justification; it is not redistributed in a second flex pass. This explicit rule is simpler than the full CSS flex algorithm and is the first conformance target.

The first subset excludes wrapping, grid, absolute/fixed positioning, floats, percentage margins, arbitrary CSS units, intrinsic min-content/max-content negotiation, fragmentation, and browser-specific style behavior. These features return an explicit unsupported-style result if presented to this engine. Adding one requires contract and property tests before implementation.

Invalid or non-finite constraints are rejected before producing a layout tree. For valid input, identical constraints and intrinsic measurements produce identical logical bounds. Results must be finite and non-negative, respect declared min/max constraints, and preserve source child order. Child overflow caused by an explicit minimum larger than available space is allowed and reported in the result; layout does not hide it by returning invalid geometry. The `layout` to `element` boundary returns IDs and logical bounds only, not platform objects.

## Scene and renderer boundary

Scene generation and pixel output are separate oracles. A scene is an immutable or frame-bounded list of stable paint commands: quads, paths, clips, images, text runs, transforms, and stacking order. IDs and serialized scene ordering must be deterministic for identical input. Image/font resources are referenced by framework IDs plus validated descriptors, never raw GPU handles.

The renderer consumes scene values and reports typed outcomes for invalid resources, allocation failure, surface/device loss, and submission/presentation failure. A headless scene implementation exists before a GPU renderer. A software raster path may be added for deterministic pixels, but pixel equality across native text/render stacks is not a cross-platform contract. Backend recovery and raster performance gates are specified in the platform and release packets.

## Native and unsafe boundary

Native calls are contained in target backend/FFI packages. Every boundary must document ownership, lifetime, nullability, encoding, threading, callback/reentrancy, failure mapping, and cleanup. A callback after logical destruction must be ignored safely and diagnosed. Public core values use framework IDs or copied data; native handles never escape through `App`, `Entity`, `Context`, `Element`, or scene APIs.

Prefer a narrow C ABI when it keeps platform types out of MoonBit package interfaces and simplifies ownership review. A backend cannot be promoted to a supported platform tier while it has undocumented native boundaries, aborts on a recoverable operation failure, or lacks teardown coverage.

## Dependency audit and merge checks

Every dependency addition must identify whether it is runtime, development-only, or platform-native and list its owning package. The executable package-boundary check fails if test tooling reaches a runtime package or an unreviewed third-party MoonBit package enters the runtime graph. Native library inventories are separate per target. Dependency review must also check version pinning, license notices, and the lockfile/toolchain reproducibility policy.

The module plus M1 core and M2/M3 headless runtime packages exist. The package-boundary check validates the current graph, including `scene -> primitives`, `element -> core/primitives/layout/scene`, and the consumer-only `examples/headless/` package; it fails if a package introduces an unreviewed runtime dependency. Current contract, dependency, format, build, and test commands are listed in [README.md](../README.md).

## Initial native package edges

The first macOS slice adds checked edges `platform -> primitives/diagnostics/scene`,
`platform/macos -> platform/primitives/diagnostics/scene`, and
`examples/native_macos -> platform/macos/platform/primitives/diagnostics/scene`.
The portable Backend trait includes frame submission in this first slice; a
separate renderer interface is deferred. No reverse edge from core, element,
layout, or scene to a backend is permitted. Native OS dependencies and ABI
ownership are documented in [macos-native.md](macos-native.md).
