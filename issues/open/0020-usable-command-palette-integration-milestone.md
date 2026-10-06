# Proposal: usable command-palette integration milestone

Status: open (proposal)
Updated: 2026-10-06
Related: [0018 MZed native island migration roadmap](0018-mzed-native-island-roadmap.md), [0019 MZed native coexistence proof](0019-mzed-native-coexistence-proof.md)

## Motivation

gpui.mbt has moved beyond isolated rendering proofs. The current framework has deterministic app/entity state, layout and input routing, bounded Linux text rendering, a reusable experimental single-line field, undo/redo, portable composition transactions, and a default-off qualified Ubuntu Japanese IME profile. MZed has also demonstrated a bounded MoonBit/gpui.mbt island inside the original editor window.

The next useful milestone should therefore be measured by an end-to-end application interaction rather than by adding another isolated primitive: build a small reusable command palette on Linux, qualify it as a gpui.mbt component composition, and then use it as the next meaningful MZed migration unit.

This proposal does not claim that gpui.mbt, Linux text, IME, accessibility, or MZed is production-ready. Existing support and evidence boundaries remain unchanged.

## Goal

A user can complete this flow using reusable gpui.mbt components on the declared Linux qualification profile:

1. Open a command palette.
2. Focus its search field.
3. Enter and compose Japanese text through the qualified native IME path.
4. Filter a bounded collection of commands.
5. Move the active selection with the keyboard.
6. Activate the selected command.
7. Close or cancel the palette.
8. Restore focus to the prior owner without leaking the closing key/action to the background UI.

After the standalone fixture is qualified, integrate the same reusable palette/component boundary into MZed as the next application-level island milestone, subject to the MZed admission gate below.

## Why this milestone

This joins capabilities that are currently proven mostly in separate slices:

- text measurement, rendering, caret and selection;
- composition/commit/cancel and bounded history;
- focused keyboard routing and native IME ownership;
- reusable list/picker behavior;
- semantic command actions;
- focus containment and restoration;
- bounded collection work;
- application integration in MZed.

Passing this flow is stronger evidence of practical framework usefulness than another standalone renderer or input fixture, while remaining much smaller than attempting to port an editor.

## Scope

### Framework

Add the smallest reusable pieces needed for a command palette:

- a bounded picker/list model with explicit active selection;
- deterministic filtering over copied command metadata;
- keyboard navigation and activation;
- a reusable composition of the existing text field with the picker/list;
- explicit modal focus ownership, dismissal, and focus restoration;
- semantic command actions using the existing capability/action boundary where practical;
- explicit limits for command count, label length, filtering work, and visible rendering work.

Prefer extending existing layout, focus, scrolling, text-field, scene, and capability contracts over introducing a parallel widget system.

### Native Linux qualification

Qualify the complete flow on one declared Linux profile before broadening platform claims.

The acceptance fixture must exercise actual native input ownership for the profile, not synthetic text injection presented as IME acceptance. Preserve the current distinction between model tests, renderer tests, protocol/input evidence, and application-level acceptance.

Japanese composition acceptance should include at least:

- preedit is visible in the search field;
- candidate conversion can produce one committed Japanese value;
- filtering observes committed text at the documented boundary;
- Escape during composition cancels composition without closing the palette;
- Escape with no active composition closes the palette;
- focus loss/cancel cannot commit stale composition;
- reopening starts with a fresh owner/epoch;
- activation does not double-submit or leak through to the restored background owner.

Candidate-window contents/highlight remain outside scope unless separately qualified.

### MZed integration

