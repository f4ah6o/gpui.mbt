# Experimental Linux single-line text field

Status: experimental framework slice on Ubuntu/Wayland; not a general
usable text-field API, an input-method implementation, or an Ubuntu support
claim. The experimental field implementation builds on merged focused-input
PR #29 (`18e8fadf470823b389feff3b9d496213b4d3f67a`, reviewed base tree
`7554a5f181724160e1be4a11ac0e47067ca79e3d`). Field-specific hosted
qualification is pending review. The renderer base is
PR #28 (`3cc72f548dc6138e17f949efad8eae92c70a1cb0`); its existing evidence is
not field-input evidence.

This is a deliberately narrow, opt-in demonstration of a bounded single-line,
left-to-right (LTR) entry field joining copied text geometry, portable editing
state, Ubuntu grayscale drawing, focused dispatch, and a private native direct
keyboard-text route. It does not establish ordinary application readiness.

## What the slice does

- `controls/text_field/` supplies immutable document, selection, focus, scroll,
  and revision snapshots. `examples/linux_text_field/` owns its native target,
  connects it to the focused element dispatcher, and submits copied scene
  snapshots. Native measurement, hit testing, and grayscale admission remain in
  the Linux adapter.
- The owner must arm `DirectKeyboardText` while the window is the current native
  keyboard-focus target before it accepts logical field focus. This is a
  private direct XKB/locale-Compose path for key presses/releases and committed
  text. The field consumes `TextInput` for insertion; a `Character` key label
  is never treated as typed text. `DirectKeyboardText` is a separate opt-in
  capability. It does not advertise the public `TextInput`/IME capability, a
  Wayland text-input protocol, candidate-window positioning, or Japanese IME.
- Editing supports text commits, cursor-stop Left/Right, Home/End, Backspace,
  Delete, Shift-extended selection, click-to-place, and horizontal scrolling.
  Unshifted Left/Right collapses a nonempty selection to its matching edge
  without an extra move; Shift keeps the original anchor. Movement and adjacent
  deletion use Pango-provided cursor stops, not scalar or UTF-16 increments.
  The snapshot retains the complete logical selection; one full measured text
  run supplies the caret geometry. The selection spans the full logical-line
  rectangle behind text, and the per-run active caret is painted above it.
  Unequal in-line fallback-font caret y/height values are accepted, while the
  selected logical-line rectangle remains shared across that run.
- The field viewport clips selection, text, and caret locally. Horizontal
  scrolling keeps the active caret in view. This does not add general scroll
  widgets, drag-selection, word navigation, undo, bidi editing, or wrapping.
- The existing Ubuntu clipboard API is reused. Copy writes the selected text;
  cut prepares and raster-admits the edit first, writes clipboard data, and
  installs the candidate only after a successful write. Paste uses the
  existing bounded synchronous clipboard read and strict UTF-8 decoding. The
  owner captures the field revision and direct-text epoch before the read and
  rechecks focus, revision, and epoch after any event pumping before admission.
  A stale or invalid paste is discarded whole.

## Bounds and intentional overhang rejection

The current field limits document text to 4,096 UTF-8 bytes, font size to 32
logical pixels, and measured logical/ink geometry to 2,048 by 128 pixels. It
requires exactly one line, no unknown glyphs, valid monotonic strong caret
positions with matching strong/weak geometry, and a single LTR caret order.
Committed/pasted U+0000–U+001F, U+007F–U+009F, U+2028, and U+2029 are forbidden;
other text is neither normalized nor truncated. Unsupported layout is rejected
as a whole edit. The owner supplies trusted measure, admit, and hit-test
callbacks using the same `sans` family, font size, and Pango context as the
renderer. The field validates returned document identity, geometry, line and
cursor-stop invariants; click handling also checks the hit result's document
identity and resolved cursor-stop status against the stored measurement before
changing selection. See the exact validation in
[`controls/text_field/model.mbt`](../controls/text_field/model.mbt).

