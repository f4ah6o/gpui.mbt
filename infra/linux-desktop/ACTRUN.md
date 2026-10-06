# Local Linux acceptance with actrun

Use pinned `@mizchi/actrun` **0.32.0** on the already-prepared Linux computer.
For current Linux development, a passing declared local mode is **Green for
that mode's scope**; hosted GitHub Actions are not a prerequisite or a wait gate.
Hosted workflow files/settings are unchanged. This policy does not promote
untested platforms, pending IME/repeat cases, or production release evidence.

- Default `fast`: contracts/Python tests, Linux infrastructure and Mozc safety
  guards, read-only IME owner safety and native direct/repeat/experimental IME
  ingress checks, formatting, three C text harnesses, the Linux text package,
  and warning-denied native checks/tests for `text`, `controls/text_field`,
  `platform`, `ubuntu`, and the field example's owner/controller tests.
- `--mode acceptance`: the same common checks, all Linux-runnable MoonBit
  targets, then a freshly built manifest-bound candidate and every ready native
  private-display keyboard case. IPC/oracle prerequisites are required. A denied
  IPC probe fails this mode; it is never converted into a skipped Green.
- `--mode headless`: the original three C harnesses plus Linux text package
  only, for the shortest geometry loop. Its pass is explicitly subset-scoped.
- `--mode mutation`: independent composition state-machine/boundary oracle,
  then fresh turtles 0.3.0/schema-2 file-scope mutation and reviewed-survivor
  audit. See [exact scope, setup and limits](COMPOSITION-MUTATION.md).
- `--mode proof`: the separately qualified bounded Moon proof and its negative
  controls. Missing tools, blocked IPC, unknown or timed-out proof cannot pass.
- `--mode verification`: actual turtles schema-3 helper mutants, each checked
  against the portable runtime/PBT suite and independently fixed source-exact
  proof contracts. The strict collector reopens the fresh campaign's source,
  edit, compiler, test and solver evidence. Sanity controls are never mutants.
- `--mode performance`: the pinned hotpath input workload using an explicit
  support-library checkout.
- `--mode quality`: fast checks, composition mutation, bounded proof, actual
  helper-mutant verification, and hotpath workload. Every requested stage is required; incomplete installation
  or qualification leaves this combined mode failed/not-run. Keep this longer
  qualification outside the repeated fast loop.

Fast mode is the repeated-development gate for these affected Linux packages.
Choose acceptance when qualifying a current native input/render candidate or
when wider portable coverage is needed. Changes outside the named affected
packages need their relevant additional checks. The wider mode does not run
macOS/Windows native, browser proof, mutation, MCP stdio interoperability, or
the separate Ubuntu scale/readback/lifecycle GPU suite;
these are explicit separate scopes rather than silently passing checks.
Mutation is now available through its own named local mode; the wider native
acceptance mode continues to report that scope separately.

## Prepare once

First bootstrap the exact Debian desktop profile and retain its verified archive
cache as described in [README.md](README.md). The profile must be outside the
checkout. `doctor --build-only` must pass; this does not require or claim desktop
IPC, GUI input, IME, compositor or native screenshot validation.

Install the named official npm package into that external profile, with lifecycle
scripts disabled. Node.js 18 or newer and npm are explicit host prerequisites.
The entrypoint does not install software or contact package registries itself.

```sh
export GPUI_DESKTOP_ROOT=/absolute/path/to/your/external/profile
npm install --prefix "$GPUI_DESKTOP_ROOT/tools/actrun" \
  --cache "$GPUI_DESKTOP_ROOT/cache/npm" \
  --ignore-scripts --no-audit --no-fund --save-exact @mizchi/actrun@0.32.0
python3 infra/linux-desktop/actrun-feedback.py --root "$GPUI_DESKTOP_ROOT"
```

For an existing pinned installation, pass its exact `dist/actrun.js`:

```sh
python3 infra/linux-desktop/actrun-feedback.py --root "$GPUI_DESKTOP_ROOT" \
  --actrun-cli /absolute/path/to/node_modules/@mizchi/actrun/dist/actrun.js
```

The lock records the official npm tarball/integrity and the installed CLI's
SHA-256. Both package identity/version and CLI bytes must match before execution.
The explicit profile doctor runs every time before actrun. No hosted setup step
is disabled or replaced with a blanket no-op.

### Real-mutant helper verification

Keep the separately reviewed turtles source checkout, schema-3 executable and
bounded helper profile outside this checkout. Their identities are pinned by
the verification integration lock. See the [exact public pin, reset recipe and
scope](TURTLES-VERIFICATION.md). They are separate inputs from the official
turtles 0.3.0/schema-2 executable used by composition mutation. The entrypoint
does not install or upgrade either tool.

```sh
python3 infra/linux-desktop/actrun-feedback.py --root "$GPUI_DESKTOP_ROOT" \
  --mode verification \
  --turtles-verification-root "$GPUI_TURTLES_VERIFICATION_ROOT" \
  --turtles-schema3-bin "$GPUI_TURTLES_SCHEMA3_BIN" \
  --turtles-verification-profile "$GPUI_TURTLES_VERIFICATION_PROFILE" \
  --proof-why3 "$GPUI_PROOF_WHY3" --proof-solver "$GPUI_PROOF_SOLVER"
```

Those explicit environment variables may instead be inherited by the runner.
`quality` requires the same inputs plus the composition `--turtles-bin` and
performance `--hotpath-root` inputs. Missing tools or an unreviewed profile
leave the requested stage failed/not-run. The denominator is the bounded
eligible helper scope, not every mutation in GPUI. Runtime/PBT kills, real SAT
proof kills, unviable candidates and inconclusive outcomes remain separate in
the retained report. Unknown, timeout, stale source or changed fixed contracts
cannot become proof kills or a combined quality Green.

