# Ubuntu native backend roadmap

Status: in progress — grayscale drawing implemented; bounded experimental field/direct-keyboard work is active, with unpublished origin-aware local progress; compositor typing, IME, origin GPU proof, and support gates remain open
Parent: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md)
Updated: 2026-10-05

## Current-head acceptance triage — 2026-10-04

Basis: merged main HEAD `1dea499e34a36a64927791c94f35965a91c305a2`; PR #13
head `d70b1255aa5dc1eaaea04a67a9ea748d29317cbd`.

- [x] The Wayland/xdg-shell/EGL/GLES2 first-window path and basic input, focus,
  integer scaling, clipboard, and cursor paths are implemented. The hosted
  [Ubuntu run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649294)
  passed Weston/llvmpipe native E2E at scales 1 and 2, including the serial
  lifetime and optional-service regressions.
- [x] The run collected 30 recovery-to-first-frame samples per scale.
- [ ] Its comparator reports `no_baseline`; this is not a performance pass.
  Clipboard interoperability and visible cursor smoke, fractional scaling and
  public display metadata, Japanese IME/text, accessibility/menus, reconnect,
  sustained resource limits, and real Ubuntu desktop evidence remain open.

Ubuntu/Wayland remains an experimental configuration, not general Linux or
Tier 1 support.

## Goal

Provide a real native gpui.mbt desktop backend for Ubuntu while preserving the
same platform-neutral core and SceneSnapshot contracts used by macOS and
Windows.

Ubuntu is tracked separately from generic "Linux" so the project can define a
repeatable distro/session/toolchain test matrix instead of making an
unverifiable blanket Linux support claim.

## Initial backend boundary

Target a native Linux desktop path with:

- Wayland as the primary window/input protocol
- xdg-shell for toplevel windows
- a native GPU surface/backend selected behind the shared renderer contract
- system clipboard/data-device integration
- native text-input/IME integration
- Linux accessibility bridge appropriate to the supported desktop session

X11/XWayland compatibility is a separate compatibility decision. Do not imply
it from a working Wayland backend.

Do not expose Wayland objects, file descriptors, GPU handles, or desktop-bus
implementation types through core/public application APIs.

## Work packets

### A. Session detection and host loop

Implement:

- backend/session initialization
- display connection ownership
- event-loop wakeup and dispatch
- clean disconnect/error handling
- typed unsupported-session errors

Acceptance:

- a MoonBit executable starts under the supported Ubuntu desktop session
- host wake/request-exit semantics match the common backend contract
- initialization failure leaves no half-live backend state

### B. One native window and GPU surface

Implement:

- xdg toplevel creation/configuration/destruction
- logical size/title updates
- surface creation and resize
- rendering of the supported SceneSnapshot v1 subset
- frame presentation and completion

Acceptance:

- one visible native Ubuntu window renders a deterministic quad scene
- configure/resize sequencing cannot present against stale dimensions
- clean close releases window and surface resources

This is the minimum bar for saying "gpui.mbt runs a native Ubuntu GUI app".

### C. Input, focus, scale, clipboard

Implement:

- pointer
- keyboard
- focus
- cursor
- output/display metadata
- fractional/integer scale behavior required by the supported compositor path
- clipboard/data transfer

Acceptance:

- logical-coordinate input reaches the shared event model in source order
- focus transitions match headless semantics
- scale changes take effect before later input/frame events
- clipboard failures are typed and observable

### D. Text and IME

Integrate the supported Linux text-input/IME path without leaking it into the
public text API.

Acceptance:

- composition start/update/commit/cancel
- caret/candidate positioning contract
- Japanese input smoke under the supported Ubuntu session
- mixed-script/emoji/combining/bidi rendering fixtures

### E. Accessibility

Bridge the internal semantic tree to the accessibility stack chosen for the
supported Ubuntu desktop environment.

Acceptance:

- role/name/value/state/focus/action baseline
- native assistive-technology smoke
- no rendering-only accessibility implementation

### F. Lifecycle stress and recovery

Acceptance:

- repeated window create/destroy
- resize storm
- input storm
- compositor/display reconnect or equivalent recoverable failure behavior where
  the selected stack permits it
