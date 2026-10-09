# macOS reusable Button fixture — Stage A and bounded Stage B

This example exercises the existing portable `controls/button` model in the
AppKit/Metal host. The fixture owns the Button and its application activation
count; macOS supplies the window, event queue, CoreText/Metal scene renderer,
and an opt-in native smoke path.

Source: [issue 0024](../../issues/open/0024-apple-silicon-macos-button-integration.md).
Parent: [macOS native backend roadmap](../../issues/open/0006-macos-native-backend.md).

## Scope and dependencies

Stage A history: its integration base is
`008b3c73d50108d6ed1e6c02ad9e12e930e843ec`, and its implementation branch
started from `48ca4ec0bc7862cbe3f4a6e6fc1f30af27fa3fa9`. Stage B starts from
`691edaf5012a9ae032dfe5d7721544818873717d`, after the PR #52 merge.
The reusable Button model and portable fixture are integrated from PR #47
(`4ee7bd48482db16fd6757265d7d1f3decd352bd7`); the fixture's latest
freshness checks and portable semantic projection arrive with PR #51
(`008b3c73d50108d6ed1e6c02ad9e12e930e843ec`). Stage A used the fixture's
Button state, event, and scene APIs. Stage B consumes its existing accessibility
snapshot and owner-validated semantic dispatch API. CoreText/Metal text
rendering and opt-in frame readback are integrated from PR #49
(`2c6e9a3df469922f79d7b2b8eb977a0524086486`, renderer slice
`816596187af35a8fcea3f6e7587df4f5ffed6532`). The current AppKit/Metal host
is already part of the base. Stage A does not depend on PR #40's text-field/IME
work or PR #42's documentation update. Stage B relies on the shared contract
already merged through PR #51.

Only this macOS example, its AppKit AX adapter, build/test support, its narrow
architecture contract registration and regression, this guide, and the
changelog are in scope. Do not change `controls/button`, the portable fixture,
the shared accessibility contract, the shared platform API, other OS samples,
or support-tier claims. The model and Ubuntu fixture remain the source of
portable state and activation semantics.

## Acceptance

- The native fixture presents the Button and its status/help text at logical
  coordinates through the merged CoreText/Metal renderer. The smoke check
  reads the completed GPU frame and checks the background, button fill/focus
  and pressed pixels, plus visible pixels in both the Button label and
  activation-status text regions.
- The sample routes host pointer and keyboard events through the existing
  element tree and Button model. Tab focuses or blurs; Enter and Space follow
  the model's matching-key rules. Disabled and loading transitions cancel
  armed input; hover, focus, pressed, enabled, and loading states are visible.
- Portable model/fixture and Mac-adapter tests exercise repeat,
  unmatched/duplicate release, blur, removal by undersized resize, same-value
  enabled focus preservation, reset, and zero/invalid-size/scale
  suspend/restore. No canceled input may activate after restoration.
- The finite opt-in native smoke uses the existing window-scoped synthetic
  click/Escape and FrameReadback hooks. It checks one pointer activation, the
  rendered status change, close/reopen with a reset app-owned count, and
  orderly cleanup. It also queues three content-size changes before polling
  and verifies the final-size frame, covering stale resize events. Before each
  dirty presentation the adapter reconciles its scene with the host's current
  logical size and backing scale. This is synthetic host-event and pixel
  evidence; it is not human-input, accessibility, or IME evidence.
- A separately launched GUI run is manually checked with Tab, Enter, Space,
  pointer input, state toggles, resize, and close. Report this separately from
  the synthetic smoke; do not claim it when the desktop is unavailable.

## Stage B: native accessibility

The Apple-only adapter repeatedly reconciles the existing `Run action`
snapshot while polling and after each host event. It exposes the snapshot as an
`NSAccessibilityElement` with the Button role, AX title, screen-space frame,
focused/enabled state, and help text for loading and activation count. AXPress
adds an opaque binding token to a 64-entry main-thread queue. The MoonBit owner
resolves that token to the retained full `NodeId` and `ActionRequest`, then
revalidates and dispatches against current fixture state. No physical key or
pointer event is synthesized. Node-generation changes, removal, reset, changed
bounds or availability, window close, and host teardown revoke the binding and
its pending work.

