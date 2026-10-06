# Composition helper proof pilot

This is a deliberately small, source-corresponding proof package. It preserves the executable bodies of three production helpers:

- `text/range.mbt::TextRange::length`: for `0 <= start <= end <= Int.MAX_VALUE`, the difference is exact and within `0..Int.MAX_VALUE`.
- `text/document.mbt::utf8_scalar_width`: the exact 1/2/3/4-byte partition for a valid Unicode scalar.
- `text/document.mbt::utf16_scalar_width`: the exact 1/2-code-unit partition for a valid Unicode scalar.

The production composition transaction calls this range and Unicode foundation. This does not establish correctness of the whole transaction, its callers, decoding, GUI, FFI, or native IME protocol. The copied `TextRange` has identical fields; unused `Eq` derivation and extensions are excluded. The runner checks the complete target declarations against production, allowing only proof contracts, whitespace and optional trailing argument commas. A source change fails correspondence until reviewed proof code is updated.

## Run

Use the production pin and the hash-locked Z3 executable from `proof-toolchain.lock.json`:

```sh
python3 infra/linux-desktop/composition-proof.py \
  --source-root "$PWD" \
  --artifact-dir /absolute/new/evidence-directory \
  --moon-home "$MOON_HOME" \
  --solver /absolute/user-prefix/usr/bin/z3 \
  --why3 /absolute/reviewed-prefix/bin/why3
```

The artifact directory must be fresh and outside the source checkout. Each run receives a new UUID and an atomic initial non-success result. A reused directory is rejected; its previous summary is archived and the current summary becomes failed. Catchable interruptions clean up owned process groups and persist a terminal non-success result. Full source snapshots before and after must match, in addition to the selected source/contract hashes.

`--solver` can also come from `GPUI_PROOF_SOLVER`, `Z3PATH`, or `PATH`. This script does not download or install anything. The locked official Debian package can be extracted into a user-owned prefix after its SHA-256 is checked. No production toolchain upgrade or system installation is required.

The package contains a scalar precondition-witness lemma and an executable range-witness assertion and native boundary tests. Two controls modify executable bodies while retaining their original specifications: reverse range subtraction; exclude ASCII U+007F from the one-byte branch. Both must compile, exhibit a runtime counterexample, and be rejected by the verifier. A timeout, crash, or missing report is never sufficient evidence for a negative control. The qualified export backend requires actual SAT on the mutated target and UNSAT on all other goals.

## Evidence and trust

`proof-result.json` separates source correspondence, typechecking, WhyML generation, native tests, solver results and mutant results. `ok: true` and `status: passed` require a nonempty all-valid structured solver report and both rejected controls. Unknown or timeout in a positive proof is never success. Negative unknown is explicitly recorded as unproved, not a solver-produced counterexample.

MoonBit verification uses mathematical integers. The range proof explicitly constrains the operands and result so this particular subtraction fits machine `Int`; it does not claim general machine-integer verification. The pilot adds no axiomatized contract or external proof stub. It trusts the pinned compiler, Why3/prelude and solver, and assumes callers establish the stated input validity. Concrete witnesses keep preconditions visibly inhabited.

The native-server backend is diagnostic-only and cannot qualify any proof result until its schema and actual server path are separately hardened and rerun. The separate socket-free backend uses `moonc prove -emit-only`, official Why3 task inventory and export, and direct Z3 on the unedited exported files. It does not fabricate a native compiler solver report.

The current compiler accepts these primitive/struct helpers. It rejects the production `checked_resulting_length` proof attempt because the imported `Result` constructors and patterns are not supported in its verification lowering. That helper is excluded rather than replaced with a model claimed as the implementation.

## Current validation

The default server route remains blocked: official Why3server cannot bind its local Unix socket in the restricted execution context, and an admitted 60-second attempt ended without a solver report. No socket shim, settings change, or desktop/browser bridge is used.

The separate documented export route is qualified. A hash-verified official Why3 `1.7.2` CLI was built with verified official Debian OCaml packages in an isolated user prefix. Add:

