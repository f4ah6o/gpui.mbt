# Apple Silicon macOS reusable Button integration and qualification

Status: open
Model: gpt-6-luna
Created: 2026-10-08
Updated: 2026-10-10
Branch: feat/20261010-macos-button-ax
Parent: [Apple Silicon macOS backend](0006-macos-native-backend.md)\
Related: [palette and shared dependency handoff](0022-apple-silicon-macos-command-palette-parity.md)

## Ownership and exact inputs

The repository owner coordinates Apple Silicon macOS implementation and its native host.
The Linux/shared-component coordinator owns reusable Button corrections and the
common API. This issue does not authorize changes to another platform's scope
or promote a support tier.

Current main at the 2026-10-10 audit is
`691edaf5012a9ae032dfe5d7721544818873717d` (merged Stage A #52).
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

## 概要

Stage A was delivered by merged [PR #52](https://github.com/gpui-mbt/gpui.mbt/pull/52),
source `939be4ff3f31c91e98821ef55ac165461da52480`, merge/base
`691edaf5012a9ae032dfe5d7721544818873717d`. This implementation packet covers
Stage B for the existing Apple Silicon macOS Button example.

## 背景

The merged fixture already owns a shared accessibility snapshot and a live
`ActionRequest` validation/dispatch path. The Mac session currently uses its
input and painting APIs only. No native AX control is exposed by the example.

## 問題

A native accessibility client cannot independently identify or invoke the
rendered Button. A native adapter must not infer authority from key `42`,
retain MoonBit addresses in the dylib, replay an `ActionIntent`, or bypass
the application owner's live validation and effect path.

## 目標

Expose the example's bounded Button through AppKit AX, preserving the existing
shared owner/generation model. Distinguish semantic requests, OS keyboard and
pointer input, app activation counts, and accepted GPU frames in the evidence.

## 対象外

Shared Button/accessibility/fixture corrections, Linux/Windows code, generic
all-widget AX coverage, VoiceOver qualification, rich text, palette/IME,
multi-display admission, vlmkit/Yami transport, release and support promotion.
Do not take over open PR #40/#45/#46 or pending Linux PRs #53–#56.

## 提案する方針

- Consume the existing `ButtonDemo.accessibility_snapshot()` and
  `dispatch_accessibility_request()` APIs, keeping the complete opaque semantic
  identity in MoonBit. Native transport tokens are revocable bindings to that
  identity, never a caller-owned Button key or an executable capability.
- Add narrowly bounded Apple-only projection/transport in `platform/macos/`
  and wire `examples/macos_button/`. Keep all platform-neutral contracts and
  the reused Ubuntu fixture unchanged. The existing C ABI remains byte-based;
  no retained MoonBit pointers or reentrant MoonBit callbacks.
- Map Button role/name/logical bounds, focused/enabled/loading state, and
  Invoke to AppKit. Transform logical view bounds to AX screen coordinates
  using the owning window/view. Revoke bindings and pending work at removal,
  reset, close and host teardown; stale or unavailable requests cause no effect.
- Keep request admission bounded and owner-thread confined. Consume requests
  against current state immediately before one app-owned dispatch; separate
  accepted requests are separate events, with no deduplication claim.
- Reference [Apple NSAccessibilityElement](https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class)
  and the installed Xcode SDK declarations for native protocol mapping.
  Shared prerequisites #47/#48/#49/#51 and Stage A #52 are merged. PR #40,
  vlmkit #2/#6/#7 and Yami #3/#4 are not prerequisites for this bounded slice.

## 受け入れ条件

- [x] Mac vectors observe role/name/bounds/enabled/loading/focus from the
  shared snapshot; foreign owner, stale fixture copies, reset/removal/reopen,
  disabled/loading and close reject actions with zero owner-side effects.
- [ ] A real native AX client observes the named `Run action` control and its
  screen bounds/state/actions on final source, then two separate accepted
  Invokes cause exactly two app activations without synthetic physical input.
- [x] Native stale/disabled/loading requests have zero effects and teardown
  leaves no live native element or queued request that targets a later session.
- [x] Keyboard and pointer activation, accepted pixels/count updates, resizing
  and cleanup remain independently verified on the final Apple Silicon build.
- [x] Deliberately broken semantic/keyboard fixtures fail their relevant
  assertions; passing AX does not conceal an input regression.
- [ ] Required build/lint/test and pinned local ActRun pass on final source;
  independent gpt-6.1-sol/xhigh review has no blocking findings. Required native
  acceptance that cannot run is a blocker, never Green.

## テスト計画

Run `moon fmt --check`, `python3 tests/test_check_contracts.py`,
`python3 scripts/check_contracts.py`, `moon check --target all --deny-warn`,
native `moon test --deny-warn` for `accessibility`, `platform/macos`,
`controls/button`, `examples/ubuntu_button/fixture`, and `examples/macos_button`.
Use `./script/build_macos_button.sh --build --target-dir <evidence>/bundle`
and its `--e2e` mode for the retained GPU/input/lifecycle smoke. Add and run
the bounded native AX client/adapter regression commands documented by the
implementation. Include relevant portable Button/fixture targets, existing
`./script/test_macos.sh`, Bash syntax, contract tests and changelog guards.
The AX client also exposes `./script/test_macos_button_ax.sh --deadline-probe`
to exercise its monotonic remaining-budget, IPC-timeout and bounded-sleep
helpers without launching the regular example, creating a native window, or
making AX calls.

Run those required scoped gates under pinned local ActRun on the final source.
Perform a separately launched regular GUI check using native AX observation/
semantic invocation and OS keyboard/pointer actions. Record exact source/tree,
binary identities, macOS/Xcode/SDK/Moon/Metal/font/scale, commands, PASS/FAIL/
UNRUN/UNSUPPORTED per layer and bounded process cleanup. Japanese IME is not
required for a Button; human physical input and broad multi-display/VoiceOver
qualification remain separately UNRUN unless actually exercised.

## リスク

Native callback admission can precede owner consumption; the live model must
revalidate the request, especially after availability or identity changes.
AX logical/screen/backing coordinates must remain distinct. A queue must
fail closed when full, stale native objects must be revoked, and unavailable
desktop/AX permission must be reported as an environment blocker.

## 変更履歴

The bounded user-facing AX Button entry is recorded in `CHANGES.md` 0.3.0 after
the adapter and regression coverage were implemented. Do not broaden the
existing experimental macOS support claim.

## 注記

- 2026-10-10: Stage A is merged; Stage B is the sole new packet. This repo
  retains open/done/closed issue locations; keep this issue in `open` while
  broader acceptance remains. Existing local changes and peer work are
  preserved. No competing Mac AX branch/worktree/PR was found in the six-repo
  audit. Implementation base is `691edaf5012a9ae032dfe5d7721544818873717d`.
- 2026-10-10: The issue CLI reported pre-existing metadata/section violations.
  The scoped polish adds concrete fields and acceptance without deleting the
  existing Stage A/B handoff requirements. The implementation agent's runtime
  model identifier is `gpt-6-luna`.
- 2026-10-10: Stage B's Apple-only projection, shared-fixture binding, bounded
  owner queue, native adapter vectors, and mutation probes are implemented.
  The first real-client attempt exposed that the visible name was published
  only as `AXDescription`; adding the AppKit AX title mapping resolved that
  lookup, and two retained-bundle runs passed before the later session-suspend
  gate. On candidate `ff48b53`, the bounded client did not observe an AXWindow
  within 15 seconds. A test-only unique bundle ID and PID-to-bundle identity
  check were added; the client still saw only an AXApplication. CUA observed
  the Mac locked during this final attempt; this correlation does not establish
  the cause, and no unlock or permission change was made. The final native AX
  acceptance remains a blocker pending a user-unlocked rerun. Adapter, model,
  mutation, E2E, contract, and generated-interface results are in the task
  implementation report. The parent still owns final ActRun, visible GUI/input
  evidence, and independent review, so this issue remains open.
- 2026-10-10: The parent-pinned ActRun `run-1` passed all five stages and 27
  commands on candidate `ff48b53bad4894788a8f90399bd4317a60a46fda`. Independent
  gpt-6.1-sol/xhigh review completed three passes/seven perspectives, with zero
  blocking findings and two minor findings: numeric JSON coercion and missing
  wall-clock bounds in the separate AX client. The current update adds strict
  integer type/range checks and fractional/boolean/overflow vectors, plus
  monotonic discovery/owner deadlines, remaining-budget AX IPC timeouts, a
  desktop-independent deadline probe, and an owned-client watchdog retaining
  failure evidence. ActRun and independent review must run again on this
  updated source. The prior candidate's final-source AX client failed to find
  an AXWindow; the post-unlock client and regular GUI/input/AX/pixel checks
  remain blocked or unrun. Whole-task Green is false and no PR has been
  published. Keep the issue open.
- 2026-10-10: The two minor review findings are fixed in code commit
  `4ab16de6dae5ad73712e3e69b639994e2135dc05`. Pinned local ActRun `run-2`
  passed all five scoped stages/30 commands on that unchanged source: format,
  contracts, 107 Python tests, all-target warning-denied check, four-target
  Button/fixture tests, native Mac/semantics vectors, regular arm64 build,
  native synthetic input/frame/lifecycle E2E and existing Mac smoke, AX adapter,
  deliberate mutations, desktop-independent deadline and owned-child watchdog
  probes. This is local Apple M4/macOS 26.5.2 (25F84), Xcode 26.6 (17F113),
  SDK 26.5, Moon 0.1.20260920, Node 26.8.2 and ActRun 0.32.0; it is not the
  hosted CI matrix or regular desktop qualification.
- 2026-10-10: Independent `gpt-6.1-sol/xhigh` re-review completed three
  passes/seven perspectives on `4ab16de`: approve, zero findings, both
  previous minors resolved. Separate reviewer probes passed 35 numeric cases,
  mock AX IPC deadline/failure paths and watchdog TERM-to-KILL, completion,
  exited-PID and untouched-sentinel branches. The reviewer did not launch
  desktop apps or a real AX client.
- 2026-10-10: The final desktop inventory still explicitly reports the Mac
  locked. Real-client AX and regular GUI keyboard/pointer/AX/pixels on the
  repaired source are **UNRUN/BLOCKED**, not failed or Green. The previous
  `ff48b53` AX discovery attempt completed FAIL; the cause remains unproved
  and historical earlier passes do not qualify this final source. No push,
  draft PR or public SHA exists for Stage B. The hourly task's state/memory
  retain the source, evidence and blocker. Resume the same
  `feat/20261010-macos-button-ax` branch and dedicated
  `mac-button-ax-stage-b/gpui.mbt` worktree after manual unlock; do not pick a
  new issue. Run `script/test_macos_button_ax.sh --all --target-dir <evidence>`
  and the separate final regular-bundle OS input/pixel/lifecycle checks with
  exact source/binary receipts. Correct any failures, revalidate and re-review
  as needed, then refresh main/duplicate-work checks. Push/create a draft PR
  only when all required gates pass and blocking findings are absent. The
  issue stays in `issues/open`.
- 2026-10-10: After the user manually unlocked the Mac, the first updated
  external `--all` run failed before AX discovery at a one-shot
  `NSRunningApplication` PID/bundle-ID check (`post-unlock-ax`, app PID 96145,
  expected ID `org.gpui.mbt.macos-button.ax-test.p96056`). That old client
  logged no actual bundle ID or URL, so it does not establish which identity
  was observed. The harness/client now waits within the existing 15-second
  discovery deadline and still hard-rejects any wrong ID or standardized app
  bundle path. In `post-unlock-fix-v2/all`, PID 3126 published the exact
  expected ID and bundle path after seven observations (627.9 ms); the
  separately launched client (PID 3127) then verified the app-owned AXWindow,
  Run action Button, exact bounds/state/help, and two AXPress requests with
  owner count exactly two. Client and app both exited/reaped by the harness;
  receipt, client log, and binary are retained under
  `/Volumes/devstorage/.codex-validation/mac-button-ax-20261010T074823+0900/post-unlock-fix-v2/all/`.
  This demonstrates a real registration startup delay on the repaired run;
  the exact identity seen in the earlier failure remains unknown.
- 2026-10-10: Parent's separate regular production-bundle GUI run passed 19
  cases covering keyboard, pointer, enabled/loading state, reset, resize,
  AX removal/restoration, close/reopen, and cleanup. Its receipt is
  `RUN/post-unlock-gui.json`; its owned-production-binary receipt is retained
  in external `post-unlock-gui/receipt.json`. No production source was changed
  for the identity fix. The prior ActRun `run-2` and zero-finding independent
  re-review apply to commit `4ab16de`, before this harness/client update; run
  ActRun and independent review again on the current source. Whole-task Green
  remains false, no PR is published, and this issue remains open.

- 2026-10-10: The final focused repair run, `post-unlock-fix-v3/all`, also
  passed with app PID 3974/client PID 3975: exact PID, unique ID and resolved
  bundle path matched after six observations (522.7 ms); role/name/bounds/state
  and two app-owned semantic activations passed, and both processes were
  reaped. The 19-case GUI receipt uses unchanged production sources; only the
  external client, harness and qualification documentation changed afterward.
  The publication gate requires fresh ActRun including `--all`, exact-source
  equivalence receipts and independent review. Final per-SHA results and draft
  PR identity are recorded in the task's state/memory and PR body; this broad
  issue remains open for unfinished physical-input and external conformance
  qualification. Historical failures above are retained, not current passes.
- 2026-10-10: Catch-up candidate `99f4b91da65b9c0269f26815f20542c77250115d`
  merges current main `7ed8d677f1341e36c035371869f775d61c552020` and adds the
  focus-notification and bounded-cleanup review fixes. On this candidate,
  `bash script/test_macos_button_ax.sh --all --target-dir
  /tmp/gpui-mac-catchup-20261010/ax-all` failed: the separate client identified
  the exact app PID, bundle ID and path after seven observations (620.1 ms),
  then `AXWindows` returned `unavailable` with `app windows attribute missing`
  within 15 seconds. The client log and receipt are retained at
  `/tmp/gpui-mac-catchup-20261010/ax-all/client-89498-89406.log` and
  `/tmp/gpui-mac-catchup-20261010/ax-all/client-receipt.txt`; the receipt records
  client status 1 and app cleanup as `terminated-and-reaped`. An independent
  reviewer reproduced the same AXWindows failure on baseline merge `45e651a`;
  this comparison does not establish the cause. External AX acceptance on the
  catch-up candidate is FAIL/UNQUALIFIED, and visible GUI/VoiceOver checks on
  this candidate are UNRUN. Earlier post-unlock AX and GUI passes above apply to
  their recorded older revisions only.
- 2026-10-10: Bounded checks on candidate `99f4b91` passed: the AppKit adapter
  notification regression, `moon test --target native --deny-warn
  examples/macos_button` (10/10), `./script/build_macos_button.sh --build`,
  synthetic native `--e2e`, `moon fmt --check`, and 35 contract tests. The
  stopped app/client/watchdog cleanup probe passed twice against the same
  target directory, reaping the owned children within four and three seconds
  while leaving its unrelated sentinel alive. These checks do not replace the
  failed external AX lane or qualify a visible desktop run.
