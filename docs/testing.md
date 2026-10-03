# Testing and quality contracts

Status: M1 core plus M2 layout/element and M3 scene foundation tests; current headless tests run in CI.

The current test coverage exercises the headless `primitives` value layer,
core app/entity/scheduler lifecycle, the deterministic `layout` flex-line
foundation, the flat `element` tree, and ordered `scene` commands. It includes
deterministic value and lifecycle cases, two seeded rectangle properties, a
seeded entity lifecycle reference-model property, a seeded flex-line
geometry/order property, and exact hit-test/dispatch/focus/scene-order tests.
Recursive auto layout, Render/IntoElement lifecycle, event/focus PBT,
scene golden fixtures, render/text, mutation testing, and native integration
tests remain unimplemented. Deterministic callback tests now cover capture/bubble
execution and stop-propagation, and scene tests cover schema-versioned canonical
command snapshots including negative-zero normalization. This document
separates active checks from future budgets. Release status is tracked in
[release gates](release-gates.json) and the [release policy](release.md).

## Test layers

| Layer | Purpose | Required evidence |
| --- | --- | --- |
| L0 compile/static | Formatting, warnings, package checks, target builds | Tool versions and complete command output |
| L1 deterministic examples | Exact API contracts and regressions | Test result plus case identifier |
| L2 property-based | Geometry, layout, entity, event, focus, and scene invariants | Seed, generated-case count, shrink trace, final counterexample |
| L3 model-based | Compare lifecycle command sequences with an independent reference model | Model version, command sequence, seed, expected and actual observations |
| L4 mutation | Measure whether tests detect meaningful source changes | Per-package/operator report, baseline revision, survivor and timeout list |
| L5 visual | Compare normalized scene data and pinned raster output | Fixture manifest, baseline/current/diff images, rendering environment |
| L6 artifact review | Optional external image and accessibility-oriented review | Input artifact checksum and review result; never a native-driver pass |
| L7 native integration | Exercise windows, input, focus, text services, accessibility, and recovery | Platform, runner, test result, logs, and attached artifacts |

The active M1 property suites are `geometry.rect.invariants` with seed
`12725326473013217044` (`0xb09971016ad3c714`) and
`geometry.rect.translations` with seed `13790154211114911481`
(`0xbf6078310f5c86f9`). Each currently runs 256 cases with `max_size=64` and
`max_shrinks=500`. QuickCheck comes from the pinned MoonBit core library and is
imported as `moonbitlang/core/quickcheck` only with `for "test"`; the dependency
audit rejects it in runtime imports. The `core-model` entity lifecycle
reference-model property uses seed `584118800423729943`
(`0x081b34f445e23b17`), 256 cases, `max_size=32`, and `max_shrinks=500`.
These exact counts and seeds are active. The larger nightly and stress budgets
below are policy targets and are not scheduled jobs yet.

Headless tests are the default for core semantics. Pixel comparisons are
platform-specific unless the same deterministic rasterizer and assets are used.
Semantic scene changes and raster changes have separate oracles. The optional
vlmkit workflow may inspect PNG output, but it does not drive native windows and
does not become a runtime dependency.

## Determinism and workload budgets

Every property or generated model test uses a recorded unsigned 64-bit seed.
The fixed PR seed root is `0x47505549` (`GPUI`). A suite seed is the first 64
bits of `SHA-256("gpui.mbt:pbt:v1:<root-hex>:<suite-id>")`, interpreted as an
unsigned big-endian integer. Current QuickCheck properties pass this suite seed
directly to the core library. For generated model cases, derive a replay seed
from the suite seed and stable case identifier; a model runner must pass and
report it. If the selected API cannot accept the required seed, that suite is
not eligible for a deterministic gate until an adapter is provided.

| Job | Seeds | Cases per property | Max model commands | Shrink candidates | Wall-clock cap |
| --- | --- | ---: | ---: | ---: | ---: |
| Pull request | Fixed seed root, stable suite seeds | 256 | 32 | 500 | 5 minutes total for PBT |
| Nightly expanded | Fixed root plus 10 recorded rotating roots | 2,000 per seed | 256 | 5,000 per failure | 30 minutes total for PBT |
| Scheduled stress | 100 recorded rotating roots | 10,000 per root, divided into bounded batches | 2,048 | 20,000 per failure | 2 hours per platform job |

These are initial policy caps, not measured throughput claims. The current PR
workflow enforces 256 cases per active geometry property; total PBT wall-clock
and model-command caps are not yet enforced. Nightly and stress rows are future
jobs. Before a budget is made blocking, record runner class, MoonBit toolchain,
target, elapsed time, and case count. A budget change requires a reviewed update
to this table and the CI configuration. A timeout is a failure with its seed and
last completed case; rerun-to-pass does not erase it.

