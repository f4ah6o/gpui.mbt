# Bounded real-mutant turtles stage

The opt-in `verification` actrun mode runs the actual source-checkout turtles
companion. `quality` also requires this named `turtles-verification` stage.
Default `fast`, the historical registry-schema-2 composition mutation ratchet,
and the separate pristine Moon proof remain separate and unchanged.

The stage supports only `TextRange::length` and UTF8/16 scalar widths. The
native helper model oracle, wasm production package oracle, and proof results
retain separate outcomes and denominators. Compiler/warning failures are
`UNVIABLE`, with their raw diagnostic reasons preserved; proof SAT never adds
to runtime kills. Mathematical-Int proof does not imply whole-language,
whole-transaction, GUI/FFI/IME or Kani equivalence.

The strict collector qualifies only the two observed UTF16 whole-condition
constant mutations' source-attributed unused-scalar diagnostics under
`--deny-warn`. A missing tool, crash, empty output or unrecognized compiler
diagnostic is unknown and blocks Green, rather than becoming `UNVIABLE`.

## Explicit source and executable pins

`turtles-verification.lock.json` pins the fetchable public turtles revision
`b91db91a00e5dd0cc2964f7fb7ed497a4256af10` and exact tree
`2693674efc52cf05da69fd474eb20ac0130bc4ff`. Publication changed commit metadata
from independently reviewed local `fd397e6e8563f1422e78ca667e66773142779ae3`;
all 104 tree blobs/modes and the adapter bytes are identical. The adapter's
SHA-256 stays `fc5d5134a876e86c1e05a259ddc756601ef2439997fdf273fa6926cc3d4620aa`.
The lock itself is hash-pinned in the runner before any import/process.
Intentional pin updates require explicit review, never an automatic upgrade.

Prepare a separate pinned source checkout outside GPUI:

```sh
git clone https://github.com/gpui-mbt/turtles.mbt.git /absolute/turtles-source
git -C /absolute/turtles-source checkout --detach b91db91a00e5dd0cc2964f7fb7ed497a4256af10
```

The runner requires the separately reviewed schema-3 native executable SHA-256
`07a62d16049d8ff03e43321b2f4579c6fab4b14fcc6149b0c0aca7dd89de3699` and profile
SHA-256 `95d03cf9c56140a5c7bdb5c67b5f7b3dfc8864cf91dd074184cc89e49fd88716`.
It does not use or overwrite the existing registry-schema-2 `GPUI_TURTLES_BIN`.
The source-checkout build is `moon build --target native --release`; its pinned
artifact must be supplied explicitly. Different build bytes require review.
The reviewed profile has schema1, `moonbit-composition-helpers-v1`, explicit
`packaging-39b1275` pilot, wasm production target, packages `text` and
`controls/text_field`, max64 mutants, 60-second per-command bound and that
schema-3 executable pin. The outer stage is bounded at 840 seconds.

## Invocation and collector contract

The wrapper supplies separate source/profile/schema-3 inputs and the existing
qualified Moon/Why3/Z3 paths. Its fixed stage is:

```sh
python3 infra/linux-desktop/turtles-verification.py \
  --repo "$PWD" \
  --turtles-root "$GPUI_TURTLES_VERIFICATION_ROOT" \
  --turtles-bin "$GPUI_TURTLES_SCHEMA3_BIN" \
  --profile "$GPUI_TURTLES_VERIFICATION_PROFILE" \
  --output "$GPUI_ACTRUN_RUN_DIR/turtles-verification" \
  --moon-home "$MOON_HOME" \
  --why3 "$GPUI_PROOF_WHY3" \
  --solver "$GPUI_PROOF_SOLVER" \
  --ephemeral-workflow "$GPUI_ACTRUN_WORKFLOW"
```

The output directory must be new and outside GPUI. The companion runs a fresh
actual full-source mutant campaign with fixed reviewed contracts and exact
raw compiler/Why3-export/Z3 results. A second consumer independently rechecks
the complete graph against current source, profile, tool/runtime identities,
exact single source edits, native model tests, production baselines, full goal
inventory, raw ledgers, and typed PBT regression/re-mutation artifacts.

The existing desktop profile supplies native FFI `LDFLAGS` and `CPPFLAGS`.
This primitive-helper/wasm leaf does not use them. Only the exact two values
freshly derived from the hash-pinned existing native environment provider,
under an empty inherited-flags environment and a matching installed-profile
marker/lock, are removed from a copied leaf environment. Original values,
provider/profile/marker hashes and the bounded derivation argv/status/output
are recorded; the collector derives the same context again. Appended or user
overrides, unknown providers/markers, `CC`, `CFLAGS` and `MOON_CC` remain
blocked. Other native/performance steps and global environment are unchanged.

The post-actrun collector calls `validate(output, repo, environment,
expected_workflow=...)`, where the workflow identity is exactly `{path,
sha256, mode}` attested by the parent. Only that generated random8/UUID32
workflow entry may disappear after cleanup. It must be present and identical
in the campaign's before/after manifests; all real source/tests/configuration
remain source-current. There is no blanket ignore or stale report reuse.

`invocation.json` records fresh UUID/timestamps, exact child argv/exit/duration,
source origin and hashes. It stays non-success during audit; interruption or
unknown/incomplete evidence cannot leave success. `audited-summary.json` is
written only after revalidation and bound back into the final invocation.
The parent repeats the validator before granting Green. Its discriminator is
`bounded-real-mutant-helper-verification`, and its summary keeps authentic
runtime kills, unviables, target-specific proof counterexamples and actual
regression replays separate. Solver concrete-model extraction is unsupported.

Run local rejection fixtures with:

```sh
python3 -m unittest discover -s infra/linux-desktop/tests -p test_turtles_verification.py -v
```

Synthetic fixture passes are not proof or workflow Green. Required evidence is
the real named actrun task completing on the exact current source with this
strict consumer, followed by the full requested quality mode when selected.
