# Performance measurement contract

Status: M1 methodology; no benchmark suite, runtime baseline, or pass/fail result exists yet.

Performance claims require a reproducible workload, a named environment, and a
recorded baseline. M1 currently provides headless point, size, rectangle, color,
and input values; it has no representative scene, layout, text, renderer, or
lifecycle workload. No absolute latency or throughput claim is made. The 1.0
performance gate remains pending until each Tier 1 platform has a committed
method, baseline, and reviewed regression threshold.

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

Performance suite implementation begins with headless scene/layout/text
benchmarks, then adds native present timing and input latency once a backend
exists. This ordering keeps scene semantics measurable before a GPU backend is
available while leaving platform-dependent costs explicit.
