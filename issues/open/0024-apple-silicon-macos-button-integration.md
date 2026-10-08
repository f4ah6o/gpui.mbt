# Apple Silicon macOS reusable Button integration and qualification

Status: open — fixture implementation and native acceptance pending  
Updated: 2026-10-08 (JST); inspected 2026-10-08 16:20 JST  
Parent: [Apple Silicon macOS backend](0006-macos-native-backend.md)  
Related: [palette and shared dependency handoff](0022-apple-silicon-macos-command-palette-parity.md)

## Ownership and exact inputs

The repository owner coordinates Apple Silicon macOS implementation and its native host.
The Linux/shared-component coordinator owns reusable Button corrections and the
common API. This issue does not authorize changes to another platform's scope
or promote a support tier.

Current main is `87d3e46ff35429ad747595f312798aec429ddcce`.
[Button #47](https://github.com/gpui-mbt/gpui.mbt/pull/47) is **draft/open**, head
`c9fefddaf0e925c9a20bdab10496e569e9652c95`, tree
`51158f54771fabf31c258f7f6775dec1b2243613`. Its reviewed portable model/paint
and Ubuntu fixture passed 19 tests on each of four targets and a native build
with generated-C warnings. No Ubuntu window was launched; this is not live
input, pixel, accessibility, or other-OS qualification. It has not merged.

Stacking work on that exact reviewed source is possible now. Final acceptance
must recheck and pin the final reviewed integrated source, not just this snapshot. Record the pin and
reconcile changes before landing when #47 changes or merges. Do not copy or fork
the model into an OS widget implementation.

This packet is arm64/Apple Silicon only. Button painting emits `TextItem`,
so the macOS example needs the CoreText/Metal text-rendering slice currently in
open [#40](https://github.com/gpui-mbt/gpui.mbt/pull/40), head
`7232061f83769214843a2ccfa18f1e1a4d989031`. Start portable tests and adapter
planning now; native rendering depends on that reviewed compatible slice.
Button is not a text editor and does not depend on Japanese IME completion.
The palette's AppKit field/ownership/IME gates remain in 0022, separately.

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

`docs/platform.md` describes a future generational NodeId/tree/action model;
it is not an implemented common native accessibility tree. Palette semantics
are copied DTOs, and #47 Button has neither native accessibility nor semantic
activation. A Button's caller-owned `UInt64` is not a native AX identity.

OS role/name/state/action/coordinate mapping and headless vectors can begin now.
Before native bridge implementation, agree one shared tree/action contract with
the Linux/shared coordinator: ownership/generation, reset/reuse/removal,
focus, loading versus disabled state, semantic activation, and stale-target
rejection. Do not independently invent incompatible AX and other-OS trees.

- [ ] Headless vectors describe button role, name, bounds, focused/enabled/loading
  states, supported action, generation changes and stale/reused ID rejection.
- [ ] The approved shared tree/action contract defines semantic activation and
  its application-effect boundary; mapping does not synthesize physical input.
- [ ] A real native AX client can observe the named control and invoke an
  allowed semantic action once; disabled/loading/stale targets fail closed.
- [ ] Semantic invocation, physical keyboard input, physical pointer input,
  application activation count and pixel presentation each have separate
  evidence and qualification results.
- [ ] Deliberately broken fixtures/regressions fail the corresponding checks;
  a visible label or successful semantic invoke cannot mask broken keyboard input.

The native bridge depends on the shared contract, not completion of Linux AT-SPI.
Report unsupported native accessibility honestly until this stage passes.

## External conformance and handoff

Keep responsibilities distinct: gpui.mbt owns internal semantics and AX
projection; vlmkit owns NDJSON transport and `vlmkit-a11y/1` observation/action
contracts; Yami owns scenario-level conformance evidence. Follow the current
[Yami web/native conformance packet](https://github.com/f4ah6o/Yami-kumo/blob/772ab942fa94443cc48b48472cd7fdc494b99018/issues/open/20261008-vlmkit-web-native-conformance.md),
whose order is macOS first. Recheck its final reviewed source before execution.

[vlmkit #2](https://github.com/f4ah6o/vlmkit/pull/2) remains draft at
`5583afe207456ca0d0a74ab0a85ac2c8a3fc6a96`, with unresolved live/safety gates;
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