For every failed generated case, retain the original seed, derived suite/case
seeds, property or model identifier, generator version, attempted case count,
shrink trace, minimized counterexample, toolchain, target, and reproducing
command. A failure should be reproducible from the recorded seed and fixture
revision alone.

## Reference-model strategy

The model is deliberately small and independent of implementation internals.
It specifies only public observations and valid command preconditions. The
first model covers entity identity and lifecycle with create, read, update,
observe, subscribe, unsubscribe/drop, notify, and destroy commands. The runner
compares observable state after every command, not only at sequence end.

Generators produce valid commands from the model state. Shrinking removes
commands or simplifies their values while preserving command validity. The
model records notification count/order, subscription liveness, entity liveness,
and externally visible identity. Later models add focus/event trees, window
lifecycle, task cancellation, and platform services. Each model has a versioned
contract identifier so that a failing sequence remains interpretable after a
generator changes.

Core property families include:

- geometry round trips, containment, intersection symmetry, clamping, and
  transform composition within documented precision;
- layout determinism, finite/non-negative geometry where required, containment,
  constraint satisfaction, stable order, and idempotent relayout;
- entity liveness, identity, deterministic observer order, documented
  notification behavior, and subscription drop behavior;
- event propagation order, stop-propagation, live-tree focus, and valid focus
  after destruction;
- stable scene ordering, clip nesting, normalized serialization, and equivalent
  transforms yielding equivalent normalized output.

## Fixture and visual-artifact contract

Every committed fixture has a stable ID and a manifest entry containing its
kind, source/provenance, input checksum, expected semantic result, target scope,
and any required environment. Fixtures are original unless an explicit
compatible license and attribution are recorded. Generated fixtures include
the generator version and seed. Text fixtures state script coverage, font files
and checksums, locale, scale factor, and expected shaping/layout observations.

Raster goldens pin the runner image, renderer, fonts, locale, device scale,
color profile when applicable, and animation/time state. A visual failure
retains baseline, current output, and a difference image. Font or renderer
updates require an explicit baseline review. Exact pixels are not compared
across different native text/rendering stacks.

CI retains these artifacts for diagnosis:

| Artifact | Minimum contents | Retention target |
| --- | --- | ---: |
| PBT failure | Seed manifest, command, shrink trace, counterexample | 14 days for PR; 30 days for nightly |
| Mutation result | turtles JSON, baseline revision, survivor/timeout diffs | 14 days for PR; 30 days for nightly |
| Scene result | Normalized expected/current scene and semantic diff | 14 days for PR; 30 days for nightly |
| Raster result | Fixture manifest, baseline/current/diff PNGs | 14 days for PR; 30 days for nightly |
| Native failure | Platform/test identity, crash or native logs, relevant screenshots | 14 days for PR; 30 days for nightly |

Each artifact bundle has a manifest with repository revision, workflow/run ID,
target, toolchain, suite/fixture IDs, and checksums. A red gate must identify
the failed case without requiring a local reproduction first.

## Mutation ratchet

Use turtles as development/CI tooling, never as a public runtime dependency.
Mutation reports are split by package and mutation operator. A surviving or
timed-out viable mutant is an actionable test gap. A mutant can be classified
as equivalent or redundant only with a short reviewed rationale linked from
the report.

The ratchet is:

1. Record a non-blocking deterministic baseline by package and operator.
2. Make the gate blocking only after a rerun proves the baseline is stable.
3. Require each package/operator score to stay at or above its reviewed
   baseline; do not hide a subsystem regression in one global percentage.
4. Raise thresholds as APIs stabilize. Production-critical core packages target
   100% of viable mutants killed, with only documented equivalent/redundant
   exceptions.
5. At release, allow zero unexplained `SURVIVED` or `TIMEOUT` mutants in
   critical core packages. Report property-only kills separately and convert
   useful shrunk witnesses into permanent regression examples.

No mutation tool or baseline is active in M1. The source is now sufficient for
an initial primitives mutation study, but the release ledger remains pending
until a deterministic report, baseline revision, and reviewed survivor list
exist.

## CI split

Future expanded/nightly jobs add larger PBT budgets, full turtles, all supported
target builds, raster goldens, and native E2E. Future scheduled stress rotates
and records seeds for long command sequences, resource churn, repeated window
lifecycle, large text/layout fixtures, and renderer recovery.

The PR workflow runs the Python contract-validator unit tests, document and
ledger validation, `moon fmt --check`, and warning-denied all-target MoonBit
checks and tests. It covers the present M1 core and M2/M3 headless foundation
packages. It does not run expanded
PBT, turtles, native integration, visual goldens, stress suites, or performance
baselines, and it cannot satisfy any production release gate. Check the exact
workflow commands in [`contracts.yml`](../.github/workflows/contracts.yml).
