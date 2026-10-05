# Testing and quality contracts

Status: M1 core plus M2 layout/element and M3 scene foundation tests; current headless tests run in CI.

The current test coverage exercises the headless `primitives` value layer,
core app/entity/scheduler lifecycle, deterministic flex-line and recursive
flex-tree layout, the flat `element` tree, a declarative Render/IntoElement and
request-layout/prepaint/paint path, ordered `scene` commands, and the
implemented versioned `SceneSnapshot` v1 subset. It includes deterministic
value and lifecycle cases, two seeded rectangle properties, a seeded entity
lifecycle reference-model property, seeded flex-line and flex-tree geometry/order
properties, and exact element lifecycle, hit-test/dispatch/focus/scene-order tests.
Mutation coverage now includes independently scoped `capability/` and `mcp/`
observations with reviewed baselines and a final-head stability/CI merge gate
as recorded below. Full-schema scene golden fixtures,
text/path/image rendering, mutation coverage of other critical packages, and
broader native integration assertions remain unimplemented. Bounded recursive auto container sizing is now included in the
active layout test surface.
Event/focus PBT exercises route reversal, global
stop-propagation, and focus normalization after subtree removal; scene PBT
exercises strict clip-stack nesting and rejects unclosed stacks before snapshots
are emitted. Deterministic callback tests cover capture/bubble execution and
stop-propagation. Scene tests cover both the provisional `CommandSnapshot` and
the versioned v1 subset, including canonical serialization, negative-zero
normalization, envelope validation, and deterministic clip-chain reuse. This document
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
The portable text editing property `text.utf16-replacement.invariants` uses seed
`17836885540012499121` (`0xf78958e50fbf20b1`), 256 cases, `max_size=32`, and
`max_shrinks=500`; its reference strings are independently assembled from
generated Unicode scalar fragments. These exact counts and seeds are active.
The larger nightly and stress budgets below are policy targets and are not
scheduled jobs yet.

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

The repository pins `turtles` 0.3.0 in
[`mutation-primitives.yml`](../.github/workflows/mutation-primitives.yml) and
selects the stable primitives core in [`turtles.toml`](../turtles.toml). The
job runs the normal deterministic and fixed-seed property tests in turtles'
isolated copy, retains schema-2 JSON plus survivor/timeout diffs, and audits the
report before applying the checked-in
[`primitives` ratchet baseline](../mutation-baselines/primitives.json).

The accepted initial baseline comes from hosted PR #14 run `37202065139` at
head `0dac8f5e9141a960cf0d85e23da81c30e04f26dd`: 140 of 145 viable mutants
were killed (96.552%), with five survivors and zero timeouts. The operator
floors are arithmetic 20/20, boolean 25/28, comparison 37/37, condition 54/56,
and literal 4/4. CI compares exact killed/viable fractions using integer
cross-products rather than rounded percentages. The job fails if the overall
fraction regresses, any operator fraction regresses, or timeout count rises
above the recorded baseline. Scope, turtles version, target, and test-scope
metadata must also match, so a toolchain/scope change cannot silently inherit
the old threshold.

This completes the first blocking `primitives/` mutation ratchet on Moon's
default test target. It does not complete the broader release mutation gate:
the five current survivors still need either stronger tests or reviewed
equivalent/redundant classifications, and all-target mutation plus additional
critical packages remain open. The release ledger therefore remains pending.

### Capability and MCP semantic ratchets

The separate [`mutation-capability-mcp.yml`](../.github/workflows/mutation-capability-mcp.yml)
matrix runs turtles 0.3.0 over exactly `capability/` or `mcp/`, using full-module
tests on Moon's default target. The audited PR #17
[observation run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37241489153)
killed 271/283 capability mutants and 262/271 MCP mutants. Its 12 and nine
respective survivors have independently reviewed equivalent/redundant
rationales; neither scope had timeouts, unviable mutants, or in-scope parser
skips. The observations led to 41 deterministic regression tests and the
checked-in [capability](../mutation-baselines/capability.json) and
[MCP](../mutation-baselines/mcp.json) baselines.

