# Windows command-palette integration and Japanese IME qualification

Status: open — Windows implementation is present in the candidate branch; physical-input and Japanese IME acceptance remain pending\
Updated: 2026-10-10 (JST)\
Parent: [0008 Windows backend](0008-windows-native-backend.md)\
Related: [0020 command-palette milestone](0020-usable-command-palette-integration-milestone.md)

## Gap and dependencies

Windows has bounded DirectWrite/D3D11 text and a shared text-field fixture through
[PR #39](https://github.com/gpui-mbt/gpui.mbt/pull/39), merged as
`76f75f98c4da7449a1724c4f1352fbd30c852a79`. Its startup and renderer tests do
not qualify a command palette or real Japanese IME interaction.

[PR #41](https://github.com/gpui-mbt/gpui.mbt/pull/41) and reusable Button
[#47](https://github.com/gpui-mbt/gpui.mbt/pull/47) are merged; their shared
components are available on current main. The shared headless accessibility
contract from [#48](https://github.com/gpui-mbt/gpui.mbt/pull/48) is documented
in [docs/accessibility.md](../../docs/accessibility.md). Current main is
`d8d7544662c31d6222580a0749b504d5f5e89b3f`, including merged
[#51](https://github.com/gpui-mbt/gpui.mbt/pull/51), which connects a headless
Ubuntu Button fixture to semantic projection and app-owned action dispatch.
That fixture-specific projection does not implement or qualify macOS AX,
Windows UIA, or Linux AT-SPI.

Windows integration can start now from current main; additional Linux
qualification is not a prerequisite. The broad backend roadmap remains in 0008. This packet owns the missing
Windows application interaction, not another picker, registry or editing model.

## Coordination and dependency boundaries — inspected 2026-10-09 23:41 JST

Linux/shared-component work is coordinated here; the repository owner coordinates
macOS and Windows implementation and their native hosts. Report blockers by the
specific missing contract, implementation, or test environment, rather than by
an entire operating system being unfinished.

| Work | Current shared input | May start independently | Completion dependency |
| --- | --- | --- | --- |
| Windows palette | Current main `d8d7544662c31d6222580a0749b504d5f5e89b3f` contains the shared palette and Button | Windows owner can compose and qualify the fixture on current main | Windows-owned input, presentation, IME and lifecycle qualification below |
| Apple Silicon palette | Shared palette #41 and scene-text renderer #49 are merged; the macOS field/ownership/live-IME work remains in draft #40 | Palette integration and tests can continue against the merged shared pieces | Final compatible #40 field/AppKit ownership slice plus actual arm64 input/IME acceptance; #49 does not close these gates |
| Windows Button | Shared Button #47 is merged as `4ee7bd48482db16fd6757265d7d1f3decd352bd7` | Integrate and qualify from current main | [0025 Windows Button](0025-windows-button-integration.md); exact-source Windows input, pixels, lifecycle and UIA gates remain |
| Apple Silicon Button | Shared Button #47 and bounded CoreText/Metal scene-text renderer #49 are merged | Button fixture can use the current main renderer without waiting for #40 | [0024 macOS Button](0024-apple-silicon-macos-button-integration.md); exact-source arm64 window/input/pixel acceptance remains |
| Native accessibility | #48 defines the shared headless tree/action contract; #51 adds an Ubuntu fixture projection and owner-side dispatch/freshness fence | OS role/name/state/action/coordinate mapping can begin against `docs/accessibility.md` | macOS AX and Windows UIA adapters/clients remain separate, unimplemented acceptance gates |

The Windows clipboard fixture in [#44](https://github.com/gpui-mbt/gpui.mbt/pull/44)
is not a prerequisite for these palette/Button slices. Linux AT-SPI and
[vlmkit Linux observer #7](https://github.com/f4ah6o/vlmkit/pull/7) are not
prerequisites for macOS AX or Windows UIA work. gpui.mbt fixture work is distinct
from vlmkit driver qualification: this packet does not remove the separate
Windows-driver scheduling gate in
[vlmkit #6](https://github.com/f4ah6o/vlmkit/pull/6), inspected at
`489d784a31ac86f657807890150e0cd77b9e4c70`.

### Latest Windows owner report — inspected 2026-10-09 23:30 JST

The [owner's update on #42](https://github.com/gpui-mbt/gpui.mbt/pull/42#issuecomment-6082405610)
reports an unpublished local Windows candidate based on main
`48ca4ec0bc7862cbe3f4a6e6fc1f30af27fa3fa9`: HEAD
`64d80fe21825ccce090e0c8157e1db303b8cfdd9`, tree
`279423857729f9654f2e9cf4d72b65117c3336b2`. Candidate preparation and its
independent source/bundle reviews were reported PASS with zero blocking findings;
this is preparation only, not Windows runtime acceptance. The broader Windows
Python suite reported 3 FAIL, 4 ERROR, and 1 SKIP out of 93, so it is not a
suite-wide pass. Native diagnostics ON/OFF, required native actrun, real
clipboard, GUI/Japanese IME, and the 12-image human and independent audits are
UNRUN. The candidate was not published. Current main later advanced through
#51 to `d8d7544662c31d6222580a0749b504d5f5e89b3f`; pin and qualify the exact
final integrated source after any source change. Do not reuse an old run as
acceptance for a changed source.

### Windows catch-up candidate — 2026-10-10

The Windows implementation is based on current main
`d8d7544662c31d6222580a0749b504d5f5e89b3f`. The candidate includes the bounded
palette host adapter, native command-frame/readback smoke, IME owner-thread
query bridge and input-ownership regressions. The Windows matrix and pinned
native/portable actrun profiles were rerun after rebasing; see the candidate's
retained `_build/windows-actrun/manifest.json` and per-step records for exact
source snapshot and tool identities.

`scripts/run_windows_command_palette_e2e.ps1 -Mode Validate` passes its harness
validation, but that mode does not launch the native interaction flow. Real
palette keyboard input, Japanese IME preedit/conversion/commit, candidate
placement, background-input recovery, pixel audit and GUI lifecycle remain
`UNRUN` or `BLOCKED` as identified by the retained per-check records. The
fixture remains open; no native-input or IME gate is claimed by startup/readback
smoke or portable model tests.

Linux is not globally complete. The bounded field profile in merged
[#36](https://github.com/gpui-mbt/gpui.mbt/pull/36), merge
`2de439f38682dfb55ae0f59864824f37a7017c20`, qualifies Weston 14/text-input-v1
with synchronous IBus/Mozc. Merged #41 records the bounded standalone palette
profile's 20 checkpoints/81 presentations. Neither result admits all Linux
compositors, input paths, accessibility, or MZed behavior. Historical roadmap
statements about an open #30 or wholly unimplemented Japanese IME are not the
current dependency basis.

The shared headless tree/action contract is implemented and documented in
[#48](https://github.com/gpui-mbt/gpui.mbt/pull/48) and
[docs/accessibility.md](../../docs/accessibility.md). It defines owner-scoped
IDs/generations, immutable snapshots, live action validation and the application
effect boundary. [#51](https://github.com/gpui-mbt/gpui.mbt/pull/51) connects an
Ubuntu Button fixture to that projection and adds fixture-owned stale-state
fencing; it does not implement a generic Button action system or a native AX,
UIA, or AT-SPI bridge. A caller-owned Button `UInt64` remains a mapping key,
not a native accessibility identity. gpui.mbt internal semantics, vlmkit
NDJSON/`vlmkit-a11y/1`, and
[Yami scenario conformance](https://github.com/f4ah6o/Yami-kumo/blob/772ab942fa94443cc48b48472cd7fdc494b99018/issues/open/20261008-vlmkit-web-native-conformance.md)
are distinct responsibilities. Semantic invocation, physical keyboard/pointer,
application activation count and accepted pixels require separate evidence,
including deliberately broken regression cases that FAIL. The Yami packet is
macOS-first; neither draft vlmkit #2's unresolved live/safety gates nor #7's
GTK/X11-only pass qualifies the gpui.mbt palette.

### Handoff and dependency release

Each OS owner reports: exact source/base SHA (and any stacked dependency SHA),
commands/test method, whether a real native runtime was exercised, the named
OS/toolchain/GPU/font/scale/input profile, PASS/FAIL/UNRUN/UNSUPPORTED per layer,
retained evidence, and remaining limits. Linux/shared work reports the same
fields when changing an upstream contract.

A dependency is released only by an identified reviewed source or a documented
compatible subset and its required evidence. A portable test pass does not
release native-input, pixel, IME, or accessibility gates; a Linux pass does not
qualify another OS. Pin each final integrated source and report its Windows
input, pixel, lifecycle, and UIA evidence separately. The merged shared Button
and headless accessibility foundation do not qualify Windows. Preserve the
separate Windows-driver scheduling gate and report incompatible shared-contract
findings to the Linux/shared coordinator instead of duplicating the model or
widening platform claims.

## Scope

- Compose `controls/command_palette` with the existing Windows field,
  ElementTree, ScrollState, SceneSnapshot and GuiBinding. Document the Windows
  opener, such as Ctrl+K.
- Preserve the shared bounds: 128 commands, eight visible rows, bounded
  IDs/labels/query, committed-only exact substring filtering, enabled navigation,
  live availability recheck and portable semantics.
- Join palette open epochs with window/field-owner/session epochs and ordered
  native sequences. Keep the live ElementTree through ordinary edits and use
  epoch-checked installation for delayed work.
- Reuse ordinary committed text and the default-off IMM32 session. Accepted IMM
  results commit immediately; subsequent preedit is a new transaction. Do not
  import Linux protocol assumptions.
- Fence native ownership before `finish_close`, activation and focus restoration.
  Fence failure cannot execute an action. Quarantine closing/cancelling key
  presses and releases; retire a guard only with verified fresh ownership and
  synchronous revocation of old-owner records.
- Busy retains the complete prepared palette state. Hard presentation rejection
  fails closed without a pending action or partial field/picker replay.

## Acceptance

- [ ] A final-source Windows build completes open/search/navigate/activate/cancel/
  reopen in one native window.
- [ ] Component/owner regressions cover bounds, disabled/empty results, stale
  epochs, held/repeated keys, one-shot/reentrant activation and removed/reused
  prior focus owners.
- [ ] Actual Japanese IME preedit/conversion/commit occurs in search; provisional
  text does not refilter. Composition Enter does not activate a command; Escape
  cancels composition before a later press dismisses.
- [ ] Blur/close fence old ownership; reopen is empty with fresh epochs. Native
  counters prove one activation, no closing press/release leak, correct focus
  restoration and a usable subsequent background key.
- [ ] Accepted frames correlate with GPU completion and retained pixels for
  search/caret, active/disabled rows, scrolling and clipping at declared density.
  State/startup logs alone are not pixel evidence.
- [ ] Candidate geometry follows the search caret. Candidate-window
  contents/highlight remain UNRUN unless independently qualified.
- [ ] Pinned local Windows actrun/native checks pass on the integrated source.
  Retain commands, source/binary/tool/font/OS/DPI/GPU identities and cleanup.
  Report model, native input, pixels and portable semantics separately.

UI Automation transport remains UNSUPPORTED until its own gate passes. General
IME/display/multi-window, MZed and production support are outside this packet.
Close only on reproducible complete-flow evidence for the declared Windows
profile; no public capability, support tier or release gate is promoted.
