# Codebase gap snapshot and foundation-first development

Observed 2026-10-05; gpui.mbt boundaries refreshed 2026-10-06 against merged PR30/PR31 main `73e7082` and the current bounded undo/redo change. Other project pins remain historical audit facts and were not rechecked in this refresh. This is a source-grounded prioritization record, not a claim of runtime compatibility or production readiness.

## Development decision

Use lightweight foundation development as the primary loop: inspect source requirements, implement a bounded portable contract, run focused tests/PBT/mutation and small host fixtures, then revisit MZed at integration milestones. Do not run the full editor build for each foundational or harness adjustment. MZed remains an application-level proof and a way to discover remaining integration friction, not the prerequisite for every implementation step.

The existing same-window proof is retained: [MZed PR3](https://github.com/gpui-mbt/MZed/pull/3) merged as `59a4a2b6daa48967c79de114a9de2ed119115c7b`; [main Linux evidence](https://github.com/gpui-mbt/MZed/actions/runs/37273659532) demonstrates the bounded 1x/2x mouse interaction, teardown/remount and original editor save. This does not satisfy all issue0019 gates, native text/IME/accessibility, all platforms, or the release ledger. Further fault-probe work is paused while foundation gaps are addressed.

## Source pins and evidence categories

Earlier gpui.mbt pins below are historical checkpoints. The current accepted
field/origin baseline is main `73e70822841024a7131c54fb4529cd40186d529c`, tree
`108cf4e9ebb0055477b649e2008520c5efe1ee7b`, after merged PR30/PR31. Bounded
undo/redo in the current change has local coverage; its new hosted GPU cases
are pending. Zed and supporting-tool pins describe the earlier source audit,
not newly verified current main states.

- gpui.mbt main before the composition slice: `d3c142ef9ac2b856277059e41526f32e5845447a` (the portable UTF-16 text foundation; composition was not yet in this historical audited base).
- gpui.mbt main after PR25 composition merge: `231400425d06f6be157f84ff27bb53134fa18ef3` (historical composition checkpoint).
- gpui.mbt main after PR26 strict UTF-16/UTF-8 offset-bridge merge: `7335e13abe85c65d2a0f60571adc68faa8e64cdd` (the PR27 measured-text base).
- gpui.mbt main after merged PR27 measured-text work: `d0335f65f6758b5ecaf91353500ad6978f9ae13e`, tree `ae19ca012ac03cf3b4fed6c93f442d8a04f9fd8c`.
- gpui.mbt main after merged PR28 grayscale drawing: `3cc72f548dc6138e17f949efad8eae92c70a1cb0`, tree `14b8ce67796bcb08e08b60d8fcdb495afb7257b4` (the focused-routing base).
- Zed application reference: `76659a55a8c10ed355a070f8764a0b1733e3c115` (v1.22.0). This is separate from the framework's existing upstream comparison pin.
- Turtles main: `4d9baaa258c695e803a487283076e979e2c260ba`.
- Hotpath main: `be4cb98a3eb61bd5ab176c9e5e6bd921b74d1dce`.
- VLMKit main: `f8196f8143c7d8b32b03af713d6ef7e4d5e2aea0`.

Distinguish source capability present, partial contract, missing implementation, unadopted tool capability, and runtime evidence not yet established. A missing live test is not automatically a missing API; an API name or successful compilation is not proof of host behavior.

## Core gaps and dependency order

| Area | Verified current boundary | Foundation work | Later runtime gate |
| --- | --- | --- | --- |
| Text editing semantics | Portable UTF-16 document/selection, composition and strict UTF-8 offset conversion exist. Merged PR30/PR31 add a bounded Linux single-line LTR field with directional selection, cursor-stop navigation, clipboard guards and owner freshness/rollback. The current change adds bounded immutable undo/redo with local model/provider coverage; new hosted history cases are pending. | General editable-control/composition ownership, typing coalescing and broader editor history, then multi-cursor and reusable control integration. | Actual compositor-delivered typing, Japanese IME/candidate placement, new undo/redo GPU qualification, accessibility and production gates. |
| Text measurement/rendering | Copied measurement/caret/hit values and Linux PangoFT2 exist. Merged PR30/PR31 paint field text/caret/selection/scroll with a shared origin-aware logical/ink union; declared Weston/llvmpipe injection checks passed at 1x/2x. Logical-resolution grayscale masks remain bounded; unknown/color glyphs reject. | Broader font/scale and renderer qualification, reusable controls, rich text and supported color-glyph behavior. | Native/browser editor behavior, font/scale workloads, accessibility and production gates; injected drawing is not typing evidence. |
| Input and focus | ElementTree routes pointer and focused key/text events with private copy-safe validated backing arrays. Ubuntu has an opt-in private direct XKB/locale-Compose committed-text ingress with focus/epoch/stale-record guards; it does not advertise public TextInput/IME. Browser committed-text services are separate from a full editor model. | Public native text-input protocol/IME integration, explicit composition ownership and reusable editable-control sequencing. | Actual compositor-delivered field typing, Japanese IME, input-capable desktop focus transitions/lost pairs and accessibility input behavior. |
| Lists and reusable controls | Flex layout and element lifecycle exist, plus the experimental bounded Linux field. General reusable editor-facing controls and virtualization are incomplete. | Build picker/list and broader text-field behavior from tested primitives, with bounded visible-range work. | Real large-tree/scroll performance and semantic accessibility. |
| Host services and asynchronous work | Native clipboard/cursor adapters exist on macOS, Ubuntu and Windows, and portable host-service envelopes exist; native desktop dialog/filesystem adapters and complete async endpoint topology do not. | Reuse the existing clipboard/cursor adapters through controls; add dialog/filesystem/execution behavior only for a concrete consumer. Keep parked issue 0016 work distinct from accepted main. | Cross-client permission behavior, native file/dialog flow, lifetime/cancel races and complete host integration. |

The portable UTF-16 model, immutable composition, strict scalar-boundary offset
bridge and copied Pango measurement/caret/hit values remain the foundations.
Merged PR29 focused routing and PR30/PR31 field/origin work now connect those
foundations in a bounded Ubuntu control: native direct committed-text ingress,
visible caret/directional selection, cursor-stop navigation, clipboard guards,
scroll and origin-aware grayscale drawing use matching `sans` family, font size
and Pango context. The current change adds one group per content edit, bounded
immutable history and current-style re-admission on undo/redo; clipboard and
presentation transactions retain or roll back matching history. Those local
history checks do not yet qualify the new hosted GPU cases.

This is not a general editor. Actual compositor-delivered typing into the field
and Japanese IME remain unrun. The direct XKB/locale-Compose path is distinct
from a public native TextInput/IME protocol. General bidi, rich text, color-glyph
output, multi-cursor, drag/word selection, typing coalescing and semantic
accessibility remain missing or unqualified at their respective layers. See the
[field guide](linux-text-field.md) for the bounded implemented behavior and the
[Linux text guide](linux-text.md#ubuntu-grayscale-scene-text) for frame limits.

On Debian 13 / PangoFT2 1.56.3 / Fontconfig 2.15.0 with the declared DejaVu/Noto fixtures, the headless C mask consumer passes normally and with ASan+UBSan when leak detection is disabled. The leak-enabled LeakSanitizer run reports that it does not work under ptrace in this environment; this is neither a leak pass nor a product leak failure. [PR28's Ubuntu run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37346110201) passed real Weston/llvmpipe mixed-scene checks at 1x/2x, including late invalid/color/resource preservation and retained Latin/Japanese clipping/overlap readbacks. PR28 merged as `3cc72f548dc6138e17f949efad8eae92c70a1cb0`, tree `14b8ce67796bcb08e08b60d8fcdb495afb7257b4`. Local GPU tests remain unrun because AF_UNIX stream-socket creation returns `EPERM`. This bounded software-rendered acceptance does not establish a platform support tier or text-performance qualification. Measurement/caret/hit values are still copied snapshots without session IDs or freshness guarantees; hosts must own sequencing and reject stale or cross-owner events.

Merged [PR30](https://github.com/gpui-mbt/gpui.mbt/pull/30) and
[PR31](https://github.com/gpui-mbt/gpui.mbt/pull/31) extend that baseline with
actual `Host.present` and injected field text/caret/selection/scroll/overhang
checks at 1x/2x in [PR31's Ubuntu run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37392223946).
They establish control-to-renderer acceptance, not compositor keyboard delivery
or IME. The [known hosted-compositor observation](ubuntu.md#known-hosted-compositor-observation)
retains a first-attempt Weston exit139 on merged main and a successful retry on
the unchanged SHA; its cause remains unknown.

Next, qualify this change's hosted undo/redo rendering and the field's actual
compositor-delivered typing, then define native IME composition/commit/cancel
and focus-loss ownership and qualify Japanese IME. Use the bounded field in a
picker/command palette and scalable collections when a concrete consumer is
ready, checking bounded work and keyboard navigation. Neither direct ingress
nor drawing completes public IME, accessibility, general editor history,
multi-cursor or production gates. Return to MZed when a real component can
migrate, not for each lower-level foundation increment. See
[issue 0004](../issues/open/0004-platform-rendering-and-native-boundaries.md) and
[issue 0007](../issues/open/0007-ubuntu-native-backend.md) for implementation scope
and validation boundaries.

## Why text is a shared dependency

The requirements and source links in this section come from the historical
pinned audit; they are not a fresh audit of upstream Zed or browser main.

Zed's command palette uses a Picker backed by a single-line Editor through a registered erased-editor factory. Its platform input contract uses UTF-16 selected, marked and replacement ranges, while internal buffer offsets are distinct types. Its project tree uses a virtualized visible-row list and text-bearing rows, with an editor for inline rename. These provide concrete requirements, but their whole dependency graphs are not the required implementation unit.

- [GPUI main input values](https://github.com/gpui-mbt/gpui.mbt/blob/01dff466d4c8025f578cb2d11fa7658c6f811088/primitives/input.mbt#L89-L107)
- [Browser bridge explicitly excludes a document/selection/full-IME model](https://github.com/gpui-mbt/gpui.mbt/blob/01dff466d4c8025f578cb2d11fa7658c6f811088/examples/browser/site/text-input.js#L1-L3)
- [Zed UTF-16 platform input interface](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/gpui/src/platform.rs#L1923-L2015)
- [Picker editor factory](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/picker/src/head.rs#L16-L45)
- [Project-panel virtualized rendering](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/project_panel/src/project_panel.rs#L7301-L7525)
- [Platform text measurement contract](https://github.com/zed-industries/zed/blob/76659a55a8c10ed355a070f8764a0b1733e3c115/crates/gpui/src/platform.rs#L1176-L1212)

## Supporting tools: adopt, qualify, then extend

This table preserves the historical pinned tool audit. No supporting-tool main
state or source pin was rechecked by the field/history documentation refresh.

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
