# Architecture and dependency contract

Status: M1 core plus M2 layout/element and M3 headless scene package boundaries are implemented; experimental macOS (including bounded grayscale text frames and a single-line text field), Ubuntu/Wayland/GLES (including bounded grayscale text frames), and Windows native slices are present; the JS browser hosts Weekboard and the retained interaction lab with its in-process capability/MCP seam; a separate Node stdio fixture exercises the stateless MCP wire adapter; native and browser MCP endpoint topology remains planned.

This is the dependency and package boundary for M1 through M5. The module is `f4ah6o/gpui` in [`moon.mod`](../moon.mod), with current runtime packages `primitives/`, `diagnostics/`, `core/`, `layout/`, `scene/`, `element/`, `text/`, `text_layout/`, `capability/`, and optional `mcp/`, plus native and example adapters. The lifecycle and entity semantics are in [product.md](product.md), while implementation evidence is tracked in [compatibility.md](compatibility.md).

## Runtime dependency budget

The published gpui.mbt runtime may depend on:

- the MoonBit language runtime and MoonBit standard/core packages;
- packages implemented in this repository;
- native operating-system APIs behind a gpui.mbt-owned backend and narrow FFI boundary.

No third-party MoonBit package is a runtime dependency by default. The current runtime packages import only MoonBit standard/core and repository packages. If a required facility is missing from standard/core, first write a narrow internal contract, implement the minimum behavior here, and test it independently. Reconsider extraction only after gpui.mbt has exercised the API. Do not vendor a general-purpose dependency merely to save initial implementation effort.

Development and CI tools are separate from the runtime graph. The initial allowed tools are `moonbitlang/quickcheck` for properties, `f4ah6o/turtles` for mutation testing, optional `mizchi/vlmkit` for external artifact review, Playwright for browser tests only, and the required platform CI tools. None may be imported by the published runtime packages. Their exact locked revisions, licenses, and transitive graphs belong in the development dependency audit.

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

semantic capability ──> core + diagnostics
optional MCP adapter ──> semantic capability + diagnostics
migration host-service bridge ──> semantic capability + diagnostics

target backend ──> platform API + renderer API + scene
target FFI     ──> native OS / graphics / text APIs

