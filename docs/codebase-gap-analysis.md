# Codebase gap snapshot and foundation-first development

Observed 2026-10-05. This is a source-grounded prioritization record, not a claim of runtime compatibility or production readiness.

## Development decision

Use lightweight foundation development as the primary loop: inspect source requirements, implement a bounded portable contract, run focused tests/PBT/mutation and small host fixtures, then revisit MZed at integration milestones. Do not run the full editor build for each foundational or harness adjustment. MZed remains an application-level proof and a way to discover remaining integration friction, not the prerequisite for every implementation step.

The existing same-window proof is retained: [MZed PR3](https://github.com/gpui-mbt/MZed/pull/3) merged as `59a4a2b6daa48967c79de114a9de2ed119115c7b`; [main Linux evidence](https://github.com/gpui-mbt/MZed/actions/runs/37273659532) demonstrates the bounded 1x/2x mouse interaction, teardown/remount and original editor save. This does not satisfy all issue0019 gates, native text/IME/accessibility, all platforms, or the release ledger. Further fault-probe work is paused while foundation gaps are addressed.

## Source pins and evidence categories

- gpui.mbt main before this composition slice: `d3c142ef9ac2b856277059e41526f32e5845447a` (portable text foundation merged; composition not yet in this audited base).
- Zed application reference: `76659a55a8c10ed355a070f8764a0b1733e3c115` (v1.22.0). This is separate from the framework's existing upstream comparison pin.
- Turtles main: `4d9baaa258c695e803a487283076e979e2c260ba`.
- Hotpath main: `be4cb98a3eb61bd5ab176c9e5e6bd921b74d1dce`.
- VLMKit main: `f8196f8143c7d8b32b03af713d6ef7e4d5e2aea0`.

Distinguish source capability present, partial contract, missing implementation, unadopted tool capability, and runtime evidence not yet established. A missing live test is not automatically a missing API; an API name or successful compilation is not proof of host behavior.

## Core gaps and dependency order

| Area | Verified current boundary | Foundation work | Later runtime gate |
| --- | --- | --- | --- |
| Text editing semantics | At audited main base `d3c142e`, the portable `text/` package has validated UTF-16 ranges, directional selections and immutable documents, but no composition value yet. | This worktree proposes pure composition/commit/cancel values with original-range preview replacement and relative-selection rebasing; then host-owned sequencing/freshness and history semantics, text layout/offset geometry and a focused input adapter. | Actual native/browser IME behavior, Japanese IME, candidate placement, rendering, undo, multi-cursor, accessibility and production gates. |
| Text measurement/rendering | At audited base `d3c142e`, the main scene was quad-only; merged PR23 now adds bounded plain-text snapshot items and browser Canvas system-font presentation, but no portable shaping or native text rendering. | Measured runs, offset-to-geometry contract, shaping/font-fallback adapters, wrapping/caret/selection mapping. Build on the bounded snapshot data without duplicating PR23. | Font/script/scale-specific metrics, clipping, raster output and hit testing on each admitted host. |
| Input and focus | ElementTree routes pointer events and stores focused IDs; native backends expose character keys, not full TextInput capability. | Focused key/text dispatch, explicit composition ownership, cancellation and stale-input rules. | Native focus transitions, lost input pairs, IME and accessibility input behavior. |
| Lists and reusable controls | Flex layout and element lifecycle exist; editor-facing virtualization and editable control contracts are not complete. | Build list/picker/text-field behavior from tested primitives, with bounded visible-range work. | Real large-tree/scroll performance and semantic accessibility. |
| Host services and asynchronous work | Portable host-service envelopes exist; real native adapters and complete asynchronous endpoint topology do not. | Add only adapters/execution semantics required by a concrete consumer. Keep parked0016 work distinct from accepted main. | Actual file-dialog/clipboard/permission behavior, lifetime/cancel races and real host integration. |

The first bounded implementation is the portable UTF-16 range, selection, and immutable document model. The proposed second slice adds `TextComposition`: previews always replace the original target range, relative directional selections rebase to absolute document offsets, commit applies caller-supplied final text, and cancel restores the original selection. Values are snapshots with no session IDs or freshness guarantees; hosts must own sequencing and reject stale or cross-owner events. Neither slice provides shaping, grapheme navigation, a widget, host IME input, undo history, or platform-specific clipping. Strict checked ranges remain a foundation contract, not a claim of Zed source compatibility. Composition notes in this snapshot describe the unmerged worktree and do not change the pinned audited base above.

Next, add measured text and geometry, then a focused input/native adapter, followed by an actual reusable input/picker control. Keep host event sequencing, Japanese IME, candidate-window placement, rendering, undo, multi-cursor, accessibility, and production gates explicit. Return to MZed when a consumer can exercise meaningful new behavior, not just when another low-level test is added.

## Why text is a shared dependency

Zed's command palette uses a Picker backed by a single-line Editor through a registered erased-editor factory. Its platform input contract uses UTF-16 selected, marked and replacement ranges, while internal buffer offsets are distinct types. Its project tree uses a virtualized visible-row list and text-bearing rows, with an editor for inline rename. These provide concrete requirements, but their whole dependency graphs are not the required implementation unit.

- [GPUI main input values](https://github.com/gpui-mbt/gpui.mbt/blob/01dff466d4c8025f578cb2d11fa7658c6f811088/primitives/input.mbt#L89-L107)
- [Browser bridge explicitly excludes a document/selection/full-IME model](https://github.com/gpui-mbt/gpui.mbt/blob/01dff466d4c8025f578cb2d11fa7658c6f811088/examples/browser/site/text-input.js#L1-L3)
- [Zed UTF-16 platform input interface](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/gpui/src/platform.rs#L1923-L2015)
- [Picker editor factory](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/picker/src/head.rs#L16-L45)
- [Project-panel virtualized rendering](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/project_panel/src/project_panel.rs#L7301-L7525)
- [Platform text measurement contract](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/gpui/src/platform.rs#L1176-L1212)

## Supporting tools: adopt, qualify, then extend

| Tool | Present capability | Concrete gap / next use |
| --- | --- | --- |
| Turtles | Main implements target-aware active-source planning and schema3 reports. | GPUI still adopts the registry0.3.0/schema2 contract. Verify package-vs-main parity and migrate target/schema/baseline provenance deliberately. Add focused coverage for new text logic; do not redesign mutation discovery first. |
| Hotpath | Explicit timing, deterministic aggregation and bounded percentile estimates are available. | Adopt for named workloads when measurements are useful. GPUI's existing raw-nanosecond frame harness remains valid; higher-resolution clocks/exporters/automatic instrumentation are separate tool extensions, not prerequisites to the text model. |
| VLMKit | Main includes bounded Linux composited-X11/GTK observation and macOS observation. | Real GPUI semantics and safe native input are not qualified. macOS action PR2 remains draft/diverged, with global pointer and PID keyboard routing rather than proven selected-window recipients. Linux physical input is unimplemented. Keep these as adapter/safety/runtime gates. |
| Yami-kumo | PR3 records the shared-UX design and roles. | Generator/native adapters/conformance are future work. Reuse the plan for expected focus/modal/selection behavior, not as proof those components already exist. |

- [Turtles target plan](https://github.com/gpui-mbt/turtles.mbt/blob/4d9baaa258c695e803a487283076e979e2c260ba/cmd/turtles/plan.mbt)
- [GPUI schema2 adoption checker](https://github.com/gpui-mbt/gpui.mbt/blob/01dff466d4c8025f578cb2d11fa7658c6f811088/scripts/check_turtles_report.py#L42-L52)
- [Hotpath API](https://github.com/gpui-mbt/hotpath.mbt/blob/be4cb98a3eb61bd5ab176c9e5e6bd921b74d1dce/README.md)
- [Linux VLMKit admitted scope](https://github.com/f4ah6o/vlmkit/blob/f8196f8143c7d8b32b03af713d6ef7e4d5e2aea0/native/linux/README.md)
- [Yami-kumo design PR3](https://github.com/f4ah6o/Yami-kumo/pull/3)

## Existing planning and qualification boundaries

Reuse issues0001/0004/0005 for framework text/native/release requirements, issue0003 for validation, native platform children0006–0008 and browser0009 for host-specific evidence, and0011 for host-service integration. Existing0018/0019 remain the application roadmap/proof references. This snapshot changes implementation order, not the release acceptance standard.

All new portable framework code must be independently authored. Do not copy GPL Zed editor/application implementation or test fixtures into the framework under an Apache label. Upstream Zed stays strictly read-only. Linux is the current execution priority; Mac GUI verification is on hold. The eventual Mac/Linux/Windows goal remains, with new Windows work deferred as instructed.
