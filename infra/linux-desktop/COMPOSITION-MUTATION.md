# Portable composition mutation acceptance

The named local actrun `mutation` mode runs the independent composition oracle
and a fresh turtles job, followed by a fail-closed report audit. `quality` adds
these steps, separately qualified bounded proof and hotpath timing to the
existing fast Linux checks. Missing or blocked proof/timing stages cannot yield
a combined quality Green. Neither changes the default fast
loop or the three historical primitives/capability/MCP ratchets.

## Prepare once, then run locally

Use the already prepared pinned MoonBit/core **0.10.14+7d59c7ec9** profile and
official registry turtles **0.3.0**, producing report **schema 2**. The entrypoint
does not install a tool or contact the registry during acceptance.

```sh
moon install f4ah6o/turtles/cmd/turtles@0.3.0 \
  --bin "$GPUI_DESKTOP_ROOT/tools/turtles"
python3 infra/linux-desktop/actrun-feedback.py \
  --root "$GPUI_DESKTOP_ROOT" --mode mutation
```

An existing installation can be selected explicitly with `--turtles-bin`.
The standalone equivalent is:

```sh
python3 infra/linux-desktop/composition-mutation.py \
  --turtles-bin /absolute/path/to/turtles \
  --output /absolute/new/external/evidence-directory
```

## Honest selection and denominator

[`composition.toml`](../../mutation-scopes/composition.toml) selects the complete
`controls/text_field/composition.mbt` and `text/composition.mbt` files, with all
five existing operator groups. This is explicit file-scope acceptance, **not
changed-line selection**. In the composition change, the field file was new;
the underlying text file is also deliberately included as its transaction
dependency. No source skip markers or historical exclusions are added.

The first observation at the accepted composition tree discovered **19**
candidates: **16** in the field file and **3** in the underlying transaction
file. All 19 checked successfully and were qualified viable; **15 were killed,
4 survived, and none timed out or were unviable**. It took **52.68 seconds**,
including a fresh isolated baseline. These are actual attempted/qualified
counts, not hand-authored mutations or a count of oracle negative controls.
This initial run found missing unfocused UTF-8-adapter and commit checks; those
behaviors now have direct callback-free regression checks and independent
state-machine coverage. A fresh acceptance run must demonstrate their kills.
The first improved fresh run did: **17 killed / 19 viable**, **2 reviewed
equivalent survivors**, **0 timeouts/unviable**, in **52.58 seconds**. Both
previously surviving unfocused guards were attributed to the new tests.

Score remains `killed / (killed + survived + timeout)`. Unviable candidates are
reported separately and never called kills. Reviewed equivalents remain
**survivors in the raw score**. An empty or all-unviable job, timeout, missing
kill attribution, parse skip, stale review, source change, missing step, or tool
failure cannot be Green. `--fail-under 0` only lets turtles finish the report;
the subsequent audit is mandatory and rejects every unreviewed survivor.

[`composition-reviewed.json`](../../mutation-baselines/composition-reviewed.json)
contains exact identities, byte diffs, whole-file SHA-256 pins and reasoning for
two proposed public-state equivalences. The initial hidden-preview flag is
always overwritten before publication; blur's saved endpoint check repeats an
admitted immutable original-selection invariant. These classifications must be
independently reviewed. Updating the source invalidates a matching survivor's
old approval. New survivors require a test improvement or a new explicit review,
not a threshold reduction.
The admitted-snapshot rationale also pins its field admission, document/range
validation and copied-measurement dependencies. The retained diff bytes and
exact current survivor filename set must match the review; stale or empty raw
artifacts cannot pass.

The merged main `2de439f38682dfb55ae0f59864824f37a7017c20` appends only
`committed_document` to the selected field file. Independent review confirmed
that getter exposes an immutable original document and cannot observe either
mutant distinction. The two whole-file pins are refreshed for those exact
bytes; mutant identities/diffs and dependency pins are unchanged. Historical
counts above stay historical until a fresh campaign passes on this candidate.

## Independent reference and negative controls

The field oracle computes expected transitions using plain strings, integer
directional endpoints and detached undo/redo journals. It does not calculate
expectations using production `TextComposition`, replacement or field accessors.
It enumerates 1,000 three-operation traces from a known redo branch and uses
fixed seeds **1, 1777, 4242, 65535**, each for 256 operations, followed by exact
journal replay. Failures report seed, step and operation or the exhaustive trace
indexes. UTF-8 endpoint pairs include negative, scalar-interior, zero-length and
one-past offsets. Resize rollback retains the independently known original
geometry, reversed selection and redo.

Controlled corruptions alter both document and matching measurement, selection,
history entries/stacks and composition ownership; the matcher must reject them.
Altered reference expectations are rejected too. These are oracle sensitivity
checks, **not turtles kills** and not a proof of complete correctness. The fake
layout treats scalar boundaries as cursor stops; separate existing tests retain
hidden-grapheme cursor, admission-failure and geometry cases.

## Reports, caching and coverage limits

Every invocation creates a new external directory preserving the source
snapshot, exact command, CLI SHA-256, toolchain version, verified default-target
dry-run, configuration/source fingerprints, console, raw schema-2 report,
survivor diffs, property regression templates and audited summary. No outcome
cache or `--iterate` is used; turtles only keeps its own per-invocation worker
builds warm. The actual Moon default is verified as **wasm**; a changed default
fails until deliberately qualified. Tests run over the full portable module,
including both deterministic and fixed-seed properties, on an unchanged
isolated baseline before classification.
The fresh `--list` candidate set must exactly match the report, so omitted
candidates cannot improve the denominator. This qualified scope also rejects
any `UNVIABLE`: turtles 0.3.0 cannot distinguish a compiler rejection from every
other `moon check` failure in its report. A mixed check/tool failure therefore
cannot hide behind other valid kills. This is stricter qualification, not a
relabeling of unviable results as kills.

This denominator covers eligible scalar mutations in the two named files. It
does not mutate call omissions, history-recording logic in `history.mbt`, resize
logic in `model.mbt`, native owner/presentation rollback or Wayland transport.
Those behaviors are tested where stated, but test execution is not mutation
coverage. Registry 0.3.0 cannot select an explicit native target; native mutation
requires deliberate separate qualification. No tool source change, schema
migration, all-target claim, Rust/Kani equivalence or formal proof is implied.

The operating pattern follows the user's
[mutation/property-testing article](https://zenn.dev/mizchi/articles/rust-mutants-proptest-kani):
use genuine survivors to improve an independent behavioral oracle, retain
boundary witnesses, rerun the mutants, and review equivalents explicitly.
