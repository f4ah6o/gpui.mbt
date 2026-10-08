# Apple Silicon macOS command-palette integration and Japanese IME qualification

Status: open — follow-up; implementation and native acceptance pending  
Updated: 2026-10-08 (JST)  
Parent: [0006 macOS backend](0006-macos-native-backend.md)  
Related: [0020 command-palette milestone](0020-usable-command-palette-integration-milestone.md)

## Gap and dependencies

This packet is **Apple Silicon / arm64 only**. Intel macOS is outside its scope.

[PR #40](https://github.com/gpui-mbt/gpui.mbt/pull/40), inspected current head
`7232061f83769214843a2ccfa18f1e1a4d989031`, provides the experimental
CoreText/Metal field and default-off AppKit composition path. It remains open;
complete final-source live input acceptance remains a prerequisite. The
[latest #40 review](https://github.com/gpui-mbt/gpui.mbt/pull/40#pullrequestreview-5435161619)
retains blur/final-frame and Busy-owner findings. The
[latest #45 evidence](https://github.com/gpui-mbt/gpui.mbt/pull/45#issuecomment-6037836499)
records Return key delivery, but no subsequent `insertText`/`unmarkText`
callback before timeout; it does not establish an ACK-wait cause or a passing
IME result. [#46](https://github.com/gpui-mbt/gpui.mbt/pull/46) records
build-entrypoint success only, not runtime acceptance. Resolve and
revalidate its existing field/runner review findings there, rather than opening
duplicate defect packets here.

[PR #41](https://github.com/gpui-mbt/gpui.mbt/pull/41) is merged as
`72d89475894e14f3fea9a3407e12a640da356ed9` (tested source
`ab8d33019a717f6f340c6836e2d83be34e2f4b1c`; recheck the full final source identity before implementation).
Current main `87d3e46ff35429ad747595f312798aec429ddcce` contains the reusable
palette/focus contracts. Its portable package imports contain no Wayland/Pango
dependency; waiting for Linux #41 to merge is no longer a blocker. Its Linux
native fixture and qualification are evidence for that declared profile only.

0006 owns the general backend gates. This packet owns the missing macOS palette
interaction rather than another widget system or copies of the Linux fixture.

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
