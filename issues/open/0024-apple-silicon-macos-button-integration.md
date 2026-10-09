# Apple Silicon macOS reusable Button integration and qualification

Status: open — fixture implementation and native acceptance pending\
Updated: 2026-10-09 (JST); inspected 2026-10-09 23:41 JST\
Parent: [Apple Silicon macOS backend](0006-macos-native-backend.md)\
Related: [palette and shared dependency handoff](0022-apple-silicon-macos-command-palette-parity.md)

## Ownership and exact inputs

The repository owner coordinates Apple Silicon macOS implementation and its native host.
The Linux/shared-component coordinator owns reusable Button corrections and the
common API. This issue does not authorize changes to another platform's scope
or promote a support tier.

Current main is `008b3c73d50108d6ed1e6c02ad9e12e930e843ec`.
[Button #47](https://github.com/gpui-mbt/gpui.mbt/pull/47) is merged as
`4ee7bd48482db16fd6757265d7d1f3decd352bd7`; the reusable Button is available
on current main. This merge supplies a shared control, not macOS fixture or
native-runtime qualification. Pin and revalidate the final integrated source
before claiming any platform acceptance; do not copy or fork the model.

This packet is arm64/Apple Silicon only. Button painting emits `TextItem`; the
bounded CoreText/Metal scene-text renderer from merged
[#49](https://github.com/gpui-mbt/gpui.mbt/pull/49), merge
`2c6e9a3df469922f79d7b2b8eb977a0524086486`, is available to the Button
fixture without waiting for [#40](https://github.com/gpui-mbt/gpui.mbt/pull/40).
#49 does not provide the palette field, AppKit ownership, or live Japanese IME
acceptance. Those separate palette gates remain in 0022; Button itself is not a
text editor and does not depend on Japanese IME completion.

## Stage A — reusable fixture and native runtime

Compose `controls/button` with the existing AppKit/Metal host, element routing,
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

## Stage B — shared semantics and AX projection

`docs/accessibility.md`, merged through [#48](https://github.com/gpui-mbt/gpui.mbt/pull/48),
defines the shared headless owner/generation, snapshot, action-validation, and
application-effect boundary. [#51](https://github.com/gpui-mbt/gpui.mbt/pull/51)
adds a fixture-specific Ubuntu projection, app-owned dispatch, and freshness
fence. It does not supply a general automatic Button action system or macOS AX,
Windows UIA, or AT-SPI adapter. A caller-owned Button `UInt64` remains a mapping
key, not a native AX identity.

The macOS fixture must map its role, name, bounds, focus/enabled/loading state,
and supported action to the existing contract; it must preserve live-target
validation and leave the application effect with its owner.

- [ ] Headless macOS vectors map button role/name/bounds/state and verify the
  shared owner, generation, snapshot, and stale-target rules.
- [ ] Fixture wiring conforms to the shared action/effect boundary without
  synthesizing physical input or treating an ActionIntent as an executor,
  one-shot token, or exactly-once capability.
- [ ] A real native AX client can observe the named control and request an
  allowed semantic action. Each accepted Invoke delivered by the client causes
  exactly one owner-side effect; disabled/loading/stale rejections cause zero.
  Repeated accepted requests are separate events; this checks the app dispatch
  path and does not imply framework-level deduplication.
- [ ] Semantic invocation, physical keyboard input, physical pointer input,
  application activation count and pixel presentation each have separate
  evidence and qualification results.
- [ ] Deliberately broken fixture regressions fail their corresponding checks;
  a visible label or successful semantic invoke cannot mask broken keyboard input.

The shared contract exists, but native AX support remains open until this
Apple-specific adapter and real-client acceptance pass. Linux AT-SPI completion
is not a prerequisite. Report unsupported native accessibility honestly.

## External conformance and handoff

Keep responsibilities distinct: gpui.mbt owns internal semantics and AX
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