The semantic gate compares exact overall and per-operator killed/viable
fractions, permits no timeouts, rejects any unreviewed survivor or identity/diff
swap, and checks the Moon driver build identity. Compiler/core pins remain in
the workflow; the report does not independently attest those two hashes. CI
retains observation JSON, ratchet JSON when enforcement succeeds, raw reports,
console logs, and survivor diffs for 14 days on PRs and 30 days otherwise.

The source observation deliberately failed only because the reviewed baseline
files were not yet present. A successful hosted baseline stability rerun and
all required checks on the final candidate are explicit merge gates; exact
successful run links must be recorded in PR #17's merge evidence. The source
observation alone is not a green stability result. See
[semantic mutation evidence and review caveats](semantic-mutation.md) for exact
operator floors and provenance. Closure of
[0014](../issues/closed/0014-gui-api-mcp-equivalence-conformance.md) takes effect
only with that verified merge,
while [0016](../issues/open/0016-mcp-endpoint-lifecycle-conformance.md) retains
asynchronous cancellation/disconnect and native/browser endpoint topology.
The broader mutation and production release gates stay pending.

## CI split

Future expanded/nightly jobs add larger PBT budgets, full turtles, all supported
target builds, raster goldens, and native E2E. Future scheduled stress rotates
and records seeds for long command sequences, resource churn, repeated window
lifecycle, large text/layout fixtures, and renderer recovery.

The contracts workflow runs the Python contract-validator unit tests,
document/ledger validation, `moon fmt --check`, and warning-denied all-target
MoonBit checks and tests. Independent mutation workflows run the selected
primitives scope and the capability/MCP scope matrix, retaining JSON and
survivor diffs; the semantic baseline stability merge gate is recorded above.
The Ubuntu native workflow also retains an opt-in recovery-to-first-frame timing report. These
jobs do not cover expanded PBT, renderer goldens, broad stress workloads, or a
comparable Tier 1 performance baseline and cannot satisfy production release
gates. See [`contracts.yml`](../.github/workflows/contracts.yml),
[`mutation-primitives.yml`](../.github/workflows/mutation-primitives.yml),
[`mutation-capability-mcp.yml`](../.github/workflows/mutation-capability-mcp.yml),
and [`ubuntu-native.yml`](../.github/workflows/ubuntu-native.yml) for exact commands.


## Event/focus and clip invariant implementation update — 2026-10-03

The active M2 property surface now includes stable seeded suites for pointer-route
reversal, capture stop-propagation, and focus validity after immutable subtree
removal. `ElementTree::without_subtree` removes the complete contiguous subtree
and clears focus only when the focused node is removed.

The active M3 property surface now validates strict LIFO clip nesting. A pop with
no open clip, a mismatched clip ID, or a frame that ends with an open clip is a
typed `SceneError`; `command_snapshot` refuses to freeze such a scene. These
checks strengthen the provisional command model only and do not consume the
reserved `SceneSnapshot` v1 schema.


## Recursive layout and SceneSnapshot v1 subset update — 2026-10-03

The recursive layout suite adds deterministic nested row/column cases, preorder
validation, missing-container rejection, and a fixed-seed 256-case property that
checks deterministic absolute geometry and descendant ordering. The versioned
scene suite checks schema version 1 metadata, owned resource/clip/item arrays,
clip-reference validation, finite opacity/transform inputs, canonical JSON, and
reuse of identical active rectangle clip chains.

PR CI runs `moon fmt --check`, `moon check --target all --deny-warn`, and
`moon test --target all --deny-warn`. At this slice the MoonBit suite passes
62/62 tests on wasm, wasm-gc, js, and native. This is headless target evidence,
not native GUI/platform evidence.