- renderer/surface loss recovery
- no unbounded resource growth in sustained tests

### G. Ubuntu CI/support matrix

Before any support claim, pin and document:

- Ubuntu release(s)
- desktop/session type
- compositor used by CI/E2E
- native toolchain/system packages
- GPU/software-render configuration used for evidence

A CI build alone is Tier 0 evidence only. Tier 1 additionally requires native
E2E, Japanese IME, accessibility, DPI/scale, recovery, performance, and
resource-lifetime gates from issue 0005.

## Compatibility decisions that must stay explicit

Track separately:

- Wayland native support
- X11 native support, if later implemented
- XWayland behavior
- desktop-environment-specific differences
- GPU backend differences
- headless CI compositor behavior vs real desktop evidence

Do not label the platform simply "Linux supported" based on one Ubuntu/Wayland
configuration.

## Testing

Required layers:

1. shared backend conformance tests
2. protocol/window lifecycle tests
3. native Ubuntu E2E under a pinned session
4. visual/render smoke
5. Japanese IME smoke
6. accessibility smoke
7. lifecycle/resource stress
8. renderer/surface recovery fault tests

Use vlmkit only as an optional black-box UI oracle. All content supplied to it
must follow the repository's external-AI/data-handling policy.

## Non-goals for the first native slice

The first Ubuntu window does not require:

- X11 parity
- every desktop environment
- every GPU vendor
- full text/accessibility completeness
- Tier 1 status

Those are later compatibility/support gates.

## Implementation update — 2026-10-03

The first native slice is implemented in `platform/`, `ubuntu/` and
`examples/ubuntu/`. Setup, native dependency inventory, exact API limitations,
and evidence are in [docs/ubuntu.md](../../docs/ubuntu.md).

- A: implemented owner-thread session startup, owned connection, bounded dispatch,
  wake, exit, idempotent teardown and typed session/disconnect failures. Shared
  host conformance is exercised by the native tests. Cross-thread enqueue is
  still pending from the parent contract.
- B: implemented one xdg toplevel and EGL/GLES2 surface, title/client size updates,
  v1 quad/affine/opacity/rectangle-clip rendering, stale snapshot rejection and
  compositor frame completion. Local native executable and GPU readback pass.
- C: basic pointer/keyboard/focus and integer output scale implemented; clipboard,
  cursor, fractional scale and public display metadata remain pending.
- D/E: native IME/text shaping and semantic accessibility remain pending. A
  Japanese title smoke is not Japanese IME evidence.
- F: 24 MoonBit and 40 C window cycles per scale, resize bursts, explicit renderer
  recreation, stale generations, FD stability, and terminal compositor disconnect
  checks implemented. Full fault/recovery and sustained GPU memory gates pending.
