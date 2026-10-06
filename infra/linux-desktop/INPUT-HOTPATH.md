# Actual hotpath.mbt input profiling

`input-hotpath.py` is an opt-in local performance stage. It runs the actual
`f4ah6o/hotpath/src` library, not actrun's step stopwatch or existing C timers.
Keep `fast` cheap; select the explicit `performance` mode or the combined
`quality` mode when profiling current input/composition changes.

## Measured boundary

The fixed synthetic workload calls the production `TextField` APIs with real
PangoFT2 measurement and grayscale-raster admission providers. Named spans are
`input.handle`, `composition.update`, `composition.commit`,
`composition.cancel`, `history.undo`, `history.redo`, `text.measure`,
`text.admit`, `scene.paint`, and `scene.build`.

These are synchronous CPU spans. Outer composition/input spans include nested
measurement/admission and nested instrumentation cost; do not sum them as
exclusive time. Scene spans assemble copied scene data. They do not submit a
GPU frame or observe Wayland/compositor presentation. Native input transport,
display/scanout and hardware input-to-display latency remain outside this
stage. Existing native-case replay is still its own acceptance evidence.

The harness uses fixed public fixture strings only. Metrics contain the fixed
label vocabulary, durations, counts and numeric behavior fingerprints. No
document, selection, preedit, scene JSON or user-entered text is exported.

## Why the support-library extension is required

Upstream hotpath `be4cb98a3eb61bd5ab176c9e5e6bd921b74d1dce` stores integer
milliseconds, including its injected-clock API. Injecting ns into that API
would mislabel ns as ms. Scene assembly is demonstrably below one millisecond.
The additive `ProfilerNs` API records ns without changing `Profiler` or old
millisecond reports. It rejects invalid/backward clocks, reports dropped
samples, and flags saturated totals. Its fixed logarithmic histogram provides
bounded estimates; it does not retain raw observations.

`hotpath.lock.json` pins every runtime file by SHA-256 and records upstream and
local extension provenance, plus the verified local-to-published mapping.
Supply an already-present checkout matching those
bytes. No registry download, installation, live application hook or production
dependency is added automatically.

The fetchable recovery source is published main
`87a8d8494d5e2c2b4fed2115882315ba652dc37c`, tree
`f351f46137009ceaf864c12fd620fb8d23089c63`. Published feature
`4e69017c07948616106c7e0d478aa2db9fe58186` and reviewed local extension
`0c3c26c251ee9603923144b1863e97a825c7b05a` map to those identical bytes.
The local revision is historical provenance, not the only recovery authority.

```sh
git clone https://github.com/gpui-mbt/hotpath.mbt /absolute/external/hotpath.mbt
git -C /absolute/external/hotpath.mbt checkout --detach \
  87a8d8494d5e2c2b4fed2115882315ba652dc37c
```

The runner still verifies every runtime file hash after recovery. Earlier
measurements and their original recorded locks stay unchanged as genuine
observations of the same runtime bytes. The current-candidate gate requires
a new source-bound replay after a lock/provenance change; do not rewrite old
reports to pretend they were produced with the new manifest.

## Run

Use the already-prepared environment described in [ACTRUN.md](ACTRUN.md), then
set the explicit library checkout and invoke the local entrypoint:

```sh
export GPUI_HOTPATH_ROOT=/absolute/path/to/the/pinned/hotpath.mbt
python3 infra/linux-desktop/actrun-feedback.py \
  --root "$GPUI_DESKTOP_ROOT" --actrun-cli "$GPUI_ACTRUN_CLI" \
  --mode performance --run-dir /absolute/external/results/profile
```

The stage command is also independently reproducible in that prepared
environment:

```sh
python3 infra/linux-desktop/input-hotpath.py \
  --hotpath-root "$GPUI_HOTPATH_ROOT" --output /absolute/external/profile
```

