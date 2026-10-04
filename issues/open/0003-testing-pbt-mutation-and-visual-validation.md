# Testing: property-based, mutation, and visual validation

Status: in progress — deterministic/PBT coverage and non-blocking primitive mutation reporting; ratchet pending

## Current-head acceptance triage — 2026-10-04

Basis: merged main HEAD `1dea499e34a36a64927791c94f35965a91c305a2`; PR #13
head `d70b1255aa5dc1eaaea04a67a9ea748d29317cbd`.

- [x] Deterministic tests, fixed-seed geometry/entity/layout/event/focus/scene
  properties, and the entity reference-model suite pass the hosted
  [contracts/core run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649283)
  (112 tests on wasm, wasm-gc, and JS; 122 on native).
- [x] A pinned `turtles` 0.3.0 primitives job and schema-2 report audit run in
  CI; the hosted [mutation run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649324)
  classified 145 viable mutants and retained the report/survivor diffs.
- [ ] The mutation result is observational only: 115 killed, 30 survived,
  79.310%, with `--fail-under 0`. The survivors are unreviewed, and no stable,
  repeated per-package/operator baseline or blocking ratchet has been accepted.
- [ ] All-target mutation, scene/raster goldens, vlmkit artifacts, expanded
  stress jobs, and broad native/performance evidence remain open.

The successful mutation workflow is a report-generation pass, not a mutation
quality-gate pass.

## Goal

Testing must demonstrate behavioral strength, not only line coverage.

The core quality loop is:

```
example/unit tests
      +
QuickCheck properties
      |
      v
   turtles
      |
      +--> surviving mutant -> missing property/example
      +--> property-only kill -> valuable invariant confirmed
      +--> shrunk witness -> regression test candidate
```

## Test layers

### L0: compile and static gates

- moon fmt --check
- moon check with warnings denied where supported
- target-specific compilation

### L1: deterministic unit tests

Use example tests for exact contracts and regressions.

Particularly suitable for:

- lifecycle ordering
- event propagation
- focus changes
- scene serialization
- platform-independent state machines
- parser/configuration behavior

### L2: QuickCheck PBT

Use moonbitlang/quickcheck as an explicit test-only dependency.

Prefer properties over enumerating random examples.

Initial property domains:

#### Geometry

- translate inverse/round-trip
- intersection commutativity where defined
- union containment
- clamp/idempotence
- scale composition
- coordinate conversion round-trip within stated precision

#### Layout

- determinism
- no invalid geometry
- parent/child containment invariants
- min/max constraint satisfaction
- flex conservation invariants
- stable ordering
- idempotent re-layout for unchanged inputs

#### Entity/App

Generate operation sequences:

- create
- read
- update
- observe
- subscribe
- unsubscribe/drop
- notify
- destroy

Compare the implementation to a small reference model.

Properties:

- dead entities cannot become live again
- observation order is deterministic
- one mutation has one documented notification behavior
- dropping a subscription prevents later callbacks
- entity identity is never accidentally reused while observable

#### Event/focus

Generate tree shapes and event sequences.

Properties:

- propagation order matches the model
- stop-propagation is respected
- focused element belongs to the live tree
- destroying focused nodes leaves a valid focus state
- coordinate transforms preserve hit-test meaning

#### Scene

- stable ordering
- clip nesting invariants
- deterministic serialization
- equivalent transforms produce equivalent normalized scene output

### L3: state-machine/model-based PBT

For lifecycle-heavy systems, maintain a deliberately simple reference model independent of implementation internals.

Run random command sequences against model and system under test and compare externally observable state.

This should cover App/Entity first and later window/focus/task lifecycle.

### L4: turtles mutation testing

turtles is a development/CI tool, not a runtime dependency.

Policy:

- introduce mutation testing early for pure/core packages
- use target-aware mutation runs
- retain deterministic QuickCheck seeds in mutation CI
- inspect property-only kills
- turn useful shrunk witnesses into permanent regression examples
- do not auto-accept generated properties without review

Ratchet plan:

1. establish baseline score without blocking;
2. require no score regression;
3. raise package thresholds as APIs stabilize;
4. production core packages target 100% viable-mutant kill unless a documented equivalent/redundant mutant exception exists;
5. release gate must have zero unexplained SURVIVED/TIMEOUT mutants in critical core packages.

A single global percentage is insufficient. Report by subsystem and mutation class.

### L5: renderer golden tests

Headless rendering must emit deterministic artifacts where possible:

- normalized scene snapshots
- raster image goldens on pinned rendering environments
- text/layout fixtures with pinned fonts when pixel comparison is intended

Do not mix semantic scene regressions and rasterization regressions into one oracle.

### L6: vlmkit