primitives ──> MoonBit standard/core only
text ─────────> MoonBit standard/core only
text_layout ──> text + primitives + MoonBit standard/core
platform/linux_text ──> text_layout + text + primitives + Linux PangoFT2/Fontconfig FFI
ubuntu ──private raster ABI──> platform/linux_text
ubuntu ──UTF-16 validation──> text
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
| `examples/browser_app/` | host-neutral interaction-lab model, event processing, flex layout, hit testing, and portable scene fixture | `core/`, `diagnostics/`, `element/`, `layout/`, `platform/`, `primitives/`, `scene/`, `capability/`, `mcp/` | DOM, Canvas, JS references, browser or native handles |
| `examples/browser/` | JS-only adapter translating browser callback values to framework events | `examples/browser_app/`, `diagnostics/`, `platform/`, `primitives/` | browser handles in shared packages or browser-to-model reverse dependencies |
| `examples/task_board/` | portable Weekboard task state, filtering/history, input, responsive flex layout, clipped hit testing, scrolling, drag gestures, and quad/text scene data | `capability/`, `core/`, `element/`, `layout/`, `platform/`, `primitives/`, `scene/` | DOM, Canvas, JS references, browser or native handles |
| `examples/browser_board/` | JS-only Weekboard exports over copied input, scene, status, and host-layout values | `examples/task_board/` | browser handles in shared packages or reverse dependencies from the task model |
| `layout/` | style subset, constraints, intrinsic measure interface, layout result | `primitives/` | renderer or platform types |
| `element/` | Render/IntoElement/Element, tree, hit-test and dispatch metadata, immutable scroll state and drag gesture transitions | `core/`, `primitives/`, `layout/`, `scene/` contract | backend callbacks or OS event structs |
| `scene/` | stable, platform-neutral quad/clip commands, bounded text snapshot items, validation, and ordering | `primitives/` | live GPU handles or backend resource objects |
| `text/` | UTF-16 ranges, directional selection, immutable documents, and composition transitions | MoonBit standard/core only | rendering, platform, or host-input types |
| `text_layout/` | Portable intrinsic text-measurement request/results and copied layout/caret/hit geometry | `text/`, `primitives/`, MoonBit standard/core | Pango/Fontconfig objects, native handles, GUI/session state |
| `platform/linux_text/` | Linux-only implementation of portable text-layout measurements, copied UTF-8/UTF-16 caret/hit results, and a private grayscale A8 mask raster ABI | `text_layout/`, `text/`, `primitives/`, MoonBit standard/core, Linux PangoFT2/Fontconfig via FFI | shared window `platform/` API, concrete backend, public renderer API, native object pointers, or persistent Pango handles |
| `platform/macos_text/` | macOS-only CoreText measurement, hit testing and bounded grayscale raster/admission for copied text values | `text_layout/`, `text/`, `primitives/`, MoonBit standard/core, CoreText/CoreGraphics via FFI | shared window API, editable owner state, scene types, persistent CoreText handles, color/bidi/multiline support |
| `examples/macos_text_field/` | Experimental single-line AppKit text field joining shared field state, CoreText geometry, accepted-frame drawing and opt-in per-window IME ownership | `platform/macos/`, `platform/macos_text/`, `controls/text_field/`, portable scene/layout/input contracts | a general editor API, global TextInput capability, bidi/reconversion/color glyph support, or production support claims |
| `capability/` | typed semantic operation descriptors, schema/value projection, registry, GUI binding, deterministic manifest generation | `core/`, `diagnostics/` | renderer/native/MCP transport state, host handles, duplicated domain handlers |
| `mcp/` | optional MCP-facing inventory/dispatch adapter over semantic capabilities | `capability/`, `diagnostics/` | application state ownership, domain handlers, privileged host APIs |
| `migration/host_services/` | portable service requests/completions, logical scopes, cancellation, bounded queues, and default-deny service policy for Electron/Tauri migration | `capability/`, `diagnostics/` | DOM, process APIs, native handles, or direct privileged service execution |
| `renderer API` | render submission and resource-lifetime contract | `scene/`, `primitives/` | a concrete renderer vocabulary in public app APIs |
| `platform API` | window, input, display, text, clipboard, timer, accessibility contracts | `core/`, `diagnostics/`, `primitives/`, renderer API | platform-specific types in core/facade signatures |
| `platform/` (first slice) | shared Backend trait, logical window IDs, copied ordered events | `scene/`, `diagnostics/`, `primitives/` | native pointers or OS types |
| `ubuntu/` | Wayland host/window, integer scale, basic input, EGL/GLES quad and bounded grayscale text renderer | `platform/`, `scene/`, `diagnostics/`, `primitives/`, `text/` for UTF-16 validation, private `platform/linux_text` raster ABI, system native APIs | native handles in public application signatures; Pango objects |
| `examples/ubuntu/` | native executable consuming the shared scene/window contracts | `ubuntu/`, `platform/`, `scene/`, `diagnostics/`, `primitives/`, standard env | private backend tokens |
| `windows/` | Win32 window/event loop, scale events, basic input, D3D11 hardware-or-WARP quad presentation | `platform/`, `scene/`, `diagnostics/`, `primitives/`, Windows system APIs | native handles in public application signatures |
| `examples/windows/` | native executable consuming the shared scene/window contracts | `windows/`, `platform/`, `scene/`, `diagnostics/`, `primitives/`, standard env | private backend tokens |
| `platform/windows_text/` | Windows DirectWrite copied single-line geometry and private bounded grayscale mask adapter | `text_layout/`, `text/`, `primitives/`, Windows DirectWrite APIs | native handles or shaping objects in portable values |
| `examples/windows_text_field/` | native focused single-line field and opt-in private IMM32 composition example | `windows/`, `platform/windows_text/`, `controls/text_field/`, `text/`, `text_layout/`, `element/`, `platform/`, `scene/`, `diagnostics/`, `primitives/` | public text-input capability or a qualified Japanese IME claim |
| target backend / FFI | event loop and native resources/adapters | platform and renderer APIs; native APIs | types that leak upward through the public facade |

