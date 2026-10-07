# Kotoeri hardware-input boundary — pending

Product Green: **false**. No GPUI product code was changed. Existing diagnostic
commits `8a7cf7c` / `e60b76e` and PR45's archived evidence are preserved.

## Observations

| Experiment | Result | Observation |
| --- | --- | --- |
| Archived A, immediate preview | FAIL (previous run) | Preview 0.042 ms; 200 pumps; no commit callbacks. |
| Archived synthetic B | FAIL (previous run) | 200 pumps, 3369.665 ms; marked remains; insert/unmark delta 0. |
| Fresh synthetic B, final instrumented fixture | FAIL | PID 71765; Return once, down/up delivered; 200 native and AppKit pumps; down→end 3317.621 ms, up→end 3311.812 ms; insert/unmark delta 0. |
| Hardware Return comparison | **NOT_RUN / 未実行** | PID 70605, window 5349; 180 s readiness expired; zero key events, zero Return, zero Return observation pumps. |

Synthetic Return saw Kotoeri Japanese Romaji, active application, owned key
window, `KotoeriControl` first responder, and the original live input context.
`Hello 日本語` was marked; committed text remained `Hello `. There were eight
setMarkedText callbacks during prefix entry and no insertText, unmarkText, or
doCommandBySelector callback during Return. CG/NSEvent timestamps were zero,
keyboard type 198, CG source state 0, and source PID 71765. These are observations,
not proof that any single metadata field causes the failure.

The hardware-readiness run selected the same Kotoeri source and matched the
same window geometry, first responder, initial text/caret, activation helper,
raw-executable launch, retained context, and 16 ms default-mode pump as B. The
`ready` record confirmed frontmost PID 70605 and key window 5349. A human was
asked to type on physical hardware; no keystrokes or hardware confirmation were
received. Readiness used 10776 additional pumps over 180009.402 ms. **Those are
not Return observation pumps and are not an IME timeout or failure.**

Both runs restored the source and closed their window. The readiness process
was reaped. Its requested physical producer emits no keyboard events. Computer
use was used only to inventory available surfaces, not to type or press keys.

The readiness executable predates final review fixes (invalid-sequence/cleanup
cannot report PASS; explicit source fields and Return-up elapsed added). Its
reconstructed source and binary SHA are recorded in provenance. Fresh synthetic
B used the final fixture. They are **not a same-binary Return comparison**;
there was no hardware Return to compare. A new hardware run must use the final
executable also used for fresh synthetic B.

## Cause boundary

Unresolved. The earlier A/B results still favor investigating the shared
producer/AppKit/IME conditions, but physical-input success or failure has not
been observed. Neither physical-success case A nor physical-failure case B can
be selected. Do not modify GPUI, extend the 200-pump operation budget, repeat
Return, directly invoke IME callbacks, or weaken acceptance to claim success.

## Changes and checks

Only the minimal test fixture and diagnostic instructions were changed, plus
this new evidence directory. `--physical` waits with the existing pump, observes
the same nine keycodes, requires one Return and the existing commit predicate,
and always restores/closes. Opt-in logs are bounded to 192 records and capture
event routing, callbacks, marked/committed text, focus/context/source, and time.
Human hardware provenance requires separate confirmation; metadata never
automatically claims it.

| Check | Result this continuation |
| --- | --- |
| Fixture clang `-Wall -Wextra -Werror` | PASS |
| Opt-in / invalid argument rejection (3 cases) | PASS |
| Trace-off compatibility: no control logs; unchanged synthetic failure and cleanup | PASS |
| Synthetic trace monotonicity, ownership, 192-record bound, exact 200 pumps | PASS (IME Return itself FAIL) |
| Hardware NOT_RUN classification / restoration / window closure / process reap | PASS (hardware Return 未実行) |
| Existing A/B archive validator | PASS |
| New archive validator | See validation.log |
| `moon fmt --check` | PASS |
| Native package / wbtest / warnings-denied native and all-target checks / build entrypoints | 未実行 this continuation; previous results remain in the A/B archive |
| GPUI live E2E / screenshots / follow-up composition / Escape | 未実行 this continuation; Product Green remains false |

No reset, stash, clean, evidence overwrite, or push was performed.

For the next hardware run, use [the diagnostic instructions](../../KOTOERI_DIAGNOSTICS.md#hardware-keyboard-comparison),
verify its new exact PID/window before input, and obtain the human's hardware
confirmation. `synthetic.stderr.log` provides the fresh comparison trace.