vlmkit is useful, but not as a MoonBit/runtime dependency.

Use it only outside the library as a black-box validation layer.

No MoonBit-specific vlmkit integration is required for static artifact analysis. gpui.mbt can emit/capture PNG artifacts and external tooling can inspect/diff them.

Current limitation: vlmkit's capture and interaction workflows are browser/Playwright-oriented. A native gpui.mbt window is not automatically a Playwright page.

Therefore:

- do not make vlmkit the canonical native interaction driver;
- use it for PNG/image diff, visual review, design/a11y-oriented artifact checks where applicable;
- optionally expose deterministic headless screenshot fixtures that vlmkit can consume;
- if a future native capture/driver adapter is needed, keep it in test tooling, not the gpui.mbt runtime.

### L7: native integration/E2E

Each supported platform requires native tests for:

- create/show/close window
- resize/scale factor
- mouse and keyboard events
- focus
- clipboard
- IME composition
- menus/cursor where supported
- accessibility exposure
- suspend/resume where relevant
- GPU device/surface loss handling

## Flake policy

A flaky test is a product-quality defect in the test oracle.

- fixed PBT seeds in ordinary CI
- rotating/additional seeds allowed in scheduled stress jobs, with failing seed recorded
- mutation baseline must prove deterministic before classifying mutants
- visual tests pin fonts, scale factor, locale, animation state, and renderer environment
- rerun-to-pass must not hide a release-blocking failure

## CI split

Fast PR gate:

- fmt/check
- unit tests
- bounded PBT
- selected turtles packages
- headless scene tests

Full PR/nightly:

- expanded PBT budgets
- full turtles
- all supported target builds
- renderer goldens
- native E2E

Scheduled stress:

- seed rotation
- long operation-sequence PBT
- resource churn
- repeated window create/destroy
- large text/layout corpora
- GPU recovery scenarios

## Required artifacts

CI should retain:

- QuickCheck counterexample/seed
- turtles JSON report and survivor diffs
- scene diff
- raster baseline/current/diff
- native crash logs where applicable

A red gate must be diagnosable without reproducing locally first.

## M1 implementation update

Model: gpt-6-luna
Updated: 2026-10-03
Status: in progress; M1–M3 deterministic/PBT evidence is active, while the mutation ratchet and visual/native release layers remain open

The initial M1 quality path is now concrete: [docs/testing.md](../../docs/testing.md)
records active versus planned coverage, exact geometry property seeds and PR
budgets; [docs/performance.md](../../docs/performance.md) records the pending
baseline policy. `primitives/` has deterministic geometry/color/input tests and
two seeded rectangle QuickCheck properties. The PR workflow
([contracts.yml](../../.github/workflows/contracts.yml)) runs Python contract
tests, document/evidence validation, MoonBit formatting, warning-denied checks,
and tests. `scripts/check_contracts.py` audits all package manifests, allows
QuickCheck only in test imports, and rejects new runtime packages until their
layer is approved.

Verification: `python3 -m unittest discover -s tests -p 'test_*.py'` passes all
18 validator tests, and `python3 scripts/check_contracts.py --root .` passes
while reporting the release ledger as pending. `--require-ready` exits 2 as
required while production evidence is absent. `moon fmt --check`, `moon check
--target all --deny-warn`, and `moon test --target all --deny-warn` all pass;
the full MoonBit suite passes 29 tests on each of wasm, wasm-gc, js, and native.
The active geometry package contributes deterministic/property tests, the
lifecycle model is included in the all-target suite, and `layout/` now adds
deterministic flex-line cases plus a fixed-seed QuickCheck property. The current
suite passes 36/36 tests on wasm, wasm-gc, js, and native. Recursive layout and
element-tree properties, render/text, mutation, visual, native integration,
stress, and performance suites remain open, so this packet is still incomplete.


## M2/M3 headless test update — 2026-10-03

Deterministic tests now cover element-tree validation, reverse-paint hit testing, capture/bubble route order, focus acceptance/rejection, element-to-scene ordering, and scene command data. These tests are part of the all-target MoonBit CI gate. Event/focus state-machine PBT, stop-propagation properties, scene serialization/goldens, turtles mutation baselines, vlmkit artifacts, and native E2E remain pending and therefore this packet remains open.


## Dispatch/snapshot test update — 2026-10-03

Deterministic M2 tests now execute the capture and bubble callback phases directly and verify that stop-propagation prevents every later callback. M3 tests now verify provisional `CommandSnapshot` scale validation, owned command storage, stable canonical serialization, command order, and negative-zero normalization. They deliberately do not exercise or claim the reserved `SceneSnapshot` v1 schema. Event/focus state-machine PBT, committed scene golden fixtures, turtles baselines, vlmkit artifacts, and native E2E remain pending.


