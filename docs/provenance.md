# Upstream provenance and porting policy (M0)

gpui.mbt is an independent MoonBit implementation of the GPUI programming
model. Compatibility means documented behavior and concepts, not Rust source
or binary compatibility. This M0 packet records a stable upstream reference
and defines how future implementation work keeps its source and license
context auditable. No upstream implementation code or fixtures are introduced
by this packet.

## Compatibility pin

The compatibility target is `zed-industries/zed` commit
`d9afb21688e04f89d9e94d96d33eb530aef90886`, observed at `refs/heads/main` on
2026-10-03. The immutable revision, source paths, and license evidence are in
[`upstream.json`](upstream.json). Compatibility work must use that SHA until a
reviewed pin update names the affected concepts and tests. Do not use a moving
branch URL as the compatibility target.

Primary upstream evidence at that exact revision:

- [`crates/gpui/Cargo.toml`](https://github.com/zed-industries/zed/blob/d9afb21688e04f89d9e94d96d33eb530aef90886/crates/gpui/Cargo.toml) declares the `gpui` package as `Apache-2.0`.
- [`crates/gpui/LICENSE-APACHE`](https://github.com/zed-industries/zed/blob/d9afb21688e04f89d9e94d96d33eb530aef90886/crates/gpui/LICENSE-APACHE) is a repository symlink to `../../LICENSE-APACHE`; the resolved file is the Apache License, Version 2.0. The pinned tree records the symlink mode and target.
- The same repository revision also contains [`LICENSE-GPL`](https://github.com/zed-industries/zed/blob/d9afb21688e04f89d9e94d96d33eb530aef90886/LICENSE-GPL). This is evidence that repository-wide licensing context must be checked by path; it does not change the `gpui` package metadata or grant permission to copy unrelated Zed application code.

The reviewed scope is the GPUI package and explicitly verified files at the
pinned revision. Never infer a file's license from the repository name, a
neighboring crate, or the existence of the GPUI package license. Before any
source adaptation, inspect the exact file, owning package, applicable license
file, and notices at the pinned commit. If that source context is unclear or
incompatible, implement from the documented/observable contract independently
and record no source-derived port.

## Independent implementation and source records

Preferred order:

1. Define a gpui.mbt behavior/API contract.
2. Write independently authored examples and properties.
3. Implement using MoonBit ownership and idioms.
4. Compare behavior with permitted upstream API/docs/examples or verified fixtures.
5. Inspect upstream implementation only when it resolves a concrete question.
6. Record any substantial source-derived adaptation before it is treated as complete.

For every substantial translation or adaptation, add a record to
[`upstream.json`](upstream.json) with the exact upstream repository and SHA,
upstream paths, observed license and evidence, destination paths, method
(`translated`, `adapted`, or `independent_from_behavior`), and material
deviations. `independent_from_behavior` records an implementation that used
publicly observable behavior/API as a reference but did not copy source. Keep
records specific enough to review one source-to-destination relationship.
Update the record when code moves or its implementation method changes. The
current `records` list is empty: the M1 diagnostics/core code and reference-
model tests are original implementations of gpui.mbt contracts; no upstream
implementation source or test fixture was copied.

For an upstream revision update, review the diff for the pinned source paths,
explain which gpui.mbt contracts and tests change, decide whether each change is
required for the compatibility target, identify public API/dependency/platform
impact, then update the pin and records in the same review. Do not silently
chase upstream `main`.

## Fixture policy

New tests use gpui.mbt-original examples: small hand-authored trees, events,
text, and expected semantic outputs. Keep them minimal and representative; do
not paste upstream source snippets, test bodies, screenshots, sample
applications, font files, or other assets into runtime or test packages just
to create a fixture. Synthetic text and app data should be original and
deterministic.

The M1 reference/state-sequence tests in `testing/core_model/` use a small
independently written model and synthetic integer entity state. Command
sequences are generated from the local lifecycle contract, not copied from
GPUI tests or source. No upstream implementation code or fixture was copied
for this model.

M1 also adds the repository-owned `diagnostics/` and `core/` packages. Their
implementations follow gpui.mbt contracts and do not adapt upstream source;
the machine-readable `records` array therefore remains empty. The local
headless suite
`moon test primitives diagnostics core testing/core_model --target native --deny-warn`
passes 29 tests. That verifies only the named MoonBit packages and does not
replace the source, license, fixture, dependency, and notice audit required
before release.

An upstream fixture may be used only after its exact source path and license
are verified, its required attribution is retained, and the fixture record
names the source path, SHA, license evidence, destination, and any
modification. Binary/font/image fixtures also require a separate check of the
asset's own license and redistribution terms. A comparison based only on
public behavior should be rebuilt as an independent fixture and recorded as
`independent_from_behavior` when it materially informs an implementation.

## License, attribution, and release audit

When adapted material is redistributed, carry its applicable license and
attribution notices, mark modified files as required by that license, and
retain a readable NOTICE file if the source work includes one. The pinned GPUI
package tree has `LICENSE-APACHE` and no package-level NOTICE file; this M0
change adds no upstream-derived material, so it does not add a new repository
`NOTICE` file. Revisit this decision when the first adapted file or dependency
with a notice enters the project.

The `gpui` package's Apache-2.0 metadata applies to that package context. It
does not transfer any GPL license or source into gpui.mbt. Zed application
crates and other repository paths remain outside this package-level finding;
do not copy them into gpui.mbt under the GPUI Apache license. Before 1.0 and
each major release, audit source records, notices, licenses, fixture origins,
and dependency licenses separately, and verify no GPL-derived source entered
runtime packages.
