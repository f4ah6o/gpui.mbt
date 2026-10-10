# Windows reusable Button integration and qualification

Status: open — fixture and completed-frame smoke are implemented; physical input and lifecycle acceptance remain pending\
Updated: 2026-10-10 (JST)\
Parent: [Windows backend](0008-windows-native-backend.md)\
Related: [palette and shared dependency handoff](0023-windows-command-palette-parity.md)

## Ownership and exact inputs

The repository owner coordinates Windows implementation and its native host.
The Linux/shared-component coordinator owns reusable Button corrections and the
common API. This issue does not authorize changes to another platform's scope
or promote a support tier.

Current main is `d8d7544662c31d6222580a0749b504d5f5e89b3f` (includes macOS catch-up #59).
[Button #47](https://github.com/gpui-mbt/gpui.mbt/pull/47) is merged as
`4ee7bd48482db16fd6757265d7d1f3decd352bd7`; the reusable Button is available
on current main. This merge supplies a shared control, not a Windows fixture or
native-runtime qualification. Pin and revalidate the final integrated source
before claiming any platform acceptance; do not copy or fork the model.

The existing main Windows field/text-rendering path from merged
[#39](https://github.com/gpui-mbt/gpui.mbt/pull/39) is the host/rendering basis.
Integrate the fixture from current main; no additional Linux renderer,
Wayland/IME work, or Windows clipboard fixture #44 is a prerequisite. Use native
Windows event and DPI contracts; do not copy Ubuntu host assumptions.

## Stage A — reusable fixture and native runtime

Compose `controls/button` with the existing Win32/D3D11 host, element routing,
scene and text renderer. Keep application effects and activation counting with
the fixture owner. Exercise enabled, disabled, loading, hover, focused and pressed
states, keyboard Tab/Enter/Space, pointer press/release, and cancellation.

- [ ] Relevant portable checks and tests pass on the exact integrated source.
- [ ] A real native window presents the button and label with logical/backing
  coordinates, text baseline, clipping, focus and state rendering verified.
- [ ] Each accepted pointer/keyboard gesture causes exactly one application
  action. Repeated keydown, unmatched release and duplicate events do not repeat it.
- [ ] Disable/loading changes, blur, removal, close/reopen, reset and resize
  cancel stale presses. Same-value enabled updates preserve synchronized focus.
- [ ] Positive undersized resize hides/removes the hit target and uses current
  viewport size; invalid/zero dimensions suspend presentation and stale input.
  Restoring valid dimensions does not replay an earlier activation.
- [ ] Native input, focus/window lifecycle, render completion and cleanup are
  measured on a named OS/toolchain/GPU/font/scale profile. State logs alone do
  not count as pixel or physical-input evidence.

Stage A is independently deliverable. It is not blocked on Linux AT-SPI or an
external automation driver, and passing it does not imply Stage B is complete.

### Windows catch-up candidate evidence — 2026-10-10

The candidate branch rebases on the current main above and adds
`examples/windows_button/`, which composes `controls/button/` with the shared
`examples/ubuntu_button/fixture/` rather than copying either model. The
portable Windows adapter suite passes 6 tests and the shared fixture passes 16.
The native D3D11 smoke completed a 640 × 240 frame at scale 1.0, read back the
finished frame, and sampled the background `[24,28,36,255]`, enabled Button
fill `[42,71,101,255]`, 183 bright label pixels and 279 status-text pixels.
The observed host was Windows 11 Pro build 26200, x64, MSVC 19.44.35214.0,
MoonBit `0.10.14+7d59c7ec9`, a 3440 × 1440 desktop and NVIDIA GeForce RTX 2060
SUPER. The test did not record hardware-versus-WARP selection.

The visible `SendInput` runner compiled but its preflight returned `BLOCKED`:
`OpenInputDesktop` failed with Win32 error 5 and no foreground window was
available. Physical keyboard/pointer gestures, GUI lifecycle, resize/close/reopen
acceptance and UI Automation are `UNRUN` or unsupported; this does not complete
Stage A. Japanese IME remains `UNRUN`. See the [Button guide](../../docs/windows-button.md)
for the runnable gate and retained evidence path. The exact post-rebase source
and actrun records are pinned in the final candidate update before merge.

## Stage B — shared semantics and UIA projection

`docs/accessibility.md`, merged through [#48](https://github.com/gpui-mbt/gpui.mbt/pull/48),
defines the shared headless owner/generation, snapshot, action-validation, and
application-effect boundary. [#51](https://github.com/gpui-mbt/gpui.mbt/pull/51)
adds a fixture-specific Ubuntu projection, app-owned dispatch, and freshness
fence. It does not supply a general automatic Button action system or macOS AX,
Windows UIA, or AT-SPI adapter. A caller-owned Button `UInt64` remains a mapping
key, not a native UIA identity.

The Windows fixture must map its role, name, bounds, focus/enabled/loading state,
and supported action to the existing contract; it must preserve live-target
validation and leave the application effect with its owner.

- [ ] Headless Windows vectors map button role/name/bounds/state and verify the
  shared owner, generation, snapshot, and stale-target rules.
- [ ] Fixture wiring conforms to the shared action/effect boundary without
  synthesizing physical input or treating an ActionIntent as an executor,
  one-shot token, or exactly-once capability.
- [ ] A real native UIA client can observe the named control and request an
  allowed semantic action. Each accepted Invoke delivered by the client causes
  exactly one owner-side effect; disabled/loading/stale rejections cause zero.
  Repeated accepted requests are separate events; this checks the app dispatch
  path and does not imply framework-level deduplication.
- [ ] Semantic invocation, physical keyboard input, physical pointer input,
  application activation count and pixel presentation each have separate
  evidence and qualification results.
- [ ] Deliberately broken fixture regressions fail their corresponding checks;
  a visible label or successful semantic invoke cannot mask broken keyboard input.

The shared contract exists, but native UIA support remains open until this
Windows-specific adapter and real-client acceptance pass. Linux AT-SPI completion
is not a prerequisite. Report unsupported native accessibility honestly.

## External conformance and handoff

Keep responsibilities distinct: gpui.mbt owns internal semantics and UIA
projection; vlmkit owns NDJSON transport and `vlmkit-a11y/1` observation/action
contracts; Yami owns scenario-level conformance evidence. Follow the current
[Yami web/native conformance packet](https://github.com/f4ah6o/Yami-kumo/blob/772ab942fa94443cc48b48472cd7fdc494b99018/issues/open/20261008-vlmkit-web-native-conformance.md),
whose order is macOS first. Recheck its final reviewed source before execution.

[vlmkit #2](https://github.com/f4ah6o/vlmkit/pull/2) remains open/draft at
current head `8a6ada8e0609a36b189032e6ca3b222a1fd4f187` (verified 2026-10-09).
Its PR body reports the Linux live scan-to-judge lane as UNRUN and macOS,
real-GPUI, and multi-display acceptance plus additional qualification gates as
unresolved;
[#7](https://github.com/f4ah6o/vlmkit/pull/7) qualifies only the named GTK/X11
observer profile. Neither is acceptance of this gpui.mbt fixture. The separate
Windows-driver scheduling gate in [vlmkit #6](https://github.com/f4ah6o/vlmkit/pull/6),
inspected at `489d784a31ac86f657807890150e0cd77b9e4c70`, remains in force; preparing this OS fixture does not remove it.

Report exact source/base/dependency SHAs, commands/test method, actual native
runtime exercised (or UNRUN), OS/toolchain/GPU/font/scale profile, evidence and
cleanup, and PASS/FAIL/UNRUN/UNSUPPORTED separately for model, input, pixels and
semantics. State which dependency the result releases and which remain. Send
shared-contract incompatibilities back to the Linux/shared coordinator.

Close only when the claimed bounded stages have reproducible evidence; keep
unfinished stages explicitly open. No production support, broad platform parity,
IME, MZed integration, merge, or release is implied.
