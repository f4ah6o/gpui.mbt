# Apple Silicon macOS command-palette integration and Japanese IME qualification

Status: open — follow-up; implementation and native acceptance pending\
Updated: 2026-10-09 (JST)\
Parent: [0006 macOS backend](0006-macos-native-backend.md)\
Related: [0020 command-palette milestone](0020-usable-command-palette-integration-milestone.md)

## Gap and dependencies

This packet is **Apple Silicon / arm64 only**. Intel macOS is outside its scope.

[PR #40](https://github.com/gpui-mbt/gpui.mbt/pull/40), inspected at current head
`7232061f83769214843a2ccfa18f1e1a4d989031`, retains the experimental macOS
field/provider, AppKit ownership, and default-off composition/IME path. The
bounded scene-text renderer is separately available from merged #49. PR #40
remains open; complete final-source live input acceptance remains a prerequisite. The
[latest #40 review](https://github.com/gpui-mbt/gpui.mbt/pull/40#pullrequestreview-5435161619)
retains blur/final-frame and Busy-owner findings. The
[latest #45 evidence](https://github.com/gpui-mbt/gpui.mbt/pull/45#issuecomment-6037836499)
records Return key delivery, but no subsequent `insertText`/`unmarkText`
callback before timeout; it does not establish an ACK-wait cause or a passing
IME result. [#46](https://github.com/gpui-mbt/gpui.mbt/pull/46) records
build-entrypoint success only, not runtime acceptance. Resolve and
revalidate its existing field/runner review findings there, rather than opening
duplicate defect packets here.

[PR #41](https://github.com/gpui-mbt/gpui.mbt/pull/41) and reusable Button
[#47](https://github.com/gpui-mbt/gpui.mbt/pull/47) are merged; their shared
components are available on current main. The shared headless accessibility
contract from [#48](https://github.com/gpui-mbt/gpui.mbt/pull/48) is documented
in [docs/accessibility.md](../../docs/accessibility.md). Current main is
`008b3c73d50108d6ed1e6c02ad9e12e930e843ec`, including merged
[#51](https://github.com/gpui-mbt/gpui.mbt/pull/51), which connects a headless
Ubuntu Button fixture to semantic projection and app-owned action dispatch.
That fixture-specific projection does not implement or qualify macOS AX,
Windows UIA, or Linux AT-SPI.

0006 owns the general backend gates. This packet owns the missing macOS palette
interaction rather than another widget system or copies of the Linux fixture.

## Coordination and dependency boundaries — inspected 2026-10-09 23:41 JST

Linux/shared-component work is coordinated here; the repository owner coordinates
macOS and Windows implementation and their native hosts. Report blockers by the
specific missing contract, implementation, or test environment, rather than by
an entire operating system being unfinished.

| Work | Current shared input | May start independently | Completion dependency |
| --- | --- | --- | --- |
| Windows palette | Current main `008b3c73d50108d6ed1e6c02ad9e12e930e843ec` contains the shared palette and Button | Windows owner can compose and qualify the fixture on current main | Windows-owned input, presentation, IME and lifecycle qualification below |
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
qualify another OS. Pin each final integrated source and report its OS/toolchain,
input, pixel, lifecycle, and accessibility evidence separately. The merged
shared Button and headless accessibility foundation do not qualify macOS. Keep
the open #40 palette-field/AppKit ownership and live-IME gates distinct from
#49 scene-text support and from Button fixture acceptance. Report incompatible
shared-contract findings to the Linux/shared coordinator instead of duplicating
the model or widening platform claims.

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
