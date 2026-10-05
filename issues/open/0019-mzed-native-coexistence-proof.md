# MZed native coexistence proof

Status: open (planning only)
Parent: [0018-mzed-native-island-roadmap.md](0018-mzed-native-island-roadmap.md)
Related: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md), [0011-electron-tauri-migration.md](0011-electron-tauri-migration.md)
Updated: 2026-10-05

## Scope

Implement only after a separate implementation start decision. This packet
records the first proof for the roadmap; it does not resume 0016. Zed upstream
is read-only. All implementation changes, if approved, belong in MZed or the
appropriate independently authored framework/tool repository.

Linux is the first qualification environment; macOS follows. Preserve existing
Windows checks while deferring new Windows work under the parent roadmap.
Select and record the Zed source pin before the first build; the source pin and
gpui.mbt behavioral compatibility pin are separate review decisions.

## Outcome

A reproducibly built MZed baseline still performs its existing editor workflow while one bounded, optional gpui.mbt region is visible and interactive in the same application window. The region can be disabled without breaking the original workflow.

This is a native boundary experiment, not yet a migrated project tree. Use a small synthetic interaction that does not depend on unfinished text rendering. A second process or second window can establish a transport experiment, but does not satisfy the same-window island outcome.

## Work to investigate

1. Build and smoke-test the chosen unmodified Zed-derived baseline on the selected Linux environment. Record compositor, graphics stack, driver/backend, display scale and toolchain. Establish a basic file-open/edit/save workflow as the preservation fixture.
2. First exercise a small model/logic boundary inside the same application if useful to validate ownership and transport. This prerequisite does not count as a visual native island. Compare the minimum viable same-window boundaries: host-owned embedded surface, host-composited output, or a narrow native integration layer. Inspect the actual Rust GPUI and MoonBit native boundaries before choosing. Record ownership of the event loop, rendering resources, window, thread, scale conversion and destruction. Do not assume arbitrary Wayland client embedding or a stable Rust ABI.
3. Keep the Rust app authoritative. Pass copied/versioned state and commands through a narrow interface. No cross-runtime shared mutable entity graph, raw application objects or portable Rust/OS handles. Define limits, typed failure, request/scope identity, cancellation and stale-result rejection.
4. Give one runtime exclusive input ownership for each sequence. Define hit testing, focus acquisition/return, keyboard routing, modifier handling, wheel routing, visibility and clipping. The proof may declare text entry unsupported, but must not capture or corrupt editor IME sessions.
5. Keep a reversible runtime toggle or equivalent fallback path to the original UI. Verify fallback before describing the coexistence proof as successful.

## Acceptance evidence

- [ ] Clean build and baseline editor smoke at the chosen upstream pin.
- [ ] Same-window island shows a MoonBit-owned state change after a real targeted interaction.
- [ ] Logical bounds, resize, scale and clipping agree with the host, including partially hidden or zero-sized regions.
- [ ] Focus moves into and out of the region; one input sequence causes at most one action; the original editor works immediately afterward.
- [ ] Hide, close, destroy and remount are exercised repeatedly without orphaned handlers/resources.
- [ ] Late completions after teardown and duplicate/out-of-order replies are safely rejected.
- [ ] Failure injection produces actionable diagnostics and restores the original workflow.
- [ ] A bounded churn workload records resource growth and frame/input timing, with workload parameters, tolerances and stopping conditions declared before the run.
- [ ] Deterministic model/contract tests and an actual native integration run agree on state transitions.
- [ ] Artifacts identify software-rendered versus hardware-backed execution accurately.

A screenshot alone cannot pass lifecycle or state ownership gates. A software-rendered Weston/CI run can qualify correctness for that environment; it cannot establish general Linux hardware rendering performance or a production support tier.

## Go or fallback decision

Proceed to product slices only when same-window presentation, input ownership, teardown and original-editor preservation are demonstrated on the pinned environment.

Stop expansion and prepare a decision report if the narrow bridge requires uncontrolled coupling to both application runtimes, cannot safely route input or resources, breaks the baseline workflow, or cannot meet the declared workload bounds. First distinguish an unavailable test environment from an architectural failure.

Present these alternatives with measured consequences:

- Continue native work with a narrower host-owned surface/renderer contract, if evidence supports a tractable boundary.
- Retain Rust Zed UI and initially move selected non-UI behavior behind a tested MoonBit boundary. This is a revised migration order and needs approval.
- Build a separate hosted frontend. This is a larger product change and cannot be described as preserving Zed's native editor island; obtain approval first.

Do not make Electron/Tauri, a separate application window or a replacement editor the silent fallback.

## Dependencies and completion report

Use the roadmap's [supporting tools](0018-mzed-native-island-roadmap.md#supporting-tool-adoption),
Linux vlmkit admission criteria, source provenance policy and per-candidate
release evidence. Do not add an unmerged native-input PR as a trusted dependency.

The completion report must name the chosen integration, discarded alternatives,
exact source/tool revisions, target profile, baseline preservation result,
individual acceptance results, failure/recovery evidence and remaining blockers.
A failed architecture gate produces a fallback decision report, not an expanded
implementation. No software-rendered CI result is a general hardware performance
claim. No release or upstream contribution follows automatically from this proof.