The runner stages source inputs into a new external workspace with a local
`moon.work`. Only the staged compiler paths become absolute. The original
checkout stays unchanged and its before/after input digest must match. The
prepared profile marker must match the exact current lock and package set;
an older prefix or another active MoonBit executable fails before timing. The
nested workload is a separate Moon module, so production checks/builds do not
depend on hotpath. It compiles once in native release mode and launches the
same binary with profiling off/on. Old upstream warning27/79 are filtered for
this isolated fixture; other MoonBit warnings are denied. Compiler-generated C
warnings stay in the build log.

Each process warms up eight unrecorded cycles, then executes32 fixed cycles.
Seven paired repetitions alternate mode order. Profiling-on emits exactly800
raw observations per repetition with exact expected per-label counts. All
raw counts/totals/min/max must agree with the actual hotpath snapshot. The
fixed input, commit, cancel, undo/redo invariants and scene fingerprints must
match in every on/off run. Missing spans, clock failures, saturation, content
fields, mismatched aggregates or behavior differences fail the stage.

Artifacts include per-run JSONL raw samples, actual bounded-histogram
aggregates, clock diagnostics, build logs, source/library/binary hashes,
toolchain/profile/font fingerprints and `summary.json`. OS `CLOCK_MONOTONIC`
resolution and the observed smallest positive tick are separate fields.
Nanoseconds are storage units, not a promise of1ns accuracy. The checked native
adapter fails on unavailable clocks or Int64 conversion overflow.

Schema2 additionally retains a source/build staging manifest, exact producer
identity and a hashed inventory of the executable and raw files. Evidence
validation rereads those files, restores only the declared compiler-path
rewrite, verifies source/workload/library/binary identities, and recomputes all
statistics from strictly validated on/off observations. Typed success flags,
complete distinct pairs and behavior parity are mandatory. A truthy string,
forged summary statistics, stale bytes or missing raw files cannot qualify.

Build identity follows the actual Linux compiler wrapper: effective
`GPUI_LINUX_TEXT_CC`/`CC`, `PKG_CONFIG`, `CPPFLAGS`, `CFLAGS`, `LDFLAGS`, package
versions/cflags/libraries and discovery paths are recorded with resolved tool
paths, versions and SHA-256s. Relevant MoonBit, default C and font-discovery
tools are bound too. Multi-executable compiler/discovery wrappers are rejected
in this bounded harness rather than assigning them an inferred identity.

## Noise and overhead

The default performance policy is observe-only; stage success verifies the
measurement contract and behavior. It does not declare a speed improvement
or pass an arbitrary universal latency budget. The summary retains repeated
run means, medians and MADs, full workload timings, and empty-body calibration
for both the real hotpath API and the raw-sample wrapper. Raw samples and
library percentiles are not interchangeable: library quantiles are bucket
estimates. Do not subtract calibration from each sample to invent precision.
On/off workload variation can be larger than the instrumentation effect.

For a deliberately calibrated local regression check, provide a successful
baseline and an explicit relative tolerance:

```sh
python3 infra/linux-desktop/input-hotpath.py \
  --hotpath-root "$GPUI_HOTPATH_ROOT" --output /absolute/external/comparison \
  --baseline /absolute/external/prior/summary.json --relative-tolerance 0.10
```

`0.10` is an example chosen by the caller, not a default policy. The baseline
must match environment/toolchain/profile/font bytes, fixture, library and
behavior signature and producer. The baseline directory must retain its source,
library, workload, executable, manifest and raw JSONL files; an isolated copied
summary is insufficient. Each baseline is fully revalidated before comparison.
Prior production revisions may differ, with their own bound source snapshots.
Compare repeated per-label mean medians. The allowance
is the maximum of the selected relative budget, six combined MADs, measured
raw-wrapper cost, and reported clock resolution. This is a conservative
noise-aware heuristic, not a confidence interval. A mismatched environment
blocks comparison; a clear excess fails and names the label. Preserve raw
samples and inspect workload changes before updating a baseline.