The current runtime edges include `primitives -> stdlib`, `text -> stdlib`, `diagnostics -> stdlib`, `core -> stdlib + diagnostics`, `capability -> core + diagnostics`, `mcp -> capability + diagnostics`, and `migration/host_services -> capability + diagnostics`; the executable allowlist also records current layout, scene, element, native, and example edges. The browser app fixture is portable and can use the semantic registry plus an in-process optional MCP dispatch seam; the JS host adapter remains a leaf above it. The host-service bridge queues bounded JSON-compatible requests and completions over copied framework values; browser/Electron/Tauri adapters must enforce their own permission and host allowlists before acting. The executable dependency check covers these boundaries and test-only imports; new runtime packages still require an explicit layer entry and reject unlisted edges. The dependency direction must remain acyclic; cross-cutting code belongs in a lower-level contract rather than a reverse import.

The `text/` package is a pure immutable value model. `TextComposition` retains
the original document and target range, rebuilds every preview from that
original pair, maps relative UTF-16 selection endpoints into the resulting
document, and yields a committed or cancelled value. `TextDocument` also
provides strict UTF-16/UTF-8 scalar-boundary conversion; each conversion is an
O(n) scan with overflow-checked UTF-8 byte counts and no cached offset table.
It provides no mutable session owner, event sequencing, freshness guarantee,
undo history, grapheme segmentation, host adapter, layout, caret geometry, or
rendering. Host owners must enforce their own event ordering and ownership
rules.

The approved `capability -> core` edge consumes only the portable application
lifetime contract. `core` never imports capabilities, MCP, or platform code.
See [capability owner lifecycle](capability-lifecycle.md) for creation/adoption,
pre-start readiness, synchronous stop invalidation, and reentrant completion
semantics. This adds no third-party runtime dependency.

The optional MCP package generates transport inventory, projects each schema
to the modern MCP object-shaped tool contract, and routes wire calls back
through the same typed registry and domain handlers. Its stateless protocol
router implements discovery, tools, and query resources for MCP revision
`2026-07-28`. The checked JavaScript stdio fixture hosts that router as a
newline-delimited JSON-RPC subprocess; native and browser transport hosts,
prompts, legacy initialization, and interruption of running synchronous
handlers remain outside this adapter slice. See the [MCP adapter guide](mcp-adapter.md).

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

The first layout engine supports a deliberately bounded flex subset. It does not claim CSS or full GPUI style compatibility. The initial `layout/` package implements deterministic layout for one definite row/column flex line, including points/percent/auto child dimensions, gap, padding/border, grow/shrink, one-pass min/max clamping, justification/alignment, stable child order, and explicit overflow reporting. Recursive flex-tree layout is available beneath a definite root viewport. The `element/` package exposes immutable element builders, open `Render` and `IntoElement` traits, and a headless request-layout → prepaint → paint path: request-layout resolves the recursive boxes, prepaint builds the live hit-test tree, and paint emits the current quad scene. Nested auto-sized containers in this subset measure their flow axis from child bases and gaps, and their cross axis from the maximum child size; insets and min/max bounds are applied. Percentages against an auto-measured axis are rejected as indefinite, while orthogonal percentages against a definite axis remain supported. Element nesting is bounded at 64. The current recursive algorithm repeatedly scans its flat pre-order input and nested auto measurement can rescan descendants, giving quadratic worst-case work in node count; the depth bound protects stack use only, and performance has not been benchmarked. Intrinsic measurement callbacks, invalidation, and the broader style surface remain pending.

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

