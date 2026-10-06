# Apple Silicon macOS command-palette integration and Japanese IME qualification

Status: open — follow-up; implementation and native acceptance pending  
Updated: 2026-10-07 (JST)  
Parent: [0006 macOS backend](0006-macos-native-backend.md)  
Related: [0020 command-palette milestone](0020-usable-command-palette-integration-milestone.md)

## Gap and dependencies

This packet is **Apple Silicon / arm64 only**. Intel macOS is outside its scope.

[PR #40](https://github.com/gpui-mbt/gpui.mbt/pull/40), inspected current head
`c76079cd4608a5d53e9b902862d518191f054b15`, provides the experimental
CoreText/Metal field and default-off AppKit composition path. It remains open;
complete final-source live input acceptance is a prerequisite. Resolve and
revalidate its existing field/runner review findings there, rather than opening
duplicate defect packets here.

[PR #41](https://github.com/gpui-mbt/gpui.mbt/pull/41), inspected at
`e51dd6c97d75824ca565ad383ab698d86e0348d4`, provides reusable palette/focus
contracts and a Linux-only native fixture. It remains open. Neither candidate
head is an accepted integration pin; recheck final reviewed sources and current
main before implementation.

0006 owns the general backend gates. This packet owns the missing macOS palette
interaction rather than another widget system or copies of the Linux fixture.

## Scope

- Compose the shared palette with the existing macOS field/provider and AppKit
  host. Publish the logical-opener mapping, such as Command+K.
- Preserve 128 commands/eight rows, bounded metadata/query, committed-only
  filtering, enabled navigation, live availability checks, one-shot activation
  and portable semantics.
- Join palette open epochs with window/host/session/batch identities and the
  acknowledged field revision. Keep the live ElementTree; epoch-check delayed
  edits and acknowledge each applied batch before further native dispatch.
- Reuse AppKit resolved committed text and default-off
  `GPUI_FIELD_MACOS_IME=1` composition. Successfully fence ownership before
  `finish_close`, activation and restoration; a failed fence cannot dispatch.
- Quarantine closing/cancelling presses and releases across blur/reopen. Guard
  retirement requires verified fresh ownership and old-record revocation.
  Busy retains the whole prepared state; hard frame rejection fails closed.

## Acceptance

- [ ] Final integrated arm64 sources build a native palette app and complete
  open/search/navigate/activate/cancel/reopen in one owned window.
- [ ] Shared/macOS owner tests cover bounds, disabled/empty results, stale
  batches/epochs, held/repeated keys, one-shot/reentrant actions and removed/
  reused prior focus owners.
- [ ] Actual Kotoeri preedit/conversion/commit occurs in search. Direct text
  installation and logs do not count as IME evidence. Preedit does not refilter;
  composition Enter cannot activate; Escape cancels before a later dismissal.
- [ ] Blur/close fence the session and reopen starts fresh. Native counters prove
  one activation, no closing press/release leakage, safe focus restoration and
  subsequent background usability.
- [ ] Accepted frame identifiers correlate with actual native presentation and
  screenshots. Check search/caret, active/disabled rows, scrolling and clipping
  with correct logical/backing-pixel coordinates.
- [ ] The live runner completes blur/teardown before success, restores the
  previous app-context input source and retains bounded success/failure cleanup.
- [ ] Pinned local actrun checks pass on the exact final source. Record arm64
  architecture, actual macOS/Xcode/SDK, Metal device, fonts, source/binary/tool
  identities and distinct model/input/pixel/semantic results.

The inspected PR #40 profile is macOS 26.5.2 arm64, Xcode 26.6 and SDK 26.5;
revalidate the chosen profile rather than claiming all Apple Silicon versions.
Live acceptance requires an unlocked logged-in desktop and the declared Kotoeri
source; report environment/permission blockers distinctly.

Native AX transport and candidate-window contents/highlight remain UNSUPPORTED
or UNRUN unless independently qualified. Intel, general rich text/IME/display,
MZed and production support are excluded. Close only on reproducible complete-
flow evidence; no support tier or release gate is promoted.
