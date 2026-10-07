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

Run the pinned Windows gates with scripts/test_windows.ps1 or the local actrun
workflow with scripts/run_windows_actrun.ps1. scripts/run_windows_command_palette.ps1
-Mode Smoke verifies one completed frame and D3D11 readback before exiting.
For the scripted real-input pass, run these commands from 64-bit PowerShell:

    pwsh -NoProfile -File scripts/run_windows_command_palette_e2e.ps1 -Mode Validate
    pwsh -NoProfile -File scripts/run_windows_command_palette_e2e.ps1 -Mode Preflight
    pwsh -NoProfile -File scripts/run_windows_command_palette_e2e.ps1 -Mode Run

The driver requires a readable active Default input desktop. It records an
access failure and exits without launching a fixture or sending input if that
preflight is unavailable. Run mode verifies a clean source commit and matching
executable manifest, launches two copies of the owned fixture (one IME-enabled
primary and one input-free focus target), then sends scripted virtual-key
events through Win32 SendInput. It uses no Unicode text injection and checks
the owned PID, start time, executable, HWND, foreground window, and input
desktop around each input batch. It covers Ctrl+K, ordinary committed search,
disabled-row navigation, scrolling, one-shot activation, background key
recovery, Japanese IME preedit/conversion/commit, Escape cancellation and
dismissal, composition-time focus loss, and empty reopen with fresh epochs.
The primary fixture closes only after an observed closed/end-fenced frame; both
owned windows receive bounded WM_CLOSE. Window discovery requires exactly one
visible top-level `gpui_mbt_windows_host_v1` window under the child PID whose
start time, native executable path, and executable hash still match the launch
record. The caption is diagnostic data and is not used to identify the window;
same-PID console windows and other-PID decoys cannot match. If startup
discovery fails, bounded cleanup repeats those identity and class checks before
it can send WM_CLOSE, while the original run remains failed.

Each run saves result.json, flushed stdout/stderr, correlated
ACCEPTED/STATE/COMPLETE/READBACK identities, exact input counts, IME layout/state
restoration, and full visible-client BMP captures under
_build/windows-command-palette/e2e/ (or -OutputDirectory). The parser rejects
a newer incomplete frame so captures cannot be paired with stale readback.
After a requested state is reached, capture may settle on a newer complete
frame only when its visible palette state, search selection, focus, caret,
viewport, options, IMM32 mode, key counters, native owner generation/epoch/
sequence/composition state, and native record/fence counters still match that
request. Only the presentation-side native `update` counter may advance during
settling; background or guarded key counts and every other native counter stay
part of the equivalence check. The driver retries capture when the frame
identity advances during BitBlt, while retaining each attempt (including a
terminal capture error) and requiring exact
ACCEPTED/STATE/COMPLETE/READBACK identity before and after a successful
capture. A changed semantic state or exhausted bounded retry remains FAIL; an
older frame cannot turn a failed capture green. Three GPU samples remain
separate from the full client image. Candidate-form coordinates report
the IMM32 adapter request and retain their source frame/semantic identity; that
query alone does not prove popup visibility or placement. Review each stable
full-client BMP at human scale before marking pixels qualified. Candidate
contents and highlight remain UNRUN unless separately qualified. Preflight or
focus failures are retained as FAIL/BLOCKED with dependent stages UNRUN.

Portable component tests cover model bounds and selection behavior. Windows
owner regressions cover native owner, epoch, sequence, composition, close-fence,
Busy retry, and fatal rejection transitions. Actual Japanese IME behavior,
candidate contents/highlight, and visual qualification of search/caret, rows,
scrolling, and clipping require final-source GUI evidence for the declared
Windows display profile. The three staging samples supplement that evidence
but do not qualify the full frame. UI Automation transport and broader Windows
support remain unsupported.