Scene generation and pixel output are separate oracles. The current command stream emits quads and rectangle clip push/pop commands. `SceneSnapshot` v1 adds explicit clip-chain tables, transforms, opacity, and ordered `TextItem` values alongside quads. The bounded text item is copied plain text plus bounds, font size, color, transform, opacity, and clip reference; it does not carry a native font handle or implement an editable-control contract. Existing quad serialization remains byte-stable. The Canvas 2D host presents these text items using a system sans font and clips each run to its bounds. Ubuntu's GLES host presents a bounded grayscale subset through PangoFT2 masks; `platform.Capability::GrayscaleTextFrames` is a discovery flag, while each frame still undergoes unsupported/resource preflight and color glyphs reject the whole frame. macOS presents its admitted bounded grayscale subset through CoreText/CoreGraphics. Windows presents a separate bounded LTR grayscale subset through DirectWrite and D3D11. These renderer paths do not add the public `TextInput` capability on macOS or Windows or promise shared editable-control parity. The single-line macOS field's per-window Japanese composition and the Windows field's private IMM32 input remain experimental and default-off; real Japanese IME qualification for Windows remains open. See [snapshot validation](../scene/snapshot.mbt), [text tests](../scene/snapshot_text_test.mbt), the [Linux text guide](linux-text.md#ubuntu-grayscale-scene-text), the [macOS text-field guide](macos-native.md#experimental-single-line-text-field), the [Windows native guide](windows-native.md), and [the Canvas renderer](../examples/browser/site/canvas-renderer.js).

The complete design also includes paths, images, richer text runs, and logical resource descriptors. IDs and serialized scene ordering must be deterministic for identical input. Image/font resources will use framework IDs plus validated descriptors, never raw GPU handles. Those broader resource and shaping contracts remain pending.

The renderer consumes scene values and reports typed outcomes for invalid resources, allocation failure, surface/device loss, and submission/presentation failure. The headless scene implementation supplies scene contracts; Ubuntu GLES and Windows D3D11 now present quads and their separately bounded grayscale text subsets. A shared software raster path may still be added for deterministic pixels, but pixel equality across native text/render stacks is not a cross-platform contract. Backend recovery and raster performance gates are specified in the platform and release packets.

## Native and unsafe boundary

Native calls are contained in target backend/FFI packages. Every boundary must document ownership, lifetime, nullability, encoding, threading, callback/reentrancy, failure mapping, and cleanup. A callback after logical destruction must be ignored safely and diagnosed. Public core values use framework IDs or copied data; native handles never escape through `App`, `Entity`, `Context`, `Element`, or scene APIs.

Prefer a narrow C ABI when it keeps platform types out of MoonBit package interfaces and simplifies ownership review. A backend cannot be promoted to a supported platform tier while it has undocumented native boundaries, aborts on a recoverable operation failure, or lacks teardown coverage.

## Dependency audit and merge checks

Every dependency addition must identify whether it is runtime, development-only, or platform-native and list its owning package. The executable package-boundary check fails if test tooling reaches a runtime package or an unreviewed third-party MoonBit package enters the runtime graph. Native library inventories are separate per target. Dependency review must also check version pinning, license notices, and the lockfile/toolchain reproducibility policy.

The [package-boundary check](../scripts/check_contracts.py) validates the current graph, including `scene -> primitives`, `element -> core/primitives/layout/scene`, the consumer-only `examples/headless/` package, and the one-way `examples/browser -> examples/browser_app` and `examples/browser_board -> examples/task_board` adapter edges. The task-board package may import only `capability/core/element/layout/platform/primitives/scene` plus standard/core. Checker regressions prevent the portable examples from importing their JS host layers. Current contract, dependency, format, build, and test commands are listed in [README.md](../README.md) and the [browser guide](browser-demo.md).