## Workload, records and safety

Each mode composes existing repository checks through ordinary local actrun
shell steps; no remote setup actions are mocked. The pinned toolchain, real
PangoFT2/Fontconfig libraries and declared fonts are reused. Tests, assertions
and warning policy are not weakened.

```sh
# Default: repeated affected-Linux acceptance
python3 infra/linux-desktop/actrun-feedback.py --root "$GPUI_DESKTOP_ROOT"
# Wider qualification, in the supported native process-launch context
python3 infra/linux-desktop/actrun-feedback.py --root "$GPUI_DESKTOP_ROOT" --mode acceptance
# Historical narrow geometry workload
python3 infra/linux-desktop/actrun-feedback.py --root "$GPUI_DESKTOP_ROOT" --mode headless
```

Acceptance reuses the profile and external build cache, writes its own fresh
build manifest/bundle under the run directory, and preserves the profile's
previous `field-build.json` and `field-binary.txt`. The native runner uses only
an authenticated fresh private Xvfb/Weston display. It does not inject input into
the live desktop. If this shell denies IPC, stop; the same entrypoint can run
from the already-supported authorized native desktop launcher. No sandbox or
permission changes are a fallback.

The current native catalog has seven ready cases and explicit skips for the
adaptive held-repeat oracle and unsupported GPUI IME composition. The separate
historical held-repeat proof remains historical; it is not counted as this
catalog case or as a replay of a new binary.

The historical headless template is stored here, outside hosted workflow discovery;
fast/acceptance templates are generated from fixed steps in the entrypoint. Published
actrun 0.32.0 has workspace-inference quirks, so the entrypoint briefly creates a
uniquely named workflow in the checkout's `.github/workflows`, runs in explicit
local mode, and removes only that file in a `finally` block. The existing hosted
workflow files are never changed. The narrow gitignore rule for this generated
filename keeps it outside candidate source manifests, so the persisted native
bundle remains verifiable after cleanup. The exact workflow bytes/hash are kept
in the run record. The real-mutant verification collector accepts only this
parent-attested exact workflow path, hash and file mode when comparing the
campaign to current source after cleanup. Other files have no such exception.
Do not force-add or push this temporary workflow. Normal success/failure/interruption removes it; an uncatchable
process kill can leave the uniquely named file for manual inspection/removal.

Each invocation creates new external records under
`$GPUI_DESKTOP_ROOT/results/actrun-feedback/`, including doctor output, actrun
output, full task stdout/stderr, raw runner task durations and `summary.json`.
Use `--run-dir /absolute/new/external/directory` to choose the result destination.
The report distinguishes preflight, actrun and total wall time, required steps
that passed/failed/were not run, and explicit skipped scopes/native cases.
`ok` and `green_scope` describe only the selected mode. A required missing or
skipped step revokes Green. The report verifies the candidate checkout and fails
if source state changed during the run. Existing build caches are reused. No artificial sleeps or cache purges
are introduced. No live-desktop/global-input, daemon or sandbox setting is changed; acceptance
starts and cleans up only its owned private native-test processes.

## Measured choice

[Raw recorded timings and workload evidence](evidence/actrun-headless-20261006.json)
come from one clean source build followed by three warm runs, against 38 workload
and dependency files byte-identical to hosted main commit
`36bcb245845354b955a2f1bb2f07b527f4f39c4f`.

- Local actrun: clean **10.78 s**; warm **2.11 / 2.22 / 2.10 s**
- Historical hosted headless job: **43 s** from run creation through job finish,
  including **3 s** queue/startup; the test step itself took about **7 s**
- Fresh local profile recovery from an already-verified offline archive cache:
  **10.50 s**, before the clean source build

The warm local loop is the adopted repeated-development route. Cold test
execution alone was faster on the hosted sample; this is not evidence that the
local computer always computes faster. Cached recovery plus clean execution
was about 21.28 s, excluding actrun installation, network downloads and computer
startup. A fully empty-cache/bootstrap comparison was not measured.

The local machine was Debian 13 amd64 with PangoFT2 1.56.3; the hosted machine
was Ubuntu 24.04 with PangoFT2 1.52.1. Both used Fontconfig 2.15.0 and the
same pinned MoonBit/core 0.10.14+7d59c7ec9. The same source/tests are compared,
but the distribution/native library stack differs. The original benchmark
timings include the actrun process but exclude this new entrypoint's doctor;
each current invocation records the additional preflight and total time.
The original headless entrypoint's warm replay took **3.24 s** including doctor and source
snapshot checks; its clean replay took **10.54 s**. These are separate wrapper
measurements, not a relabeling of the original 2.11 s raw-runner median.

The complete hosted Ubuntu workflow took about 100 s in the historical run.
It includes a separate Wayland/GLES E2E job and is not comparable to this
headless subset. These historical timings do not measure the expanded fast or
acceptance modes. Current Linux acceptance uses the declared local mode and
does not wait for hosted CI. Native claims still require actual native replay
of that candidate. Published npm 0.32.0 also warned that the workflow's remote setup-moonbit
action was unsupported in its dry-run; the dedicated local workflow avoids
assuming that every hosted action is faithfully emulated.

Sources: [actrun](https://github.com/mizchi/actrun),
[official release](https://github.com/mizchi/actrun/releases/tag/v0.32.0), and
[historical hosted run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37403927714).