## Event/focus and clip invariant update — 2026-10-03

The next headless correctness slice is implemented. M2 now has immutable
`ElementTree::without_subtree`, which removes a complete subtree and clears
focus when the focused node is removed, plus seeded QuickCheck properties for
capture/bubble route reversal, global stop-propagation, and live focus after
subtree removal. M3 now validates clip pushes/pops as a strict LIFO stack and
rejects underflow, ID mismatch, and unclosed clips before a provisional
`CommandSnapshot` is emitted; a seeded clip-stack property accompanies the
deterministic cases.

This does not complete the packet. Render/IntoElement lifecycle, recursive auto
layout, the reserved `SceneSnapshot` v1 resource/clip-chain/item schema,
mutation baselines, visual/native evidence, renderer/backend work, and later
production gates remain open.


## Recursive layout and versioned scene test update — 2026-10-03

The headless suite now includes a fixed-seed 256-case recursive flex-tree
property in addition to deterministic nested-layout cases. The versioned scene
tests cover the `SceneSnapshot` v1 subset envelope, canonical JSON,
negative-zero normalization, invalid clip references, opacity validation, and
deterministic reuse of identical rectangle clip chains.

The current PR gate passes `moon fmt --check`,
`moon check --target all --deny-warn`, and
`moon test --target all --deny-warn`; the MoonBit suite is 62/62 on wasm,
wasm-gc, js, and native. These are MoonBit target/headless results only.
Turtles mutation baselines, committed full-schema scene/raster goldens, vlmkit
artifacts, Render/text coverage, native E2E, stress, and performance evidence
remain pending, so this packet stays open.

## Mutation and timing tooling update — 2026-10-04

The repository now pins `turtles` 0.3.0 for a `primitives/` mutation job. It
runs deterministic examples and the existing fixed-seed QuickCheck properties
against source mutants in turtles' temporary workspaces, retains schema-2 JSON
and survivor/timeout diffs, and emits property-kill regression templates. Its
first baseline uses `--fail-under 0`, so survivors are recorded for review
without blocking CI; setup failures and the independent report audit remain
fatal. The audit rejects empty or all-unviable runs, missing configured
operator groups, skipped source files, inconsistent score summaries, and
missing survivor/timeout diffs. The pinned 0.3.0 CLI has no target selector, so
this initial job uses Moon's default test target; it is not an all-target
mutation score or a reviewed per-package/operator baseline.

Ubuntu native CI now has an opt-in benchmark report for 30 renderer-recovery to
first-frame samples at 1x and 2x. The report retains raw samples, fixture and
worktree checksums, the actual GL renderer, CPU/toolchain/runner metadata, and
summary statistics. The comparator requires two distinct runs on the same
candidate worktree and exact environment/workload signatures before confirming
a 10% p50 or p95 regression. The report is diagnostic only until a comparable,
reviewed baseline exists.

The first complete local mutation run used pinned MoonBit and turtles 0.3.0 and
passed turtles' pristine `moon check` and baseline tests. Across 145 viable
mutants, 115 were killed, 30 survived, and none timed out or was unviable: the
observed score is 79.310%. Per-operator results were arithmetic 16/20, boolean
16/28, comparison 34/37, condition 45/56, and literal 4/4. The schema-2 report
and all 30 survivor diffs passed the report audit. This is one non-blocking
observation on the default Moon test target, not a reviewed or repeated
per-package/operator ratchet; the mutation release gate remains pending. It was
captured at HEAD `731981259efe3815de06d3420163f3b842e854a0` from a dirty shared
worktree with audited source-manifest SHA-256
`cd6c3cec88c5fcba97ec2325a798fe5cc47141f99c45d467bf6b45d6c353d6f1`; it is not
a clean candidate baseline. The local Ubuntu benchmark attempt could not create
the Wayland AF_UNIX socket, so it produced no timing samples or performance
score. Full turtles coverage, all-target mutation, visual goldens, vlmkit
artifacts, and broader native/performance evidence remain open.


## Hosted mutation observation — 2026-10-04

The [PR mutation workflow](https://github.com/f4ah6o/gpui.mbt/actions/runs/37186910719)
completed successfully for PR head
`c9a119c0f4f501d1146d4f9932551f3d446296f4`, checked out as synthetic merge
`d29982bedcd51839c9da00c37e0a0b3a5870642a`. The hosted result classified 145
viable mutants: 115 killed, 30 survived, zero timed out or was unviable
(79.310%); the schema-2 audit passed. The 30 survivors are still unreviewed.
This is one hosted observation, not a reviewed/repeated baseline, score
ratchet, or clean release-candidate result. The mutation and broader test
evidence packet remains open.