## Ubuntu native dependency exception

The first Ubuntu backend uses system Wayland/xdg-shell, EGL/GLES, xkbcommon and
libc/pthread behind `ubuntu/`. This narrow native exception and its dependency
inventory, licenses, upgrade sources and failure behavior are documented in
[ubuntu.md](ubuntu.md#native-dependency-inventory-and-exception). No portable
package imports the concrete backend. The executable package audit now permits
`platform -> scene/diagnostics/primitives`; `ubuntu` may depend on
`platform/scene/diagnostics/primitives`, `text`, and the private
`platform/linux_text` raster ABI.
and the native example edges above. It audits aliased imports and whitebox
test imports as well as blackbox test imports. All other runtime dependencies
continue to require a written exception.

The Linux text adapter has a Linux-only PangoFT2/Fontconfig system-library
exception. `text_layout/` remains portable, while `platform/linux_text/` owns
all native calls, copied geometry results, and the private grayscale-mask
raster boundary. The Ubuntu renderer consumes that raster ABI but does not
expose Pango values or handles. Headless measurement remains independent of a
window/backend or display server. The public
`require_grayscale_raster()` admission check verifies the linked private ABI
and Pango >= 1.50 glyph-color metadata at runtime. The executable package
allowlist records the Ubuntu-to-`platform/linux_text` and Ubuntu-to-`text`
edges; this exception does not permit other portable packages to depend on the
adapter. See the [Linux text guide](linux-text.md)
for FFI, build, font-fixture, and dependency/license boundaries.

## Initial native package edges

The first macOS slice adds checked edges `platform -> primitives/diagnostics/scene`,
`platform/macos -> platform/primitives/diagnostics/scene/text`,
`platform/macos_text -> text/text_layout/primitives`,
`examples/native_macos -> platform/macos/platform/primitives/diagnostics/scene`,
and `examples/macos_text_field -> platform/macos/platform/macos_text/controls/text_field/text/text_layout/element/primitives/scene/diagnostics`.
The portable Backend trait includes frame submission in this first slice; a
separate renderer interface is deferred. No reverse edge from core, element,
layout, or scene to a backend is permitted. Native OS dependencies and ABI
ownership are documented in [macos-native.md](macos-native.md).

The Windows packages use checked edges `windows -> platform/, platform/windows_text/, scene/, diagnostics/, primitives/`, `platform/windows_text -> text_layout/, text/, primitives/`, `examples/windows -> windows/, platform/, scene/, diagnostics/, primitives/`, and `examples/windows_text_field -> windows/, platform/windows_text/, controls/text_field/, text/, text_layout/, element/, platform/, scene/, diagnostics/, primitives/`. Win32/D3D11 and DirectWrite calls remain in native leaf adapters. Bounded grayscale scene text and the focused opt-in IMM32 field do not establish a Windows support tier or qualify real Japanese IME behavior. Native dependency and smoke boundaries are documented in [windows-native.md](windows-native.md).

## JavaScript browser example edges

The interaction lab uses `examples/browser_app -> core/diagnostics/element/layout/platform/primitives/scene/capability/mcp` and `examples/browser -> examples/browser_app/diagnostics/platform/primitives`. The first package is host-neutral and compiles on all configured targets; its MCP seam is in-process dispatch through the registry, not MCP wire transport. The second is JavaScript-only.

Weekboard adds `examples/task_board -> capability/core/element/layout/platform/primitives/scene` and `examples/browser_board -> examples/task_board`. Its model owns task operations, history, scroll/drag state, filtering, selection, and logical geometry. The JS leaf exposes only copied values. Canvas rendering and ordinary HTML search/add/detail controls live in the static host. The dynamic visible-card DOM projection consumes the model's layout DTO and returns actions to the model; it does not move layout or task ownership into the DOM or establish a general semantic tree. Both pages share the bounded Canvas renderer. See the [browser guide](browser-demo.md) for implementation, test links, and limits.
