# Upstream provenance and porting policy

Status: done
Model: gpt-6-luna
Updated: 2026-10-03

## M0 resolution

The source-use, fixture, attribution, and release-audit rules are recorded in
[docs/provenance.md](../../docs/provenance.md), with machine-readable pin and
license evidence in [docs/upstream.json](../../docs/upstream.json). The
compatibility target is `zed-industries/zed@d9afb21688e04f89d9e94d96d33eb530aef90886`.
At that revision, `crates/gpui/Cargo.toml` identifies the GPUI package as
Apache-2.0 and `crates/gpui/LICENSE-APACHE` resolves to the Apache 2.0 text;
the repository also contains a root `LICENSE-GPL`, so license scope is checked
by exact path. This is documentation only: no upstream code or fixtures were
copied, no GPL source was transferred, and no new NOTICE file was needed.
Per-source port records, adapted-material notices, and the pre-release GPL
source audit remain future gates.

## M1 evidence

The `diagnostics/`, `core/`, and [`testing/core_model/`](../../testing/core_model/model_test.mbt)
implementations and synthetic reference-model fixtures are original gpui.mbt
work. The [`records`](../../docs/upstream.json) array remains empty, no
upstream source or fixture was copied, and no GPL-derived code was transferred.
The local command
`moon test primitives diagnostics core testing/core_model --target native --deny-warn`
passes 29 tests; `python3 scripts/check_contracts.py` validates the contract
documents while correctly leaving release evidence pending. These checks do
not replace the per-source/license/dependency audit required before release.

## Purpose

gpui.mbt may study and adapt Apache-2.0 GPUI code and behavior, but provenance must remain auditable and GPL Zed application code must not be accidentally mixed into the port.

## Scope rule

Before using upstream implementation details, verify the license of the exact upstream crate/file context.

Do not infer that all code in the Zed repository has the same license as GPUI.

## Provenance record

For each substantial port/adaptation, record:

- upstream repository
- upstream revision SHA
- upstream path(s)
- observed license
- gpui.mbt destination path(s)
- whether implementation was translated/adapted or independently reimplemented from behavior/API
- material deviations

This may live in PR descriptions initially and later in a machine-readable provenance file if volume warrants it.

## Preferred implementation order

1. specify behavior/API contract;
2. write conformance examples/properties;
3. implement in MoonBit idioms;
4. compare behavior with upstream fixtures/examples;
5. inspect upstream implementation details only where useful;
6. record provenance when source materially influenced implementation.

This avoids unnecessary line-by-line translation and produces a better MoonBit-native design.

## Upstream synchronization

Pin compatibility work to explicit upstream revisions.

Do not continuously chase upstream HEAD without a reviewed compatibility update.

A synchronization change should answer:

- what changed upstream?
- which gpui.mbt contracts are affected?
- is behavior required for our compatibility target?
- which tests change?
- is the change a breaking public API change for gpui.mbt?
- does it introduce a new dependency or platform assumption?

## Naming and attribution

Project identity should make independence clear.

Recommended README statement:

> gpui.mbt is an independent MoonBit implementation of the GPUI programming model. GPUI is developed by Zed Industries. This project is not affiliated with or endorsed by Zed Industries.

Keep applicable Apache-2.0 notices/attribution for adapted upstream material.

## Source boundaries

Do not port Zed application-specific UI code merely because it uses GPUI.

If a useful abstraction currently exists only in a differently licensed Zed application crate:

- derive requirements from observable behavior/documentation where legally appropriate;
- design an independent gpui.mbt abstraction;
- do not copy implementation text into Apache-2.0 gpui.mbt without compatible licensing.

## Test fixture provenance

Fixtures can also carry licensing/provenance concerns.

Prefer:

- gpui.mbt-original fixtures
- small independently written compatibility examples
- upstream fixtures only when their license is verified and attribution is preserved

## Release audit

Before 1.0 and every major release:

- review provenance records
- verify license files/notices
- verify dependency license inventory for non-runtime tooling separately
- verify no accidental GPL-derived source entered runtime packages
- verify README independence statement remains accurate


## M2/M3 provenance update — 2026-10-03

The new `element/` and `scene/` foundations were implemented from this repository's documented behavior contracts and existing gpui.mbt value/layout APIs. No upstream GPUI implementation text or fixture was copied for this slice, so `docs/upstream.json` requires no new source-adaptation record. The pinned upstream revision remains the later conformance target.


## Closure — 2026-10-03

The upstream provenance and porting policy is complete: the compatibility revision is pinned, license scope and source-use rules are documented, and machine-readable provenance metadata is in place. Future per-source records are created only when adapted upstream material is actually used, while pre-release provenance/GPL audits remain release work tracked by `0005`; those ongoing compliance gates do not keep this policy-definition packet open.
