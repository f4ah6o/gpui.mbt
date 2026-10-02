# Testing: property-based, mutation, and visual validation

Status: design only

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
