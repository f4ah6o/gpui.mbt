# Upstream provenance and porting policy

Status: design only

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
