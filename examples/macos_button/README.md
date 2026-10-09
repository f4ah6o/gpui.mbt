# macOS reusable Button fixture — Stage A

This example exercises the existing portable `controls/button` model in the
AppKit/Metal host. The fixture owns the Button and its application activation
count; macOS supplies the window, event queue, CoreText/Metal scene renderer,
and an opt-in native smoke path.

Source: [Stage A child of issue 0024, captured at `4bf3afd56550862c20c56175da05c44159b4ce3b`](https://github.com/gpui-mbt/gpui.mbt/blob/4bf3afd56550862c20c56175da05c44159b4ce3b/issues/open/0024-apple-silicon-macos-button-integration.md).
Parent: [macOS native backend roadmap](../../issues/open/0006-macos-native-backend.md).

## Scope and dependencies

The implementation base is `48ca4ec0bc7862cbe3f4a6e6fc1f30af27fa3fa9`.
The reusable Button model and portable fixture are integrated from PR #47
(`4ee7bd48482db16fd6757265d7d1f3decd352bd7`). CoreText/Metal text rendering
and opt-in frame readback are integrated from PR #49
(`2c6e9a3df469922f79d7b2b8eb977a0524086486`, renderer slice
`816596187af35a8fcea3f6e7587df4f5ffed6532`). The current AppKit/Metal host
is already part of the base. Stage A does not depend on PR #40's text-field/IME
work, PR #42's documentation update, or the Stage B shared semantics/AX
contract.

Only this macOS example, its build/test support, its narrow architecture
contract registration and regression, this guide, and the changelog are in
scope. Do not change `controls/button`, the portable fixture, the shared
platform API, accessibility projection, other OS samples, or support-tier
claims. The model and Ubuntu fixture remain the source of portable state and
activation semantics.

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
  orderly cleanup. It is synthetic host-event and pixel evidence; it is not
  human-input, accessibility, or IME evidence.
- A separately launched GUI run is manually checked with Tab, Enter, Space,
  pointer input, state toggles, resize, and close. Report this separately from
  the synthetic smoke; do not claim it when the desktop is unavailable.

## Build, test, and run

On Apple Silicon macOS with the pinned repository toolchain:

```sh
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpui-macos-button.XXXXXX")"
moon fmt --check
moon test --target native --deny-warn controls/button
moon test --target native --deny-warn examples/ubuntu_button/fixture
moon test --target native --deny-warn examples/macos_button
./script/build_macos_button.sh --build --target-dir "$RUN_DIR/build"
./script/build_macos_button.sh --e2e --target-dir "$RUN_DIR/e2e"
./script/build_macos_button.sh --run --target-dir "$RUN_DIR/gui"
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

Record model tests, adapter tests, native build/smoke, and visible GUI input as
separate PASS/FAIL/UNRUN results, with the exact source SHA and macOS, Xcode,
SDK, MoonBit, GPU, font, and display-scale profile. Stage A does not qualify
native accessibility, Japanese IME, other platforms, or a macOS support tier.
