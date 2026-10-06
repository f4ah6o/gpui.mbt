# Windows command-palette integration and Japanese IME qualification

Status: open — follow-up; implementation and native acceptance pending  
Updated: 2026-10-07 (JST)  
Parent: [0008 Windows backend](0008-windows-native-backend.md)  
Related: [0020 command-palette milestone](0020-usable-command-palette-integration-milestone.md)

## Gap and dependencies

Windows has bounded DirectWrite/D3D11 text and a shared text-field fixture through
[PR #39](https://github.com/gpui-mbt/gpui.mbt/pull/39), merged as
`76f75f98c4da7449a1724c4f1352fbd30c852a79`. Its startup and renderer tests do
not qualify a command palette or real Japanese IME interaction.

[PR #41](https://github.com/gpui-mbt/gpui.mbt/pull/41), inspected at
`e51dd6c97d75824ca565ad383ab698d86e0348d4`, supplies the reusable palette and
focus contracts but only a Linux native fixture. It is open; this reference is
not an accepted dependency pin or a claim that it has merged. Recheck its final
reviewed contract and integration with current main before implementation.

The broad backend roadmap remains in 0008. This packet owns the missing
Windows application interaction, not another picker, registry or editing model.

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