`test_macos_button_ax.sh --adapter-only` covers the AppKit projection, bounded
queue, stale token rejection, and lifecycle. `--all` builds the regular app
without `GPUI_TESTING`, gives only the test bundle a unique bundle identifier,
and launches a separate `AXUIElement` client. Monotonic deadlines bound
discovery to 15 seconds and initial-state/action/owner-count observation to a
separate 15 seconds. Before each synchronous AX query or action, the client
sets `AXUIElementSetMessagingTimeout` to at most 250 ms and less than the
remaining phase budget; tree traversal and poll sleeps also stop at that
deadline. The shell harness has a separate 35-second watchdog for the client,
retains its receipt and logs on timeout, then stops only the client and app PIDs
it launched. The client checks the named 240×48 control at screen bounds
corresponding to logical left 24/top 20, enabled and unfocused, with `Ready` and
the exact activation count in help. It invokes AXPress twice and requires the
owner-reported count to be exactly two.
`--mutation-probes` deliberately breaks the enabled-Invoke guard and keyboard
routing; each probe must fail at its relevant assertion. Each `--all` run keeps
a receipt with the absolute bundle path, unique bundle ID, launched PID, and
client status. These AX results are kept separate from the synthetic E2E, GUI
keyboard/pointer checks, and pixel readback. This bounded sample does not
qualify VoiceOver, Japanese IME, general widget accessibility, or a macOS
support tier.

## Build, test, and run

On Apple Silicon macOS with the pinned repository toolchain:

```sh
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpui-macos-button.XXXXXX")"
moon fmt --check
python3 tests/test_check_contracts.py
moon test --target native --deny-warn controls/button
moon test --target native --deny-warn examples/ubuntu_button/fixture
moon test --target native --deny-warn examples/macos_button
./script/build_macos_button.sh --build --target-dir "$RUN_DIR/build"
./script/build_macos_button.sh --e2e --target-dir "$RUN_DIR/e2e"
./script/build_macos_button.sh --run --target-dir "$RUN_DIR/gui"
./script/test_macos_button_ax.sh --adapter-only --target-dir "$RUN_DIR/mac-ax-adapter"
./script/test_macos_button_ax.sh --deadline-probe --target-dir "$RUN_DIR/mac-ax-deadline"
./script/test_macos_button_ax.sh --mutation-probes --target-dir "$RUN_DIR/mac-ax-mutations"
./script/test_macos_button_ax.sh --all --target-dir "$RUN_DIR/mac-ax"
```

The `--e2e` mode builds the native shim with `GPUI_TESTING`, launches with
`GPUI_NATIVE_E2E=1`, runs a bounded synthetic-input/readback scenario, and exits
after closing its windows. The regular `--run` mode is interactive and does
not enable native test hooks. Build outputs and the app bundle stay under the
selected target directory. The GUI displays the “Run action” label, activation
count, enabled/loading state, and keyboard help. It also prints the current
focus/hover/pressed state and activation count to `button.log`; a single
activation changes both the window text and the log. The printed process ID is
recorded in `button.pid` so a caller can close only the launched sample.

For the visible GUI check, press Tab to show focus, Enter to increment the
count once, then press Tab to remove focus. Focus again and hold Space to see
the pressed fill before release increments once. Try pointer click, D to
disable/re-enable, L to toggle loading, R to reset the count/state, resize below
the minimum viewport and restore it, then Escape to close. Read the same count
and state in the GUI log with `tail -f "$RUN_DIR/gui/button.log"`. Record this
manual native-input result separately from `--e2e` synthetic input/readback.

`--deadline-probe` compiles the external client and tests its monotonic
remaining-budget, per-IPC timeout, and bounded-sleep helpers without launching
the regular example bundle, creating a native window, or making AX calls.
`--all` runs that probe before its separate client lane. The client uses
separate 15-second discovery and owner-observation
budgets, with at most 250 ms per remote AX call and a 5 ms dispatch margin;
the 35-second process watchdog preserves the failure receipt/log and permits
the harness cleanup to run if a synchronous call still stalls.

Record model tests, AX adapter tests, the separately launched AXUIElement
client, native build/smoke, visible GUI input, and pixel readback as separate
PASS/FAIL/UNRUN results, with the exact source SHA and macOS, Xcode, SDK,
MoonBit, GPU, font, and display-scale profile. The Stage B result covers only
this sample button; it does not qualify VoiceOver, Japanese IME, other
platforms, or a macOS support tier.

## Current qualification status

The parent-pinned ActRun `run-1` passed five stages and 27 commands on
candidate `ff48b53bad4894788a8f90399bd4317a60a46fda`. An independent
gpt-6.1-sol/xhigh review completed three passes across seven perspectives with
zero blocking findings and two minor findings. The current source addresses
those findings; ActRun and independent review must be rerun on this update.
The latest external AX attempt on the prior candidate failed to discover an
AXWindow; the post-unlock client and regular GUI input/AX/pixel gates remain
blocked or unrun. Whole-task Green is false and no PR is published. Keep
Stage B open until the final-source desktop gates and fresh review pass.
