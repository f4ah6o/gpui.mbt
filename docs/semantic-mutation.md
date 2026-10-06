# Capability and MCP mutation contract

Status: reviewed semantic baselines and CI ratchet implementation. The original
PR #17 required final-head hosted stability/CI and verified merge for semantic
closure. Those requirements below record historical provenance. Current Linux
development instead uses the scoped [local actrun acceptance](../infra/linux-desktop/ACTRUN.md)
without a hosted wait; that gate does not rerun or promote these mutation scopes.

## Scope and provenance

The semantic mutation matrix is separate from the existing `primitives/`
ratchet. [`mutation-capability-mcp.yml`](../.github/workflows/mutation-capability-mcp.yml)
runs two independent scopes from
[`capability.toml`](../mutation-scopes/capability.toml) and
[`mcp.toml`](../mutation-scopes/mcp.toml). Each mutates only its named package
with arithmetic, boolean, comparison, condition, and literal operators while
running turtles' full module tests. It uses turtles 0.3.0, Moon's default test
target, two workers, a 180-second timeout, and timeout multiplier three.
It is not all-target mutation evidence.

The reviewed source observation is
[PR #17 run 37241489153](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37241489153)
at head `ac89b8e24a71209a21223a445b125c5a420fceac`, tested as GitHub's
synthetic PR merge `6d18b844167259c258f5ec9fef8e443b4c3a134a`. That synthetic
merge is not evidence that the PR merged to main. The run produced complete
reports and failed only when enforcing baseline files that intentionally did
not yet exist. Independent review checked the source artifacts and all report
fingerprints and classified every remaining survivor before creating the
baselines. For that original acceptance, a final hosted rerun had to demonstrate stable
baseline enforcement, and the final candidate had to pass required CI and be
verified merged before semantic closure. Exact successful final-head run links
belong in [PR #17's merge evidence](https://github.com/gpui-mbt/gpui.mbt/pull/17).
This source observation does not establish that final-head gate or assert its
result in advance.

The source artifacts are:

- [Capability artifact 11317679053](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37241489153/artifacts/11317679053),
  SHA-256 `b0aeca1246513ab05770feef192de2d45ca75654ad82482f4719914c43bb064c`.
- [MCP artifact 11318000405](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37241489153/artifacts/11318000405),
  SHA-256 `e9c8836dbae8604dc6d2219aa42f120f32cdf132edd826a73126850143ceb74f`.

The [capability baseline](../mutation-baselines/capability.json) and
[MCP baseline](../mutation-baselines/mcp.json) also retain the full head/merge
revision, workflow URL, source-manifest digest, and mutant-by-mutant reviews.
Artifacts have finite retention and may require GitHub access; the baseline
provenance and rationale records remain in the repository.

## Exact floors

Fractions are killed viable mutants divided by all viable mutants. Reviewed
survivors remain in the denominator; they are not relabeled as kills or removed
to report 100%.

| Scope | Overall | Arithmetic | Boolean | Comparison | Condition | Literal | Reviewed survivors |
| --- | --- | --- | --- | --- | --- | --- | ---: |
| `capability/` | 271/283 | 17/17 | 12/12 | 73/73 | 128/140 | 41/41 | 12 |
| `mcp/` | 262/271 | 8/8 | 11/11 | 67/67 | 138/144 | 38/41 | 9 |

Both observations had zero timeouts, zero unviable mutants, and no in-scope
parser skips. Forty-one regression tests in the capability/MCP black-box and
white-box mutation regression suites protect the meaningful gaps found during
review. The baseline JSON is authoritative for the exact ratchet values.

## Enforcement

[`check_turtles_report.py`](../scripts/check_turtles_report.py) audits each
complete report before enforcing its scope's baseline:

1. Require turtles schema 2 and version 0.3.0, nonempty toolchain/module
   metadata, full-module test scope, source/configuration fingerprints,
   nonempty mutants, unique mutant IDs, valid counts and diffs, and all five
   configured operator groups. Reject any mutant outside the selected scope
   and any skipped file inside it. Validate that the copied `turtles.toml`
   fingerprint matches the exact
   checked-in scope config.
2. Recompute overall/operator counts from individual outcomes and the score
   from viable counts. Require exactly the nonempty survivor/timeout diff
   files identified by the report. The report records a source-manifest digest;
   source-to-revision provenance is also reviewed when adopting a baseline.
3. Match scope, turtles version, default target, and full-module test scope.
   Compare overall and every operator's killed/viable floor using integer
   cross-products; a global gain cannot mask an operator regression.
4. Enforce each timeout ceiling. These semantic baselines require zero
   timeouts. They allow only explicitly reviewed survivor IDs whose path,
   operator, original text, and replacement text match their review. Killing an
   existing reviewed survivor is allowed; swapping in a different survivor
   with the same score is not.
5. Match the semantic baseline's Moon driver version/commit/date identity:
   `moon 0.1.20260920 (914d7da 2026-09-20)`. Installation-directory differences
   are ignored. The workflow separately pins compiler and core to
   `0.10.14+7d59c7ec9` and logs `moon version --all`; turtles' report and this
   identity comparison do not independently pin or attest compiler/core
   hashes. Formatter-dependent reviews must be reconsidered on those changes.

The audit counts `UNVIABLE` separately and excludes it from the viable
fraction; it does not enforce a zero-unviable ceiling. The observed zero count
is evidence, not an additional implemented gate. All-unviable/empty reports
are rejected. A changed source manifest is expected when code evolves and is
not forced to equal the historical baseline manifest. Review the source
change and survivor assumptions rather than treating a passing fraction or
stored rationale as a proof of semantic correctness.

The workflow writes an audited `observation.json` before baseline enforcement,
then a `ratchet.json` on successful enforcement. Raw JSON, console logs, and
survivor diffs are retained even when enforcement fails. Retention is 14 days
for pull requests and 30 days for other runs. A missing baseline or turtles
failure cannot become a passing job merely because artifact upload succeeded.

## Survivor review boundaries

The remaining survivors are reviewed equivalents or redundant checks under
specific invariants, not unexplained semantic gaps. Full per-ID reasoning,
locations, mutation diffs, and caveats live in the baseline JSON.

Capability rationale classes cover:

- signed-zero formatting equivalence under the pinned core formatter;
- non-finite serializer fallbacks unreachable after public validation;
- repeated liveness and aggregate-size guards protected by earlier checks;
- a bounded, harmless self-swap in descriptor sorting;
- size-check fast paths whose removal still leaves finite explicit bounds.

The fast-path cases are not identical in all observable costs or diagnostics.
For `m-88ed5fc8e417cb2b`, disabling the array-length precheck changes O(1)
rejection to at most 10,000 immediate child visits and can change the
`InvalidInput` detail or which malformed child is reported first. Recursive
child validation and cumulative node/character/depth budgets still apply.
For `m-b4ba90c8f17e7f33` and `m-e80beadd239d51c8`, either the raw-length cap or
the escaped-length early exit continues to bound the scan; successful output
sizes and caller rejection remain unchanged. The reviewed exemption accepts
these bounded cost and non-contractual diagnostic differences. It must be
revisited if exact diagnostics, latency, formatter behavior, or guarding
invariants become part of a changed contract.

MCP rationale classes cover unreachable parser/decoder branches under their
production callers, immutable in-flight request fingerprint checks already
established earlier, resource-identity checks guaranteed by successful adapter
resolution and immutable descriptors, repeated quote guards, and an argument
budget traversal dominated by the earlier whole-request scanner. These claims
rely on the documented caller, immutability, and resource-bound invariants;
changes to those invariants require renewed review even if a mutant ID persists.

## Acceptance and remaining release limits

This evidence supports the bounded semantic acceptance and merge-gated closure of
[0014](../issues/closed/0014-gui-api-mcp-equivalence-conformance.md): normalized
GUI/direct/MCP semantic traces, supported schema/wire parity, GUI observation,
explicit bounded synchronous replay, and a reviewed semantic mutation ratchet.
Owner-lifecycle packet [0015](../issues/closed/0015-capability-owner-lifecycle.md)
was already merged at main `074cd7b` with all nine main checks green.

[0016](../issues/open/0016-mcp-endpoint-lifecycle-conformance.md) remains open
for genuinely asynchronous cancellation/disconnect, pending teardown, hosted
parity, native/browser endpoint topology, and retained lifecycle evidence.
Cancellation notifications in the current synchronous stdio host are no-ops;
no interruption, rollback after commit, or durable/cross-process exactly-once
execution is claimed. Parent [0013](../issues/open/0013-generated-api-and-mcp-adapters.md)
remains open through that work and its parent close review.

[0003](../issues/open/0003-testing-pbt-mutation-and-visual-validation.md) still
owns the wider quality scope: the five primitives survivors, mutation on every
supported target and other critical packages, larger property/stress budgets,
visual evidence, and native/performance coverage. These package ratchets do
not promote the [release ledger](release-gates.json) or certify a production
release candidate.
