# Experimental Ubuntu Wayland text sessions

This is an opt-in, Ubuntu-local **experimental single-window text session**.
Set `GPUI_FIELD_WAYLAND_IME=1` for the Linux text-field example owner. The
portable platform API and default direct-keyboard path keep their current
behavior. This flag alone is not a general GPUI IME capability or native
acceptance claim.

The bounded deployment target is Weston14 desktop-shell with text-input-v1,
stock IBus1.5.32's Wayland adapter and Mozc. The adapter must be launched by the
compositor with its inherited privileged `WAYLAND_SOCKET`; synchronous IBus
mode is required in that profile. Weston kiosk-shell does not initialize this
manager. Other compositors, v3, XWayland, candidate-table selection and IME
repeat are unqualified. A compositor without v1 returns UnsupportedCapability.

## Owner API

Use a single focused target in the host's one live window:

- `begin_text_session(window, committed_document, logical_caret_rect)` returns
  a positive epoch. Wait for the matching `Entered` event; activation is async.
  `Entered` proves v1 protocol focus only, not an available/ready engine or grab.
- `next_editor_event(timeout_ms?)` returns either a normal platform event or a
  typed Ubuntu text-session event from the same ordered native queue.
- `update_text_session(window, epoch, committed_document, logical_caret_rect,
  external_edit?)` defaults to an external-edit fence. Pass `external_edit=false`
  only to acknowledge an ordinary IME edit or update caret geometry in the same
  transaction. The returned epoch may change.
- `cancel_text_session(window, epoch)` cancels the old target and requests a
  replacement epoch using the last committed document. After restoring an owner
  transaction, send its correct committed document with `update_text_session`.
- `end_text_session(window, epoch)` revokes the target.
- `set_text_session_panel(window, epoch, visible)` requests show/hide. Panel
  lifecycle and placement still need actual integrated screenshot acceptance.

A caret rectangle is in surface-logical coordinates, with integral signed
Int32 x/y and positive integral Int32 width/height. There is no output-scale
multiplication. Derive it from the actual owner caret, not a fixed window corner.
The whole committed document is currently limited to 4096 UTF-8 bytes and cannot
contain NUL; no surrounding-text window/truncation policy is implemented.

Disarm `DirectKeyboardText` before beginning an IME session. While activation,
IME ownership or its leave fence is pending, direct XKB/Compose text and the
existing text repeater are suppressed. Command keys retain raw `wl_keyboard` keysyms when delivered by the compositor,
and IME-forwarded keysyms with modifiers decoded from its advertised names.
During a leave fence old-target keys are excluded. An unavailable/stalled engine
can still leave text undelivered; end the opt-in session to release ownership. The
transport neither derives character text nor synthesizes a release/repeat flag.

## Atomic events and freshness

Every text event captures window generation, native sequence, epoch, seat global
and proxy generation, plus its issued commit-state serial. Session epochs and
serials are positive and never wrap. Serials from the current activation floor
through the latest issued state are accepted; multiple commits can legitimately
share one serial. No deduplication by serial occurs.

Preedit styling/cursor metadata is staged for the next preedit string. The
preedit and its fallback are copied immediately; UTF-8 cursor/style boundaries
are checked and translated into UTF-16 by the typed decoder. A negative cursor
hides it. The fallback is retained for inspection and is never auto-committed.

Surrounding deletion and cursor-position metadata is staged separately for the
next commit string and delivered as one atomic event. Empty commit text can
carry a real deletion or cursor move. Signed postinsert cursor/anchor and
surrounding-deletion byte indices are retained exactly. The editor applying
these operations must check them against its correct committed document and
convert UTF-8/UTF-16 boundaries with checked arithmetic. This transport does not
apply those text semantics. Multiple deletion records within one pending commit
are rejected by this bounded profile, rather than silently overwritten.

Focus loss, close, destroy and removed seats/proxies clear pending staging and
invalidate the composition target before their lifecycle event. Stock IBus's
v1 reset handler is empty, so external edits and cancellation serialize
`deactivate -> leave -> activate`. Immediate refocus waits for the old leave;
delayed old-proxy or old-serial events cannot attach to the replacement target.