- G: Ubuntu 24.04 x86-64 / Weston 13 / Mesa llvmpipe CI configured at integer
  scales 1 and 2, with MoonBit 0.10.14+7d59c7ec9. The [hosted Ubuntu run
  37188934281](https://github.com/f4ah6o/gpui.mbt/actions/runs/37188934281)
  passed MoonBit E2E (4/4), C lifecycle, pixel-readback, input-order, scale,
  recovery and resource checks at both scales, and collected 30 timing samples
  per scale. PR head
  `087e54cb9fde48b56ed5d6d50d564b43c42fa803` was tested as synthetic merge
  `871fb17` into `731981259efe3815de06d3420163f3b842e854a0`. The report completed
  with comparison `no_baseline`; this is diagnostic evidence, not a reviewed
  performance baseline or pass. Real GNOME/Mutter, Japanese IME, accessibility
  and production gates remain pending.

Local execution used Debian 13 / Weston 14.0.2; it does not establish Ubuntu
support. No X11/XWayland, Tier 1 or general Linux support claim is made.

## Implementation progress — 2026-10-04

The first slice now also implements Wayland data-device UTF-8 clipboard read
and write, with bounded nonblocking pipe transfer and a real input-serial
requirement for writes, plus arrow/hand/text cursors gated on pointer-enter
focus. Details are in [docs/ubuntu.md](../../docs/ubuntu.md). Helper and
portable tests pass locally; the Weston native E2E could not run in this
environment because the headless compositor failed to create its socket. The
first Ubuntu CI run confirmed Weston 13 starts and the transfer helper
passes, but MoonBit E2E failed on unconditional clipboard/cursor capability
requirements. A subsequent run passed MoonBit E2E 4/4, then exposed the same
assumption in the C harness. Both E2E layers now check typed optional-service
status. The latest run [37188934281](https://github.com/f4ah6o/gpui.mbt/actions/runs/37188934281)
passed native E2E at both scales and produced a complete 30-sample-per-scale
report with `no_baseline`. It tested PR head
`087e54cb9fde48b56ed5d6d50d564b43c42fa803` as synthetic merge `871fb17`; this
single headless run is not a reviewed performance baseline. Local Debian
evidence is not an Ubuntu support claim.

Still open are cross-client clipboard roundtrip and visible cursor smoke,
fractional scaling/public display metadata, Japanese IME/text-input integration,
accessibility, menus, cross-thread enqueue, automatic recovery/reconnect and
sustained resource/performance evidence. X11/XWayland, real Ubuntu desktop
validation, and all Tier 1 gates remain pending.

## Grayscale text-frame implementation — 2026-10-05

PR27's measured-text work is merged as main commit
`d0335f65f6758b5ecaf91353500ad6978f9ae13e`. The Ubuntu host now implements a
bounded renderer slice for existing `SceneSnapshot` v1 `TextItem`s, in their
original order with quads. It reuses the Linux PangoFT2 text-layout/font
decisions, emits grayscale A8 masks at logical resolution, and draws them
through GLES using existing affine/scale geometry and `GL_LINEAR` filtering.
This is scaled-mask presentation rather than device-resolution rasterization;
enlarging text may appear softer. Text bounds are item-local; viewport clip
chains remain viewport-space scissors.

`platform.Capability::GrayscaleTextFrames` discovers this subset only. It is
not an input, focus, caret/selection, editable-control, composition, IME, or
color-glyph capability. Preflight rejects any frame with a color glyph or an
unpaired UTF-16 surrogate as `UnsupportedCapability`. Documented resource
bounds are 256 runs, 16,384 UTF-8 bytes per run, 1 MiB UTF-8 per frame, 512
logical font pixels, 2,048 by 2,048 A8 tiles, 16 MiB aggregate masks, actual
`GL_MAX_TEXTURE_SIZE`, and an additional 1,048,576 limit on
`(Unicode scalar count + 1) * font_size_px`. Aggregate mask budget is checked
before the next allocation. No input is truncated. Invalid/unsupported/
resource-limit failures discovered during preflight preserve the currently
displayed frame; real device/surface loss retains existing typed recovery
semantics. The `SceneSnapshot` envelope version remains v1 and permits
additional item variants.

The local headless C mask consumer passes normally and with ASan+UBSan using
leak detection disabled on Debian 13 / PangoFT2 1.56.3 / Fontconfig 2.15.0
with the declared DejaVu/Noto fixtures. The leak-enabled LeakSanitizer run
reports that it does not work under ptrace in this environment; that is not a
leak pass or a product leak failure. [PR28's Ubuntu run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37346110201) passed the headless
adapter and integrated mixed-scene Weston/llvmpipe checks at 1x/2x, including
late invalid/color/resource rejection with unchanged prior pixels and retained
Latin/Japanese clipping/overlap readbacks. PR28 merged as
`3cc72f548dc6138e17f949efad8eae92c70a1cb0`, reviewed tree
`14b8ce67796bcb08e08b60d8fcdb495afb7257b4`. Local GPU tests remain unrun because
AF_UNIX stream-socket creation returns `EPERM`. This bounded correctness proof
is not a desktop, IME, text-performance or production-support qualification. Ubuntu checks `require_grayscale_raster()` to admit the
linked ABI and Pango >= 1.50 before discovering the capability. The
experimental field uses the same generic `sans` family, font size, and Pango
context as drawing for caret/hit geometry; arbitrary-family measurement does
not guarantee parity. Use [the Linux text guide](../../docs/linux-text.md#ubuntu-grayscale-scene-text)
and [Ubuntu guide](../../docs/ubuntu.md#grayscale-text-frame-subset) for the
complete implementation boundary.

## Experimental bounded field/direct-text slice — 2026-10-05

The field prototype based on merged focused-input PR29
(`18e8fadf470823b389feff3b9d496213b4d3f67a`, tree
`7554a5f181724160e1be4a11ac0e47067ca79e3d`) adds a bounded, single-line LTR
field example, portable edit snapshots, visible caret/selection, same-context
Pango measurement and grayscale admission, guarded reuse of the Ubuntu
clipboard path, and an owner-armed private XKB/locale-Compose committed-text
target. This remains an experimental implementation, not a generally
usable control or a capability advertised by `GrayscaleTextFrames`.

Native direct input requires a live seat, usable keymap and Compose table, and
current native keyboard focus. Its copied v2 ABI carries key and committed-text
epochs; stale direct input is dropped, v1 reads refuse active/queued direct
records, and epoch exhaustion fails closed until a fresh host. Blur, keymap or
seat changes, re-arm, window release, and stop reset Compose and revoke the
logical target. The public `TextInput`/IME route, Japanese IME, composition UI,
and candidate positioning are still unsupported.

Origin-aware local progress is based on reviewed PR #30 tree `5ac17e9` and is
not published as a source commit. The scene remains a v1 envelope: legacy
`TextItem` meaning and JSON are unchanged; new plain `TextRunItem` JSON uses
`kind: "text_run"`, a separate `text_origin`, and exact local clip bounds
applied before the transform. Consumers must reject unknown variants and
public exhaustive matches must handle the new variant. Ubuntu mixed-frame
ABI3 keeps ABI2's 23-field prefix and appends origin x/y for a 25-double record;
kind 2 denotes the run and quad/legacy-text tags require zero origins. Linux
raster ABI v2 returns UV crop data alongside the unchanged v1 mask struct and
entry semantics.

The field computes one shared logical/ink union with in-line carets, rounds minima down and
maxima up to whole logical pixels to include Pango pixel coverage, and uses
that mapping for admission, caret/selection paint, hit testing, and scroll.
Actual-font headless field and full negative-mask tests pass, including
negative-bearing text, composed/decomposed accents, and scroll. This closes the
old negative-bearing rejection for the bounded local slice; it does not qualify
GPU presentation. The field is still single-line LTR; unknown glyphs, color
glyphs, and reflow/resource-limit cases reject the edit. Masks remain at logical
resolution and may soften when scaled. No IME, autorepeat, general bidi, drag,
undo, or actual compositor-delivered typing is qualified.

PR #30 remains draft after pre-start runner cancellation. Its Windows, macOS,
documentation, and headless Pango jobs passed; GPU, core, browser, and mutation
jobs are not qualified. A bounded retry of an Ubuntu failed job was again
cancelled before runner start; no source or billing cause is established. New
encoder/GPU acceptance cases compile and hosted execution remains
pending. No GPU execution or publication is claimed. Control-to-renderer
fixtures are injected and do not show compositor keyboard delivery. Actual
compositor-delivered typing is **unrun**: the stock Weston 13 headless setup
lacks an admitted input injection driver for this qualification, and local
AF_UNIX socket creation returns `EPERM`. Packet D's Japanese IME/text-input
acceptance remains open, along with actual desktop typing, accessibility,
recovery/reconnect, performance, resources, and all Ubuntu support gates. Do not
treat this work as a support-tier change. See the [experimental field guide](../../docs/linux-text-field.md).

Remaining packet D work is to qualify actual compositor-driven delivery through
the direct-text target and implement a real text-input/IME path with
composition start/update/commit/cancel, candidate/caret positioning, and
Japanese IME qualification. The current XKB/Compose route does not satisfy
those IME acceptance criteria. Also open are compositor/GPU qualification,
logical-resolution/scaled-mask quality, semantic accessibility, reusable
field/picker behavior, and the backend recovery/resource/support gates. Text
drawing or the local field prototype alone does not complete packet D.