```sh
--why3 /absolute/user-prefix/bin/why3
```

or set `GPUI_PROOF_WHY3`. The runner clears inherited Why3 configuration/loadpath settings. It creates an exact fresh config with no configured plugins, disables automatic standard-library/plugin loading, and adds only the pinned prelude and bundled standard-library directories. It probes the CLI’s compiled library directory and hashes the actual command plugin loaded there; relocated binaries with a different adjacent prefix are rejected. Configuration text/hash, effective bindings and bounded version/libdir probe logs are retained.

The script inventories the exact five pinned WhyML goal IDs, uses official `inline_all` and `remove_unused` transformations, then the unchanged bundled `z3_471.drv` driver to export all goals. No goal-selection filters or hand-edited SMT-LIB are used. The transformation names, exact goal count/identities, task hashes, commands, raw solver output and measured duration are persisted separately in each `*-export-report.json`.

The complete pilot establishes 5/5 positive UNSAT results. The range-subtraction mutant produces SAT only on the range goal; the U+007F mutant produces SAT only on the UTF-8-width goal. Their other four goals remain UNSAT and native boundary tests expose both faults. The pilot completes in roughly five seconds here; that is observed timing, not a universal performance threshold.

## Setup and recovery contract

The current qualified runtime is the hash-locked local build. `proof-recovery.lock.json` commits all 13 official Debian OCaml package URLs/versions/SHA-256 values and the official Why3 source archive/checksum provenance. A source-build recovery recipe is available:

```sh
python3 infra/linux-desktop/recover-proof-export.py \
  --destination /absolute/fresh/owned/tools-directory \
  --archive-cache /absolute/verified-archive-cache
```

The cache is optional. Every archive is verified before extraction. The recipe uses isolated prefixes, the locked configure flags, and `make install-bin install-data`; it does not run upstream completion or system-install targets. Host prerequisites are Debian 13 amd64, compatible libc, curl, dpkg-deb, GCC and make. No production Moon toolchain changes are made.

A fresh-prefix recovery build was observed to finish in about 32 seconds using cached verified archives. It is explicitly `built-unqualified`: Why3 embeds its configured absolute prefix, so CLI/plugin hashes changed. This is source-build recovery, not a portable or bit-identical bootstrap guarantee. The recipe never rewrites the reviewed runtime lock. A different-prefix rebuild needs an explicit pin update, independent review of actual plugin/config/loadpath bindings, and rerunning all five positive goals and both controls before use. The current runner rejects that new binary until this happens.

## Future turtles adapter boundary

The two current negative controls are sanity checks that mutate the extracted proof module. This pilot does not run formal verification on arbitrary turtles mutants and does not add a mutation-kill score.

A future per-mutant adapter must regenerate or verify each executable target body against that isolated mutant, while holding the reviewed contract fixed. Bind the production/mutant source hash, extracted executable-body correspondence, contract hash and proof toolchain to every result. A stale template/source mismatch is inconclusive, not a synthetic kill. Unsupported lowering, including the current imported `Result` limitation, unknown and timeout must stay distinct from a proved property or a counterexample. Only a genuine solver result for the corresponding mutant may affect a proof-based kill classification.

## Relationship to Kani

This can fill the proof stage in a mutation/property/proof workflow, but is not a drop-in Kani equivalent. Kani uses bounded model checking on Rust proof harnesses and checks machine-level safety properties. MoonBit's experimental contract/invariant pipeline lowers supported code to Why3, and currently uses mathematical integers. Keep mutation tests and independent property tests; require genuine solver evidence for only the named supported proof scope.

Sources:
- [MoonBit stable formal verification](https://docs.moonbitlang.com/en/stable/language/verification.html)
- [Pinned Moon proof report schema](https://github.com/moonbitlang/moon/blob/914d7da/crates/moon/src/cli/prove.rs#L559-L577)
- [Kani verification results](https://model-checking.github.io/kani/verification-results.html)
- [Why3 task export](https://why3.org/doc/manpages.html#the-prove-command)
