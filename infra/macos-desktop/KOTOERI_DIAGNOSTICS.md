# Kotoeri Return diagnostics

These diagnostics do not change the key sequence, synthesize IME callbacks, or
extend the 200-iteration Return observation limit.

## Experiment A: immediate collector preview

Build one test-hook TextField app, then use that **same binary and dylib** for
normal `ime-acceptance.py` and `--diagnostic-immediate-preview` runs. The option
skips only composition capture, after validating the composition checkpoint,
and immediately sends `preview`. Initial/final capture and all native final
predicates remain in force. Diagnostic reports contain `diagnostic_only: true`,
never set `ok: true`, and never print `GREEN`. The artifact validator rejects
that marker even if someone changes `ok` and `status` to claim a pass.

Each run requires a new external output directory. The collector records
`composition_ready_to_preview_ms` from receipt of the composition checkpoint
until flushing `preview`, including composition capture in a normal run.
App activation must target only the exact owned PID/executable, as in the PR45
activation helper. Running a diagnostic does not authorize stopping another app.

## Experiment B: minimal standard control

Compile without launching:

```sh
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  tests/native/macos_kotoeri_control.m platform/macos_text/core_text.c \
  -framework AppKit -framework QuartzCore -framework Metal \
  -framework CoreText -framework CoreGraphics -o /tmp/gpui-kotoeri-control
```

The live opt-in invocation is:

```sh
GPUI_FIELD_MACOS_KOTOERI_CONTROL=1 GPUI_FIELD_MACOS_IME_TIMING_TRACE=1 \
  /tmp/gpui-kotoeri-control --local
```

It uses the exact `create_app_local_key_events` producer from native.m,
Kotoeri Japanese Romaji, and keycodes `45,34,4,31,45,5,31,49,36`. Return is
posted once, only after `Hello 日本語` is marked. A pass requires down/up
view delivery, an insert/unmark callback, exact final text, and no mark.
Return observation stops at 200 default-mode pumps of the existing 16 ms
parameter. The result reports source restoration; process exit is nonzero
if Return or cleanup fails. It does not qualify as Product Green.

The older larger contrast fixture is useful too, but its GPView adapter must
complete prefix and cleanup before its two-arm result is comparable. A valid
standard-control failure still provides independent evidence of the common
path; it does not prove that GPUI's client implementation is defect-free.

## Bounded timing

`GPUI_FIELD_MACOS_IME_TIMING_TRACE=1` affects only `GPUI_TESTING` builds. One
process emits at most 64 `GPUI_MACOS_IME_TIMING` records. Values contain fixed
phase names, a dispatch ID, counts, and clock values; no text or pointers.

- `monotonic_ms` uses `CLOCK_MONOTONIC`, independently of the event timestamp.
- `elapsed_ms` starts when the Return pair is successfully constructed.
- `return_down`/`return_up` mark entry to the owning view for the tagged Return.
- Callback phase records mark client entry; they do not create callbacks.
- `native_event_pumps` counts calls that actually entered `pump_native_event`.
- `appkit_event_pumps` counts actual calls to `nextEventMatchingMask` inside it.
  Draining an already queued GPUI event does not increment these counters.
- `last_pump_elapsed_ms` records the last completed native pump.
- The MoonBit operation-timeout diagnostic requests the existing read-only
  window-state hook, emitting `window_state_snapshot` before restoration.
  This timeout snapshot also requires `GPUI_FIELD_MACOS_IME_DISPATCH_TRACE=1`.
- `observation_end` closes the timing scope at the next constructed key or
  source restoration. It is later than a timeout snapshot and must not be
  mistaken for the exact timeout instant.

The trace never pumps recursively or changes owner, presentation, or ACK state.
The clock has millisecond units but may contain fractional values. Absolute
monotonic times are local to the host, not UTC or input-event timestamps.