Once the standalone component is qualified and the reviewed application/framework pins have a recorded go decision under [0019](0019-mzed-native-coexistence-proof.md#go-or-fallback-decision):

- mount the command palette inside the existing MZed application/window boundary;
- keep upstream Zed read-only;
- preserve the original editor as the surrounding application;
- prove open/search/navigate/activate/cancel and restoration to the editor;
- prove the original editor remains usable after palette teardown/remount;
- keep framework code independently authored and application-derived integration code in MZed.

If the coexistence boundary fails its gates, stop expansion and prepare the 0019 fallback decision report.

Do not rebuild or run the full MZed editor for every lower-level framework change. Use focused framework fixtures during development and return to MZed at the integration checkpoint.

## Accessibility and semantics

This milestone must not equate visible pixels with a usable picker.

Define a portable semantic contract for at least:

- palette/dialog ownership;
- search-field name/value/focus;
- list or equivalent collection role;
- active/selected option state;
- command accessible name;
- disabled state where applicable.

Linux accessibility transport may remain a later platform gate if it is not yet available, but the reusable component must not make semantics impossible to expose later. Record semantic accessibility as PASS, FAIL, UNRUN, or UNSUPPORTED separately from visual/input acceptance.

## Performance and boundedness

Use hotpath.mbt only where measurement answers a concrete question. At minimum observe:

- input/composition handling;
- filtering;
- visible-list preparation;
- scene assembly.

Performance measurements are initially observe-only. Do not establish arbitrary regression thresholds without a measured baseline and workload rationale.

Large collections should not require rendering every command. If virtualization is introduced, keep it deterministic and test visible-range/boundary behavior independently.

## Verification

Use layered evidence rather than one aggregate green claim.

Required before calling the standalone milestone complete:

- focused MoonBit model/component tests;
- property/boundary tests for filtering, selection and focus state;
- turtles.mbt mutation coverage for new state logic where it provides useful signal;
- warning-denied relevant target checks/tests;
- Linux renderer/presentation checks for the new component states;
- actual native keyboard + Japanese IME end-to-end flow on the declared profile;
- cancellation, stale-owner, teardown/remount and leak-through regressions;
- retained exact source/tool/font/runtime identity for native acceptance.

Required before calling the MZed integration milestone complete:

- exact pinned gpui.mbt and MZed source identities;
- same-window evidence;
- command-palette flow exercised through the integrated application;
- original editor input/save still works after palette use and teardown/remount;
- no second unintended native toplevel;
- explicit record of unrun platform/accessibility/performance scopes.

The existing local fast/quality workflows may be reused, but a passing quality workflow does not substitute for the application interaction gates above.

## Supporting tools

### turtles.mbt

Use the source-exact verification path on new state transitions where mutation findings can produce meaningful regressions. Do not expand formal-proof scope merely to increase coverage numbers.

### hotpath.mbt

Instrument named application spans needed to understand the palette workload. Nanosecond storage is not a claim of nanosecond clock accuracy.

### vlmkit

Use vlmkit visual/semantic/action evidence only after the driver profile for the target platform is qualified. vlmkit evidence supplements deterministic assertions; it does not replace them.

Do not block the Linux command-palette milestone on unfinished macOS vlmkit work.

## Non-goals

- Full Zed editor port.
- General rich-text editor.
- Multi-cursor editing.
- General bidi qualification.
- Full IME support across compositors/protocol versions.
- Candidate-window content/highlight qualification.
- Production accessibility support on every platform.
- New Windows-specific feature work.
- A complete Kumo/Yami-kumo native component library.
- Pixel-identical UI across operating systems.

## Sequence

1. Freeze and document the current reusable text-field/IME boundary.
2. Implement bounded picker/list state and keyboard behavior headlessly.
3. Compose picker/list + text field into a standalone command-palette fixture.
4. Qualify focus containment, dismissal and restoration.
5. Qualify actual Linux keyboard and Japanese IME behavior.
6. Add bounded performance observations and targeted mutation coverage.
7. Record or reconfirm the 0019 go decision on the reviewed pins, then integrate the same component boundary into MZed.
8. Record the resulting framework gaps before choosing the next component migration.

## Exit criteria

This proposal is complete when the repository can point to reproducible evidence that a reusable gpui.mbt command palette performs the full declared Linux flow, and MZed consumes that same reusable boundary for an application-level interaction without breaking the surrounding editor.

Completion of this proposal does not imply gpui.mbt 1.0 readiness. It should, however, move the project from "individually qualified foundations" to "one useful native interaction assembled from reusable framework components."
