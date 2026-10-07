# Windows command palette

`examples/windows_command_palette/` composes the shared bounded picker with the
existing Windows text field, live `ElementTree`, and native one-window host. The
fixture has 16 sample commands, an intentionally disabled row, a 128-command
component limit, eight visible rows, exact committed-text substring filtering,
and a 256-byte query bound. Ctrl+K opens it; arrow keys navigate, Enter selects,
Escape dismisses, and clicking outside blurs. A fresh open creates a new palette
epoch and an empty search field.

The private IMM32 session remains default-off. When opted in, native records
must match the window, stable field owner generation, current palette open
epoch, native session epoch, and increasing event sequence before they can
install a field value. Composition updates are prepared from their saved
committed replacement range. Preview text and caret edits do not change the
picker query; an accepted native result commits once and filters immediately.
An ordinary committed field edit synchronously refreshes and fences the native
snapshot before the event loop can consume another IMM32 record. If a native
candidate cannot be installed within the palette's query bound, the saved
composition is restored and the native session is cancelled/rearmed before
more records are accepted; a failed recovery exits with the modal focus held.
Escape cancels composition before another press can close the palette. A
Win32 focus loss can enqueue the old-epoch `Cancelled` record before
`FocusChanged(false)`, even though the HWND has already lost focus. The palette
rechecks actual window focus while handling `Cancelled` and immediately after
an accepted present, before syncing the native owner. The accepted-present
check also verifies that the exact native session epoch remains armed, because
the window can lose and regain OS focus while Win32 has already revoked the
old session. If either check detects revocation, the palette restores any
still-live composition transaction, ends the native owner, and retains the
accepted frame until completion before submitting the closed state. Closing
ends the native owner before the palette runs a command or restores saved
focus. A failed close fence leaves focus in the modal tree and does not run the
command. Text-session event payloads keep reserved geometry fields zero; the
window viewport is carried by platform events.

The frame loop snapshots the scene, query, selection, owner, focus, and pending
frame together. A busy present retains that complete prepared value for retry.
An intervening platform or native event invalidates the retry and builds a new
complete scene from the updated model. A hard present failure closes without a
command, retains modal focus if the native fence fails, and exits without
replaying partial palette state. Only one accepted frame may await application
consumption of `FrameCompleted`, because that event carries no presentation
identity. While one is pending, input can continue to update the live palette,
but a newer scene waits for the old completion and readback to be paired. Each
pending record retains its submitted logical viewport and scale, so a resize
does not relabel the older frame's staging samples. The fixture logs frame
acceptance and completion identities and obtains staging readback only after
the matching completion event.

Run the pinned Windows gates with `scripts/test_windows.ps1` or the local actrun
workflow with `scripts/run_windows_actrun.ps1`. For a visible, bounded GUI
fixture use `scripts/run_windows_command_palette.ps1 -Mode Run`; add
`-ExperimentalIme` only for the manual IME exercise. `-Mode Smoke` opens the
fixture, verifies one completed frame and readback, then exits. Launch details,
cleanup command, flushed observer logs, and a tool/source/font/OS/GPU manifest
are written under `_build/windows-command-palette/`.

For the one-window interaction pass, start the visible fixture and follow this
sequence with physical key presses: Ctrl+K opens; type `Go` and confirm the
committed query and filtered rows in `app.stdout.log`; use Up/Down and Enter to
activate one enabled result; reopen and press Escape to cancel; reopen, click
outside to blur, then press Ctrl+K to reopen with an empty query. The state
records should show one activation, restored background focus, and no closing
key counted as a background press or release. With `-ExperimentalIme`, use the
Japanese IME to show preedit, conversion, and commit in the search field. The
query must remain unchanged during preedit; Enter must stay with conversion;
the first Escape cancels and leaves the palette open; a later fresh Escape
closes it. Compare the state `caret` rectangle with the candidate-window
placement and retain screenshots of the matching final frames for search,
active/disabled rows, scrolling, and clipping. Use the manifest and the
`ACCEPTED`/`COMPLETE`/`READBACK` observer records to pair each screenshot with
its final-source presentation and completed native frame. The smoke gate parses
the exact record prefixes, requires matching presentation and event-sequence
identities, and validates all three expected sample coordinates and RGBA values.

Portable component tests cover model bounds and selection behavior. Windows
owner regressions cover native owner, epoch, sequence, composition, close-fence,
Busy retry, and fatal rejection transitions. Actual Japanese IME behavior,
candidate contents/highlight, and visual qualification of search/caret, rows,
scrolling, and clipping require final-source GUI evidence for the declared
Windows display profile. The three staging samples supplement that evidence
but do not qualify the full frame. UI Automation transport and broader Windows
support remain unsupported.