The example deliberately measures and paints with the same generic `sans`
family, 18 px size, and PangoFT2 context. That is necessary for matching the
current renderer's caret/hit geometry. Real installed sans fixtures have
negative left/above ink bearings for `j`/`J` and accent cases. Since this first
slice anchors a text mask at the logical origin, accepting those layouts could
crop ink. The current fail-closed policy rejects the whole edit and retains the
prior field/revision/frame. An origin-aware presentation/measurement follow-on that can preserve negative
bearings is a separate design pending review; this slice does not claim those
inputs work. The real-font rejection and geometry cases are in
[`examples/linux_text_field/controller_wbtest.mbt`](../examples/linux_text_field/controller_wbtest.mbt)
and provider admission tests in
[`platform/linux_text/field_admission_wbtest.mbt`](../platform/linux_text/field_admission_wbtest.mbt).

## Native focus, event generations, and ABI

Direct input is admitted only with a live seat, usable XKB keymap, locale
Compose table, and current native keyboard focus on the requested window.
Direct target re-arm advances a positive, nonwrapping int32 epoch even when
re-armed to the same enabled state. Every direct-origin editor key press, key
release, and committed-text record carries its originating epoch. An ordinary
unconsumed press is delivered before its optional text commit; insertion never
occurs on release. A physical release keeps the epoch of its press; swallowed
Compose releases remain swallowed across same-keyboard target/focus resets
instead of leaking as a release into another field. Compose
prefix/completion/cancel presses are consumed before field commands; a
completed sequence emits one commit. Modifier and Control/Meta shortcut keys
remain key events; Control/Meta commands reset pending Compose and do not also
commit text. Ordinary key-plus-optional-commit queue admission is atomic.
Arbitrary layout-shortcut parity and native key-repeat timing are not promised.

Keyboard blur, keymap replacement, keyboard/seat loss, target re-arm, window
release, and host stop reset pending Compose and invalidate the current
logical epoch. Fatal native display/dispatch/pump failure also transitions the host
out of `Running` and revokes direct input once, retaining the concrete typed
failure. This is idempotent; presentation `Busy`/preflight rejection and a
clipboard `Unsupported` result alone do not stop a healthy host. A
keymap/Compose admission failure revokes the unusable direct target; ordinary
mode-entry errors remain typed and preserve the prior mode/epoch. Stale direct
key/text records are discarded before delivery.
If epoch allocation would wrap or is otherwise exhausted, the host fails
closed: an ever-armed host revokes direct input and event reads return
`Resource` until a fresh host is created. Disable/re-enable does not revive it.
Never-armed legacy hosts retain their earlier behavior.

Native event delivery uses private `gpui_next_v2(abi=2, ...)`; the existing v1
record layout stays unchanged. The non-null event buffer must hold at least the
ten common doubles. Negative capacities and a null text pointer paired with a
positive capacity are invalid; null text with zero capacity is allowed for
non-text records. Direct committed-text tag 13 stores its exact UTF-8 byte
length in detail slot 8 (coordinates are zero); each payload is 1–128 bytes,
copied exactly without a NUL or padding write. If a text payload cannot fit,
the call returns `Resource` without changing either output or consuming the
head record. Invalid ABI/buffer requests likewise leave outputs/head untouched.
The strict decoder copies the bytes before the next native read; no native
pointer escapes. v2 drops stale key/text events without disturbing the order
of surviving non-text events. v1 `gpui_next` returns `Unsupported` without
consuming anything while direct mode is active or any direct-origin key/text
record is queued, including after disarm. It never silently drops queued text. The public
Ubuntu host opts in through
[`Host::set_direct_keyboard_text`](../ubuntu/backend.mbt) and reads the current
epoch through `Host::direct_keyboard_text_epoch`; the private ABI is declared in
[`ubuntu/backend.h`](../ubuntu/backend.h) and implemented in
[`ubuntu/backend.c`](../ubuntu/backend.c). This private route does not extend
the public scene schema or claim general OS text-input support.

