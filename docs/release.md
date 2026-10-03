# Production readiness and release gates

Status: M1 contract; all 1.0 runtime evidence is pending.

Production readiness is an evidence-backed state. The machine-readable ledger
is [release-gates.json](release-gates.json). Its current `pending` status is
intentional: M1 contains a small headless primitives layer and core
app/entity/scheduler lifecycle code with deterministic and model-based tests. A
full lifecycle stress suite, element/rendering system, platform backends,
performance baselines, and release artifacts do not exist yet. Passing the
documentation contract check validates these files only; it does not mean the
project is production-ready.

## Gate states and evidence

Each required 1.0 gate is `pending`, `blocked`, or `pass`. A `pass` requires at
least one evidence manifest committed in the repository and named by
repository-relative path with its SHA-256 digest. Each manifest records the
gate ID, passing result, exact candidate commit, toolchain, target, HTTPS CI or
audit run URL, and checksummed output artifact links. The candidate commit is
recorded in the ledger itself and must match every passing manifest. A bare
status, test source file, successful documentation check, or unlinked claim is
not evidence of a production pass.

The checker verifies file hashes and manifest shape. It does not contact CI,
authenticate a run, inspect remote artifact contents, or prove that a result
semantically covers its gate. A release reviewer must confirm the run and
artifact contents independently before accepting a recorded pass.

The release-level status is derived from all gates:

- `pending` means one or more required gates still need evidence;
- `blocked` means at least one gate records a known blocker;
- `ready` is allowed only when every required gate is `pass`, the ledger pins
  the candidate commit, and its evidence manifests match that commit and their
  recorded hashes.

`python3 scripts/check_contracts.py` validates the contract documents and
reports the ledger state. `python3 scripts/check_contracts.py
--require-ready` is the release decision check: it exits non-zero until the
ledger is `ready` and every evidence reference validates. The PR contract
workflow runs the first command; a release workflow must run the second. The
M1 contract job cannot produce a production pass.

## Required 1.0 gates

| Gate ID | Release requirement | Evidence expected |
| --- | --- | --- |
| compatibility | Every required GPUI concept is classified; deviations and unsupported areas are explicit and versioned against upstream | Compatibility matrix, contract tests, pinned upstream revision |
| correctness | No known release-blocking bug; deterministic core tests, core properties, and resolved high-severity regression tests pass | Unit/PBT result manifests and issue links |
| platform_tier1 | Every declared Tier 1 platform passes native lifecycle, input, focus, clipboard, IME, accessibility, high-DPI, multi-window, recovery, and teardown tests | Per-platform conformance and sustained-run artifacts |
| text | Japanese, mixed scripts, emoji, combining marks, bidi, fallback, selection, and caret mapping fixtures pass | Fixture and per-platform text result manifests |
| performance | Representative benchmark method, pinned Tier 1 baselines, thresholds, and no release-blocking pacing or growth regression | Benchmark reports by environment and comparison result |
| stability | Entity/window/task/resource churn, resize/input storms, long text, and large trees complete within declared bounds | Workload/seed manifests, leak/resource reports, crash logs |
| api | Public API/examples, compatibility notes, semantic-versioning and deprecation policy, and backend-neutral core API are verified | API docs and consumer example build reports |
| dependencies | Runtime dependency audit confirms standard/core plus documented repository-owned platform boundaries; tooling stays out of runtime graph | Dependency graph and license inventory |
| supply_chain | Toolchain/reproducibility policy, source traceability, notices, provenance/license review, and supported signing/checksum process are complete | Build provenance and audit manifests |
| diagnostics | Fatal initialization errors and native failure paths retain actionable subsystem/platform context | Failure-injection results and retained logs |
| security_boundaries | FFI ownership/lifetime, untrusted input limits, overflow, and callback lifetime/reentrancy risks are documented and tested | Boundary review and negative-test reports |
| clean_consumer | A clean consumer can install/build the package from the release candidate without hidden repository dependencies | Clean environment smoke report |

The compatibility matrix lives in [compatibility.md](compatibility.md),
platform tiers and conformance requirements in [platform.md](platform.md),
upstream records in [provenance.md](provenance.md) and [upstream.json](upstream.json),
and test evidence requirements in [testing.md](testing.md). Performance
methodology and budget policy are in [performance.md](performance.md).

## Release-candidate sequence

Before a release candidate can be marked ready, run and retain the fast CI
gate, expanded PBT, full mutation gate, every Tier 1 native matrix, visual
goldens, benchmark comparisons, stability workloads, provenance/license audit,
and clean consumer smoke. The evidence manifest must identify the exact
candidate revision and all artifacts. A manual visual review can supplement
automated checks; it cannot override a failed blocking gate.

The release ledger and evidence files are reviewed together. When any gate
changes, update the result and evidence hashes in the same change. Missing,
stale, malformed, or mismatched evidence leaves the release pending or blocked.
Do not roll evidence forward from a different revision, platform, or toolchain
without an explicit revalidation record.

## Post-1.0 maintenance

Keep the gates active for every supported release. New behavior needs
deterministic tests, PBT where meaningful, mutation coverage where meaningful,
native tests at platform boundaries, benchmarks on hot paths, and compatibility
matrix updates for GPUI-facing changes. API and compatibility changes require
release notes and migration guidance where applicable.
