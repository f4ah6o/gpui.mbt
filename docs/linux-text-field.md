# Experimental Linux single-line text field

Status: experimental reusable single-line LTR field on Ubuntu/Wayland.
[PR30](https://github.com/gpui-mbt/gpui.mbt/pull/30) and
[PR31](https://github.com/gpui-mbt/gpui.mbt/pull/31) are merged; the source baseline
is `73e70822841024a7131c54fb4529cd40186d529c` (tree `108cf4e9`). Their declared
Ubuntu/Weston/llvmpipe profile passed real `Host.present` and injected field
text/caret/selection/scroll/overhang checks at 1x/2x. Native direct-keyboard
callback/queue/decoder tests are a separate tier; actual compositor-delivered
typing, held-key repeat timing, and Japanese IME remain unrun. Bounded direct
keyboard repeat has deterministic callback/queue and model/controller coverage
only. The undo/redo addition described below
has local model/provider coverage; its new hosted rendering cases remain
pending for the current change.

This is a deliberately narrow, opt-in demonstration of a bounded single-line,
left-to-right (LTR) entry field joining copied text geometry, portable editing
state, Ubuntu grayscale drawing, focused dispatch, and a private native direct
keyboard-text route. It does not establish ordinary application readiness.

## What the slice does

- `controls/text_field/` supplies immutable document, selection, focus, scroll,
  revision, and bounded undo/redo snapshots. `examples/linux_text_field/` owns its native target,
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
  Ctrl/Meta+A selects the entire document from anchor 0 to its UTF-16 length
  while focused. It uses the selection-only transition, retaining undo/redo
  groups and snapshots; repeating an already full selection is a no-op.
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
  widgets, drag-selection, word navigation, bidi editing, or wrapping.
- The existing Ubuntu clipboard API is reused. Copy writes the selected text;
  cut prepares and raster-admits the edit first, writes clipboard data, and
  installs the candidate only after a successful write. Paste uses the
  existing bounded synchronous clipboard read and strict UTF-8 decoding. The
  owner captures the field revision and direct-text epoch before the read and
  rechecks focus, revision, and epoch after any event pumping before admission.
  A stale or invalid paste is discarded whole.

## Bounded undo/redo

`can_undo()` and `can_redo()` report retained stack availability, independent of
focus. `undo(measure, admit)` and `redo(measure, admit)` are unchanged-value
no-ops when unfocused or empty. Ctrl/Meta+Z undoes; Shift+Ctrl/Meta+Z or Ctrl+Y
redoes. Alt-modified shortcuts are ignored. Key labels identify shortcuts;
only committed `TextInput` supplies inserted text.

The repeat flag does not change the field's existing command policy. A repeated
printable `KeyPressed` inserts nothing; its following `TextInput` inserts once.
Each repeated content-changing commit or deletion is a separate history group.
Repeated navigation adds no history. Repeated undo/redo executes once per press,
and repeated copy/cut/paste, Submit and Blur still emit their usual owner actions.
Consumers that want a one-shot command must check `KeyPressed.repeat` before
routing that command. The native repeat feature adds no typing coalescing or
new shortcut suppression.

Each successful content-changing text commit, deletion, paste or installed cut
is one group, without typing coalescing. An entry stores immutable pre-edit and
original post-edit documents including directional selections. Undo restores
the former; redo restores the latter even after selection-only navigation.
Copy, focus/bounds/selection changes, failed input or clipboard writes and stale
paste add no group. Identical-content replacement may change selection/revision
under the existing policy, but preserves redo. New content clears redo.

The combined stacks retain at most 64 entries and 65,536 logical UTF-8 payload
bytes. Each entry counts both endpoint texts, including duplicate content
across entries; selection metadata is excluded. New edits evict whole oldest
undo entries until both limits fit. This is logical payload accounting, not an
exact heap bound or a bound on immutable snapshots retained by callers. Arrays
are private and transitions use detached copies.

Restoration never reinstalls old focus, bounds, measurement or raster handles.
It validates the stored document and cursor-stop selection, remeasures and
re-admits with current style/bounds, advances the current revision and computes
current caret scroll. Failure leaves the document and both stacks unchanged.
Prepared cut history installs only after successful owner clipboard write.
`Busy` keeps the pending admitted value/history; rejected presentation restores
the submitted document/history using the existing current-bounds/focus policy.
The owner re-arms input after rollback as before. Revision exhaustion is an
explicit failure, not a history reset or counter rewind.

## Bounds and origin-aware run geometry

The current field limits document text to 4,096 UTF-8 bytes, font size to 32
logical pixels, and measured logical/ink geometry to 2,048 by 128 pixels. It
requires exactly one line, no unknown glyphs, valid monotonic strong caret
positions contained in the logical line with matching strong/weak geometry,
and a single LTR caret order.
Committed/pasted U+0000–U+001F, U+007F–U+009F, U+2028, and U+2029 are forbidden;
other text is neither normalized nor truncated. Unsupported layout is rejected
as a whole edit. The owner supplies trusted measure, admit, and hit-test
callbacks using the same `sans` family, font size, and Pango context as the
renderer. The field validates returned document identity, geometry, line and
cursor-stop invariants; click handling also checks the hit result's document
identity and resolved cursor-stop status against the stored measurement before
changing selection. See the exact validation in
[`controls/text_field/model.mbt`](../controls/text_field/model.mbt).

The example measures and paints with the same generic `sans` family, 18 px
size, and PangoFT2 context so caret and hit geometry match drawing. The field
now derives one checked run mapping from the union of Pango logical and ink
extents; legal caret stops must stay inside the logical line. It rounds each minimum edge down and maximum
edge up to whole logical pixels, including Pango's pixel coverage, then uses
that inset as `text_origin` and a zero-based rectangle as the exact item-local
clip. `TextRunItem` keeps this text origin independent of the clip bounds; the
native rasterizer clips in local coordinates before the affine transform. The
same calculated union/clip is used for field admission, caret and selection
painting, hit-test coordinate mapping, and horizontal scrolling. This preserves
negative left/above ink bearings without changing the legacy `TextItem`
positioning contract. Actual-font headless control and negative-mask tests now
pass for negative-bearing text, composed and decomposed accent cases, and
scrolling. The merged origin-aware baseline also has hosted 1x/2x drawing
evidence; these checks do not qualify compositor-delivered typing.

The scene envelope remains schema v1. Existing `TextItem` meaning and canonical
JSON are unchanged. The new `TextRunItem` is a plain system-sans variant
serialized as `kind: "text_run"` with a separate `text_origin` and local clip
bounds. The Ubuntu mixed-frame ABI3 uses a 25-double record: it preserves all
23 ABI2 fields and appends origin x/y; kind 2 denotes the new run, while quad
and legacy text kinds require zero origin fields. Linux raster_v2 returns the
v1 mask plus UV crop coordinates in a separate v2 result, preserving the v1
mask struct and entry semantics. V2 keeps a one-texel sampling halo at interior
crop edges, bounded by full pixel ink and charged to all mask budgets before
allocation; exact visible geometry and UV crop remain independent. V1 keeps its
legacy no-halo storage and filtering. V2 also rejects clip/ink roundtrip error
above a fixed 1/4096 logical pixel before allocation. Envelope v1 permits
item-variant additions,
so consumers must reject unknown variants, and public exhaustive matches must
add an explicit `TextRunItem` case. The backend and native contracts are
documented in the [Linux text guide](linux-text.md#ubuntu-grayscale-scene-text)
and [platform boundary](platform.md#scene-and-renderer-boundary).

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

### Bounded direct keyboard repeat

Repeat is private to the opt-in direct keyboard-text route. The backend caps
`wl_seat` binding at version 4 and uses the version-4 `repeat_info` policy.
Seats below version 4, missing policy, and a zero rate produce no repeats.
For an enabled policy, a fresh repeatable physical press within the existing
portable logical-key subset, not consumed by Compose, caches its logical key
and optional exact UTF-8 text commit. Physical
presses carry `repeat=false`; synthesized presses carry `repeat=true` and are
followed by their cached text, when present. There are no synthetic releases.
Compose-consumed prefix/completion/cancel presses never arm repeat, and the
timer never feeds Compose or produces an IME commit.

After dispatching available native callbacks, a native dispatch cycle admits
at most one atomic key-plus-optional-text group, only when the copied event
queue is empty. The poll timeout is bounded by the next repeat deadline. An
overdue deadline produces one group with no catch-up burst. Scheduling has
1 ms resolution: the interval is `max(1, ceil(1000 / rate))` milliseconds, so
rates above 1,000 Hz saturate at that resolution rather than creating a
zero-interval loop. This is a bounded scheduler contract, not a promise of
desktop repeat timing accuracy. Negative rate/delay values fail with typed
`InvalidInput`; monotonic-clock failure or backwards time fails with
`NativeFailure`, and checked time/sequence exhaustion fails with
`ResourceExhausted`. These fatal paths revoke the direct target rather than
replaying an old candidate.

An unchanged `repeat_info` policy preserves the held candidate. A changed
policy, modifier state, or layout/keymap cancels it until another physical
press; a timer does not reinterpret the cached key or text. Matching release,
focus loss, direct-mode/epoch changes, keyboard/seat loss, window close/release,
host stop, and fatal display/dispatch failure also cancel pending repeat. These
rules preserve current stale-generation filtering and queue admission bounds.

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
Slot 7 stores the key repeat flag: press tag 11 accepts
exactly 0 or 1, release tag 12 requires 0, and committed-text tag 13 requires 0.
NaN, infinity, fractional values, and other numbers are typed `InvalidInput`
decoder failures. Pointer records retain slot 7 as their y coordinate.
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
  selection, rejection, and immutable snapshots. The headless real-font field
  and negative-mask suites pass with installed sans/Pango measurements,
  including composed/decomposed accents and scrolling. Controller coverage
  also checks clipboard transaction guards, `Busy`/rollback behavior, focus
  routing, and the rule that `Character` keys do not insert.
- Repeat-specific portable and real-font controller tests cover printable
  repeated-key/text ordering, one content-history group per repeat, navigation
  without history, repeated undo/redo and clipboard/submit actions, and paste
  freshness and presentation rollback after repeated deletions. They inject
  input records into the model/controller; they do not inject a compositor key.
- Local headless native tests cover direct-mode callbacks, epoch/stale-record
  and queue behavior, Compose/release bookkeeping, decoder validation, exact
  byte copying, capacity/canary cases, and origin-aware Pango mask clipping.
  Repeat tests use deterministic mocked Wayland callbacks and clock/queue
  observations to check policy, cancellation, deadlines, saturation, no catch-up,
  and atomic key/text delivery. Strict MoonBit decoding tests validate repeat
  flags separately and preserve pointer-y decoding.
  These checks include history limits, restore/rollback and immutable branching.
  New undo/redo encoder and GPU cases compile; their hosted execution is
  pending. These headless tiers do not simulate compositor keyboard input or
  prove a GPU presentation.
- The control-to-renderer fixtures and `Host.present` checks are explicitly
  separated. `GPUI_FIELD_E2E` in
  [`examples/linux_text_field/host_present_wbtest.mbt`](../examples/linux_text_field/host_present_wbtest.mbt)
  is opt-in under a compositor. The test-only GPU harness retains start/scrolled
  j/J and accent readbacks when executed; no such readback exists locally.
  Replayed fixture frames are injected into the
  renderer and prove neither `wl_keyboard` delivery nor real typing. Its typed
  `Busy` assertion uses deterministic stale-viewport window state; it does not
  guarantee that an unpumped frame callback always yields `Busy`. The
  merged field/origin baseline passed
  [PR31 Ubuntu run37392223946](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37392223946)
  at both scales with source tree `108cf4e9`; exact-head scene originals, encoded
  frames, font/config hashes and readbacks were retained and reviewed. The new
  undo/redo cases submit actual control scenes and extend real `Host.present`
  serialization, but remain unrun under hosted GPU until qualified for this
  change. Rejected newline/bidi scene identity is headless control evidence,
  not a distinct live GPU rejected-edit oracle.
- Actual compositor-delivered typing and held-key repeat timing into this
  control are **UNRUN**. The stock
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
framework. The bounded field remains single-line LTR and rejects unsupported
unknown-glyph, color-glyph, and reflow/resource-limit cases. Text masks remain
logical-resolution and may soften under output scaling. IME, qualified desktop
repeat timing, general bidi, drag selection and actual compositor-delivered typing remain
open. Undo/redo is bounded as above; it does not establish a full editor history
system. See the [known hosted-compositor stability note](ubuntu.md#known-hosted-compositor-observation).
