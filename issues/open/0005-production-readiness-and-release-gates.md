# Production readiness and release gates

Status: design only

## Purpose

"Production-ready" is a measurable release state, not a subjective milestone.

## 1.0 blocking gates

### Correctness

- all required compatibility-matrix entries classified
- no known release-blocking correctness issue
- deterministic core/state-machine tests
- property suites cover core algebraic and lifecycle invariants
- no unexplained critical-package mutation survivors/timeouts
- regression tests for resolved high-severity bugs

### Platform

For every Tier 1 platform:

- native create/use/close E2E
- focus/input
- clipboard
- IME
- accessibility baseline
- high-DPI
- multi-window
- GPU/surface recovery behavior
- resource teardown

### Text

- Japanese input/rendering included
- shaping/fallback fixtures
- emoji/combining/bidi fixtures
- selection/caret mapping tests
- stable behavior for missing fonts

### Performance

Define representative benchmark scenes before optimization.

1.0 requires:

- committed benchmark methodology
- baseline values per Tier 1 platform/CI environment
- regression thresholds
- no known unbounded growth under repeated lifecycle tests
- no release-blocking frame pacing defect

Avoid absolute cross-machine claims from noisy CI. Prefer pinned runners or normalized regression thresholds.

### Stability

Stress scenarios:

- repeated entity churn
- repeated window create/destroy
- task cancellation churn
- resize storm
- input storm
- long text documents
- large element trees
- renderer resource churn

Record seeds/workloads on failure.

### API

- public API documented
- examples compile in CI
- compatibility/deviation docs current
- semver/deprecation policy documented
- no accidental backend types in public core API

### Dependencies

Runtime dependency audit verifies:

- MoonBit standard/core only
- repository-owned implementation for missing framework facilities
- documented native platform dependencies/FFI
- test tools do not leak into published runtime dependency graph

QuickCheck, turtles, and vlmkit remain development/test concerns.

### Supply chain and release

- locked/reproducible toolchain policy
- generated artifacts traceable to source revision
- release checklist
- changelog
- license and notices
- upstream provenance audit
- signed/checksummed release artifacts where release mechanism supports them

### Diagnostics

- crashes/panics preserve actionable subsystem information
- native error paths have structured context
- CI retains failure artifacts
- release build does not silently discard fatal initialization errors

### Security boundaries

Document and test relevant risks:

- unsafe/FFI ownership
- untrusted text/image dimensions and allocation limits
- malformed clipboard/input data
- path/file access performed by framework utilities if any
- integer overflow and geometry/resource sizing
- callback lifetime/reentrancy

A GUI framework need not become a sandbox, but its trust boundaries must be explicit.

## Quality metrics

Metrics are evidence, not goals to game.

Track:

- unit/integration pass status
- QuickCheck property count and budgets
- mutation score by package/operator
- property-only mutation kills
- known survivor count with rationale
- benchmark regressions
- visual regression count
- flaky-test count

Do not use code coverage alone as a release gate.

## Compatibility gate

Maintain a table by upstream concept/API area:

| Area | Status | gpui.mbt contract | Upstream reference | Deviations | Tests |
|---|---|---|---|---|---|
| Entity/App | planned | TBD | TBD | TBD | TBD |
| Render/Element | planned | TBD | TBD | TBD | TBD |
| Window/input | planned | TBD | TBD | TBD | TBD |
| Layout/style | planned | TBD | TBD | TBD | TBD |
| Scene/render | planned | TBD | TBD | TBD | TBD |
| Text | planned | TBD | TBD | TBD | TBD |
| Async/tasks | planned | TBD | TBD | TBD | TBD |
| Accessibility | planned | TBD | TBD | TBD | TBD |

The matrix is versioned against an upstream revision.

## Release candidates

A release candidate should run:

1. all fast CI
2. expanded PBT
3. full turtles gate
4. native Tier 1 matrix
5. visual goldens
6. benchmark comparison
7. stress suite
8. license/provenance audit
9. clean package/install consumer smoke

No manual "looks fine" step substitutes for a failed automated blocking gate.

## Post-1.0 policy

Production readiness must be continuously maintained.

Every new subsystem needs:

- deterministic unit/model tests
- PBT where meaningful
- mutation coverage where source mutation is meaningful
- native E2E when it crosses platform boundary
- benchmark when it affects a hot path
- compatibility matrix update when it changes GPUI-facing behavior

## M1 implementation update

Model: gpt-6-luna
Updated: 2026-10-03
Status remains: design only

The 1.0 policy is now linked to [docs/release.md](../../docs/release.md),
[docs/performance.md](../../docs/performance.md), and the machine-readable
[release ledger](../../docs/release-gates.json). The ledger has all 12 required
gates and intentionally leaves each `pending`. A gate marked `pass` now needs a
repository-local checksum-verified evidence manifest with matching gate ID,
candidate commit, toolchain, target, traceable run URL, and artifact digests.
The checker rejects missing/duplicate gates, malformed JSON or evidence,
incorrect state, and evidence paths or hashes that do not validate. It checks
manifest structure and file hashes only; independent review must still verify
that remote runs and artifacts substantiate the claim.

Verification: `python3 -m unittest discover -s tests -p 'test_*.py'` passes all
18 validator tests, and the default contract check passes while reporting
`pending`. The release decision check exits 2 until the production evidence is
complete. `moon fmt --check`, `moon check --target all --deny-warn`, and
`moon test --target all --deny-warn` all pass; the MoonBit suite passes 29 tests
on each of wasm, wasm-gc, js, and native. Platform, text, renderer, performance,
mutation, and clean-consumer evidence remain pending. The issue remains
design-only until all production gates have real, reviewed evidence.


## M2/M3 implementation evidence update — 2026-10-03

The repository now exercises more of the correctness/API/dependency surface through `element/` and `scene/` headless tests and stricter package-edge validation. This is development evidence only. No release-ledger gate is changed to `pass`: upstream compatibility comparison, mutation evidence, native Tier 1, text, performance, stability, visual, supply-chain, security-boundary, and clean-consumer evidence remain incomplete.
