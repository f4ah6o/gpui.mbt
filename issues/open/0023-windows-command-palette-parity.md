# Windows command-palette integration and Japanese IME qualification

Status: open — follow-up; implementation and native acceptance pending  
Updated: 2026-10-08 (JST)  
Parent: [0008 Windows backend](0008-windows-native-backend.md)  
Related: [0020 command-palette milestone](0020-usable-command-palette-integration-milestone.md)

## Gap and dependencies

Windows has bounded DirectWrite/D3D11 text and a shared text-field fixture through
[PR #39](https://github.com/gpui-mbt/gpui.mbt/pull/39), merged as
`76f75f98c4da7449a1724c4f1352fbd30c852a79`. Its startup and renderer tests do
not qualify a command palette or real Japanese IME interaction.

[PR #41](https://github.com/gpui-mbt/gpui.mbt/pull/41) is merged as
`72d89475894e14f3fea9a3407e12a640da356ed9` (tested source
`ab8d33019a717f6f340c6836e2d83be34e2f4b1c`; recheck the full final source identity before implementation).
Current main `87d3e46ff35429ad747595f312798aec429ddcce` contains the reusable
palette/focus contracts. Its portable package imports contain no Wayland/Pango
dependency; waiting for Linux #41 to merge is no longer a blocker. Its Linux
native fixture and qualification are evidence for that declared profile only.

Windows integration can start now from current main; additional Linux
qualification is not a prerequisite. The broad backend roadmap remains in 0008. This packet owns the missing
Windows application interaction, not another picker, registry or editing model.

## Coordination and dependency boundaries — inspected 2026-10-08 16:20 JST

Linux/shared-component work is coordinated here; the repository owner coordinates
macOS and Windows implementation and their native hosts. Report blockers by the
specific missing contract, implementation, or test environment, rather than by
an entire operating system being unfinished.

| Work | Current shared input | May start independently | Completion dependency |
| --- | --- | --- | --- |
| Windows palette | Main `87d3e46ff35429ad747595f312798aec429ddcce` includes Windows field #39 and shared palette #41 | Compose the existing Windows fixture and shared model now | Windows-owned input, presentation, IME and lifecycle qualification below |
| Apple Silicon palette | Shared palette #41 is merged; macOS field/renderer remain in open #40 | Shared-owner tests and integration design now | Final reviewed #40 field/CoreText/Metal/AppKit ownership slice plus actual arm64 native acceptance |
| Windows Button | Draft [#47](https://github.com/gpui-mbt/gpui.mbt/pull/47), head `c9fefddaf0e925c9a20bdab10496e569e9652c95` | Stack on that exact reviewed source and existing main Windows text renderer | [0025 Windows Button](0025-windows-button-integration.md); recheck/reconcile final #47 before landing |
| Apple Silicon Button | Same draft #47 | Portable tests and adapter design now; Button itself has no IME dependency | [0024 macOS Button](0024-apple-silicon-macos-button-integration.md); #40's TextItem-capable CoreText/Metal renderer slice, not completion of Japanese IME |
| Native accessibility | Portable palette semantics are copied DTOs; a shared generational tree/action contract is a design goal, not an existing bridge | OS role/action/coordinate mapping and headless test vectors | Agree one shared tree/action identity and lifetime contract before independently implementing native bridges |

The Windows clipboard fixture in [#44](https://github.com/gpui-mbt/gpui.mbt/pull/44)
is not a prerequisite for these palette/Button slices. Linux AT-SPI and
[vlmkit Linux observer #7](https://github.com/f4ah6o/vlmkit/pull/7) are not
prerequisites for macOS AX or Windows UIA work. gpui.mbt fixture work is distinct
from vlmkit driver qualification: this packet does not remove the separate
Windows-driver scheduling gate in
[vlmkit #6](https://github.com/f4ah6o/vlmkit/pull/6), inspected at
`489d784a31ac86f657807890150e0cd77b9e4c70`.

Linux is not globally complete. The bounded field profile in merged
[#36](https://github.com/gpui-mbt/gpui.mbt/pull/36), merge
`2de439f38682dfb55ae0f59864824f37a7017c20`, qualifies Weston 14/text-input-v1
with synchronous IBus/Mozc. Merged #41 records the bounded standalone palette
profile's 20 checkpoints/81 presentations. Neither result admits all Linux
compositors, input paths, accessibility, or MZed behavior. Historical roadmap
statements about an open #30 or wholly unimplemented Japanese IME are not the
current dependency basis.

The future shared tree/action contract must define generation/ownership, reset
and ID reuse, loading/disabled state and semantic activation; caller-owned
Button `UInt64` IDs are not native AX/UIA identities. gpui.mbt internal semantics,
vlmkit NDJSON/`vlmkit-a11y/1`, and
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
qualify another OS. Stacked #47 work must recheck the reviewed final source when
#47 changes or merges. Report incompatible shared contracts back to the
Linux/shared coordinator instead of duplicating the model or silently widening
platform claims.

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
