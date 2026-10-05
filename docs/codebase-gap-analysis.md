# Codebase gap snapshot and foundation-first development

Observed 2026-10-05, refreshed after merged PR27 and the Ubuntu grayscale text-frame implementation. This is a source-grounded prioritization record, not a claim of runtime compatibility or production readiness.

## Development decision

Use lightweight foundation development as the primary loop: inspect source requirements, implement a bounded portable contract, run focused tests/PBT/mutation and small host fixtures, then revisit MZed at integration milestones. Do not run the full editor build for each foundational or harness adjustment. MZed remains an application-level proof and a way to discover remaining integration friction, not the prerequisite for every implementation step.

The existing same-window proof is retained: [MZed PR3](https://github.com/gpui-mbt/MZed/pull/3) merged as `59a4a2b6daa48967c79de114a9de2ed119115c7b`; [main Linux evidence](https://github.com/gpui-mbt/MZed/actions/runs/37273659532) demonstrates the bounded 1x/2x mouse interaction, teardown/remount and original editor save. This does not satisfy all issue0019 gates, native text/IME/accessibility, all platforms, or the release ledger. Further fault-probe work is paused while foundation gaps are addressed.

## Source pins and evidence categories

- gpui.mbt main before the composition slice: `d3c142ef9ac2b856277059e41526f32e5845447a` (the portable UTF-16 text foundation; composition was not yet in this historical audited base).
- gpui.mbt main after PR25 composition merge: `231400425d06f6be157f84ff27bb53134fa18ef3` (historical composition checkpoint).
- gpui.mbt main after PR26 strict UTF-16/UTF-8 offset-bridge merge: `7335e13abe85c65d2a0f60571adc68faa8e64cdd` (the PR27 measured-text base).
- gpui.mbt main after merged PR27 measured-text work: `d0335f65f6758b5ecaf91353500ad6978f9ae13e`, tree `ae19ca012ac03cf3b4fed6c93f442d8a04f9fd8c`.
- Zed application reference: `76659a55a8c10ed355a070f8764a0b1733e3c115` (v1.22.0). This is separate from the framework's existing upstream comparison pin.
- Turtles main: `4d9baaa258c695e803a487283076e979e2c260ba`.
- Hotpath main: `be4cb98a3eb61bd5ab176c9e5e6bd921b74d1dce`.
- VLMKit main: `f8196f8143c7d8b32b03af713d6ef7e4d5e2aea0`.

Distinguish source capability present, partial contract, missing implementation, unadopted tool capability, and runtime evidence not yet established. A missing live test is not automatically a missing API; an API name or successful compilation is not proof of host behavior.

## Core gaps and dependency order

| Area | Verified current boundary | Foundation work | Later runtime gate |
| --- | --- | --- | --- |
| Text editing semantics | Historical PR25 added immutable composition to the UTF-16 document/selection model; PR26 merged strict UTF-16/UTF-8 scalar-boundary conversion at `7335e13`. No host input owner or widget is part of this model. | Host-owned sequencing/freshness and history semantics, then a focused input adapter with explicit offset-to-geometry mapping. | Actual native/browser IME behavior, Japanese IME, candidate placement, undo, multi-cursor, accessibility and production gates. |
| Text measurement/rendering | PR27 is merged as `d0335f6`: the portable copied measurement/caret/hit contract and Linux PangoFT2 adapter exist. The current Ubuntu slice draws the supported SceneSnapshot v1 subset through logical-resolution grayscale A8 masks. Per-frame unsupported/resource checks remain; color glyphs reject a frame. | Build a Linux input control on matching `sans` family/font-size/context measurement, then caret/selection policy and broader renderer qualification. | Native/browser editor behavior, Japanese IME, accessibility, font/scale workload evidence and production gates. |
| Input and focus | ElementTree routes pointer events and stores focused IDs; native backends expose character keys, not full TextInput capability. | Focused key/text dispatch, explicit composition ownership, cancellation and stale-input rules. | Native focus transitions, lost input pairs, IME and accessibility input behavior. |
| Lists and reusable controls | Flex layout and element lifecycle exist; editor-facing virtualization and editable control contracts are not complete. | Build list/picker/text-field behavior from tested primitives, with bounded visible-range work. | Real large-tree/scroll performance and semantic accessibility. |
| Host services and asynchronous work | Native clipboard/cursor adapters exist on macOS, Ubuntu and Windows, and portable host-service envelopes exist; native desktop dialog/filesystem adapters and complete async endpoint topology do not. | Reuse the existing clipboard/cursor adapters through controls; add dialog/filesystem/execution behavior only for a concrete consumer. Keep parked issue 0016 work distinct from accepted main. | Cross-client permission behavior, native file/dialog flow, lifetime/cancel races and complete host integration. |

The first bounded implementation is the portable UTF-16 range, selection, and immutable document model. PR25 merged composition at `231400425d06f6be157f84ff27bb53134fa18ef3`; `TextComposition` previews replace the original target range, rebase relative directional selections, commit caller-supplied final text, and cancel to the original selection. PR26 merged the strict scalar-boundary UTF-16/UTF-8 bridge at `7335e13abe85c65d2a0f60571adc68faa8e64cdd`. PR27 then merged copied measurement/caret/hit values over that existing bridge plus a Linux PangoFT2 implementation at main commit `d0335f65f6758b5ecaf91353500ad6978f9ae13e`. The current Ubuntu implementation adds ordered grayscale mask drawing for supported text items without changing the public SceneSnapshot schema. It uses the generic `sans` family and item font size; caret/hit geometry in a future control must use the same family, size, and Pango context, while arbitrary-family measurement does not imply rendering parity. It does not provide a text field, key/text dispatch, visible caret or selection, grapheme navigation, host IME input, undo history, rich text, or color-glyph output. Frame limits and validation are recorded in [the Linux text guide](linux-text.md#ubuntu-grayscale-scene-text).

On Debian 13 / PangoFT2 1.56.3 / Fontconfig 2.15.0 with the declared DejaVu/Noto fixtures, the headless C mask consumer passes normally and with ASan+UBSan when leak detection is disabled. The leak-enabled LeakSanitizer run reports that it does not work under ptrace in this environment; this is neither a leak pass nor a product leak failure. Integrated Weston/GLES text-frame verification is not yet established: local AF_UNIX stream-socket creation returns `EPERM` before compositor testing, and hosted renderer CI is pending. No frame-level GPU acceptance or platform support tier is claimed. Measurement/caret/hit values are still copied snapshots without session IDs or freshness guarantees; hosts must own sequencing and reject stale or cross-owner events.

Next, build a usable Linux text field that connects focused key/text dispatch to the portable model and merged measurement/drawing foundations; expose caret and selection geometry, reuse clipboard services, define composition/commit/cancel and focus-loss ownership, and qualify real Japanese IME. Then use that control in a picker/command palette and scalable collections, checking bounded work and keyboard navigation. Native text drawing does not complete input, IME, accessibility, undo, multi-cursor, or production gates. Return to MZed when a real component can migrate, not for each lower-level foundation increment. See [issue 0004](../issues/open/0004-platform-rendering-and-native-boundaries.md) and [issue 0007](../issues/open/0007-ubuntu-native-backend.md) for implementation scope and validation boundaries.

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
