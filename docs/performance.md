# Performance measurement contract

Status: M1 methodology plus an Ubuntu native recovery-to-first-frame diagnostic;
no comparable release baseline or production performance pass exists yet.

Performance claims require a reproducible workload, a named environment, and a
recorded baseline. The current implementation has no comparable scene, layout,
text, steady-rendering, or lifecycle-memory baseline. Ubuntu CI can collect a
native recovery-to-first-frame timing workload, but it uses a headless Weston
compositor and the renderer reported by the active GL context. This diagnostic
does not establish absolute latency or throughput claims. The 1.0 performance
gate remains pending until each Tier 1 platform has a committed method,
comparable baseline, and reviewed regression threshold.

## Representative workloads

Benchmark fixtures must have stable IDs, deterministic inputs, and checksums.
Cover at least:

| Workload | Measurement |
| --- | --- |
| First frame | Process start to first presented frame; report p50/p95 and cold/warm setup separately |
| Steady scene | Frame construction and frame-time distribution for small, typical, and large scenes |
| Layout | Layout time by element count and constraint mix; include a large/deep tree |
| Text | Shaping, line layout, and cache behavior for Latin, Japanese, mixed scripts, emoji, combining marks, and bidi fixtures |
| Input response | Input-to-next-frame latency proxy with the event sequence and display refresh rate recorded |
| Renderer | Scene upload/submit/present time where measurable; report surface/device recovery separately |
| Lifecycle memory | Resident/allocated memory across repeated window/entity/resource create-destroy cycles |

Do not combine fixture construction time with the operation being measured
unless that setup is explicitly part of the user-visible path. Record warmup,
sample count, timer source, compiler/build mode, optimization flags, target,
runner image, CPU/GPU class, OS version, fonts, scale factor, refresh rate,
locale, renderer, and relevant device driver.

## Baseline and regression policy

For each Tier 1 platform and pinned CI environment, capture at least 30 samples
per benchmark after warmup and store the median, p95, spread, and raw samples.
Establish the baseline from a reviewed known-good revision. Do not compare
unlike runner classes or infer an absolute cross-machine claim from shared
noisy runners.

The initial regression rule is a 10% slowdown at p50 or p95 over the reviewed
baseline, confirmed in two independent runs on the same pinned runner class.
For memory, a monotonic increase across repeated lifecycle batches or more than
5% retained growth from the first to the final stable batch blocks until
explained. These are initial ratchet rules; before they become blocking, record
runner variance and calibrate the thresholds using implementation data. Any
calibration must keep a named owner, rationale, and old/new threshold in the
benchmark report. Do not loosen thresholds solely to clear a regression.

Per-frame targets should be expressed against the display budget (for example,
16.7 ms at 60 Hz or 8.3 ms at 120 Hz) and reported by percentile. These are
display deadlines, not claims that the current framework meets them. A
release-blocking frame-pacing defect blocks readiness even if the aggregate
median passes.

## Reporting and release evidence

Each benchmark report includes source revision, fixture IDs/checksums, toolchain,
environment, raw samples, summary statistics, baseline revision, threshold,
and pass/fail result. Retain the report and workload manifest as release-gate
evidence. A performance pass without a comparable Tier 1 baseline is invalid.

The next performance work should add headless scene/layout/text workloads and
steady native present/input timing. The recovery diagnostic below measures a
specific platform boundary, not those missing workloads.

## Active Ubuntu recovery diagnostic

[`scripts/benchmark_ubuntu.py`](../scripts/benchmark_ubuntu.py) runs the existing
Wayland native E2E with `GPUI_BENCH_UBUNTU=1`. The C test warms up through the
first five recovery cycles, then records 30 samples at each advertised integer
scale (1x and 2x). Each sample uses `CLOCK_MONOTONIC` from renderer recovery to
the next Wayland frame callback. This is a recovery-to-first-frame measure; it
does not represent steady-state frame pacing or physical-GPU behavior.

The JSON report includes every raw duration, nearest-rank p95, median p50,
minimum/maximum, test-fixture checksum, `HEAD`, dirty-worktree flag and digest,
Moon/compiler versions, runner/CPU, actual GL renderer, and a unique run ID.
The workflow stores it with the native E2E logs. By default the comparison state
is `no_baseline`; a successful measurement only means the workload ran and
produced all samples.

The comparator rejects reports with missing environment details, different
runner/renderer/toolchain/workload signatures, fewer than 30 samples, or
summaries inconsistent with the raw samples. An optional comparison requires
two distinct live runs on the same candidate revision and worktree. It reports
a confirmed regression only when p50 or p95 exceeds the threshold in both runs;
one-run spikes remain inconclusive. Replayed logs are marked unverified and
cannot serve as performance evidence. CI does not currently compare against a
reviewed baseline, so this report does not promote the release ledger.