## Rejection, presentation, and recovery

Text validation, same-context measurement, hit testing, and real grayscale
admission happen before a candidate state is committed. A whole-edit
validation or native raster-preflight failure preserves the prior field
snapshot and, while the surface/device remains live, the previously displayed
frame. A typed `Busy` presentation result keeps the already-admitted pending
edit for retry; later edits build on that pending candidate rather than
silently reverting. Surface/device loss follows typed renderer recovery and
carries no promise that old pixels remain visible. The owner re-arms after a
preflight rollback so queued input and paste guards cannot target a restored
revision. Owner integration and these transaction paths are in
[`examples/linux_text_field/main.mbt`](../examples/linux_text_field/main.mbt) and
[`examples/linux_text_field/controller.mbt`](../examples/linux_text_field/controller.mbt).

This field uses, but does not broaden, Ubuntu's separate
`GrayscaleTextFrames` capability. Grayscale renderer bounds and Pango/version
admission remain as described in the [Linux text guide](linux-text.md#ubuntu-grayscale-scene-text)
and [Ubuntu guide](ubuntu.md#grayscale-text-frame-subset). Rendering capability
is not keyboard input, IME, color text, or accessibility.

## Evidence and remaining gates

Evidence is tiered and must not be conflated:

- Local portable/model tests cover edit state, limits, cursor-stop navigation,
  selection, rejection, and immutable snapshots. The controller suite uses
  installed real sans/Pango measurements and tests negative-bearing rejection,
  clipboard transaction guards, `Busy`/rollback behavior, focus routing, and
  the rule that `Character` keys do not insert.
- Local headless native tests cover direct-mode callbacks, epoch/stale-record
  and queue behavior, Compose/release bookkeeping, decoder validation, exact
  byte copying, and capacity/canary cases. The fixture encoder and GPU test
  source also have strict local compile/test evidence. These tiers do not
  simulate compositor-delivered keyboard input.
- The control-to-renderer fixtures and `Host.present` checks are explicitly
  separated. `GPUI_FIELD_E2E` in
  [`examples/linux_text_field/host_present_wbtest.mbt`](../examples/linux_text_field/host_present_wbtest.mbt)
  is opt-in under a compositor; replayed fixture frames are injected into the
  renderer and prove neither `wl_keyboard` delivery nor real typing. Its typed
  `Busy` assertion uses deterministic stale-viewport window state; it does not
  guarantee that an unpumped frame callback always yields `Busy`. The
  hosted field `Host.present`/injected-renderer result remains pending review;
  no field-specific hosted pass or source SHA is recorded here.
- Actual compositor-delivered typing into this control is **unrun**. The stock
  Weston 13 headless job has no admitted keyboard-injection driver for this
  qualification, and local AF_UNIX socket creation returns `EPERM`. Do not
  describe the existing PR28 Weston/llvmpipe text-drawing run as field-input
  evidence. Japanese IME, composition UI/candidate positioning, real desktop
  typing, accessibility, reconnect, and release/support gates remain open.

The field implementation is based on focused-input PR #29, merged at
[`18e8fad`](https://github.com/gpui-mbt/gpui.mbt/commit/18e8fadf470823b389feff3b9d496213b4d3f67a)
(tree `7554a5f181724160e1be4a11ac0e47067ca79e3d`); the relevant
[PR #29](https://github.com/gpui-mbt/gpui.mbt/pull/29) and
[PR #28 Ubuntu drawing run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37346110201)
are earlier foundation evidence only. See the repository's
[Ubuntu native workflow](../.github/workflows/ubuntu-native.yml) and
[testing evidence tiers](testing.md). This experimental field does not close
Ubuntu backend packet D or qualify gpui.mbt as a supported Linux desktop
framework.