There is one FIFO, not a second IME stream. Editor ABI3 preserves ordinary ABI2
records and has a separately versioned typed payload. Legacy ABI1/2 readers
reject an editor head without consuming it. Malformed/undersized typed reads
leave the entire queue and both output buffers unchanged. Native payloads have
4096-byte string limits, 64 styling spans and a 1MiB total allocation budget.
Queue, sequence, epoch or serial exhaustion fails closed; an ever-armed exhausted
IME host cannot regain editor ingress through legacy/direct readers. Start a
fresh host to recover from exhausted identity space.

## Verification scope

`sh scripts/test_ubuntu_ingress.sh` runs the production callback, staging and
queue code headlessly with mocked protocol requests. Set `GPUI_TEST_CFLAGS` for
sanitizers. It covers copied-buffer lifetime, independent staging, shared serials,
stale epochs/serials, leave fencing, rapid reactivation, removed proxies, bounded
resource failure, legacy reader rejection and direct-text suppression. Native
MoonBit tests cover the defensive typed decoder and owner argument validation.

These tests do not qualify GPUI native composition, undo integration, candidate
popup placement/selection, keyboard-grab readiness or IME repeat. Those require
the next owner integration and automated private-display E2E gates. Existing
native direct-input and renderer cases remain their own acceptance scope.

## Bounded field owner

The example consumes only the ordered ABI3 editor stream. It waits for native
keyboard focus and an accepted field presentation before beginning; Entered
captures the owner seat/proxy generation. Window, epoch, FIFO sequence and
seat/proxy checks keep old records from reaching a replacement target. Native
code owns the issued serial floor and does not deduplicate shared serials.

`TextField.committed_document()` reads the original directional document while
composing. Surrounding state never includes preview bytes. The preview uses
strict UTF-16 scalar and exact measured cursor stops. This first profile accepts
whole-span underline style 5, paints the marked underline, and rejects hidden
cursors and other style shapes explicitly. Preedit fallback never commits.
Empty preedit restores the original directional selection and history without
an edit; a subsequent commit replaces that restored selection. Empty commit is
an actual replacement, including deletion of the original selected range.
Signed surrounding deletion and postinsert cursor metadata are typed rejected,
including on empty commits; reconversion is not qualified by this profile.

A commit is one original-to-final undo group. Commands and pointer edits resolve
a preview explicitly, then fence native state before consuming another event,
even while presentation is Busy. Blur restores the original transaction and
ends the session. Unsupported text semantics restore/fence, with a typed
`GPUI_IME_REJECT` diagnostic. Rejected presentation restores the last submitted
history, cancels its preview and fences the replacement epoch before retrying.

`TextField.caret_rect()` shares the painted caret's surface-logical mapping,
including inset, negative-bearing run origin and horizontal scroll. The owner
rounds endpoints outward and validates signed Int32 endpoints and positive
Int32 extents. Output scale is never multiplied into that rectangle.

Raw keysyms map only named commands and an explicit Ctrl/Meta A/C/X/V/Z/Y
shortcut allowlist. They never create character text; genuine forwarded releases
remain releases. Show/hide input-panel requests accompany preview, commit and
blur, but candidate popup placement/lifetime needs its own exact-GPUI evidence.

With `GPUI_FIELD_E2E_STATE=1`, accepted IME presentations emit read-only
`GPUI_FIELD_IME_STATE` version-1 JSON. It contains committed and preview text,
both directional selections, marked range, composition/focus, native owner
epoch/Entered, commit count, undo/redo availability and logical integer caret.
It calls no input callbacks and never mutates the editor. Busy/rejected frames
emit no checkpoint. Use only non-sensitive synthetic text in this opt-in log.

Focused owner tests include real Pango admission, original surrounding/history,
empty preview versus empty commit, typed metadata rejection, scalar and cursor
stops, target fencing, command allowlist and fractional/scrolled caret geometry.
Native GPUI acceptance is separately recorded by the GPUI-specific private
runtime harness; the frozen stock-editor baseline is never substituted for it.
