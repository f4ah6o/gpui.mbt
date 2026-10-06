# Keyboard measurement boundaries

These historical measurements use the same bounded field/key scenario, but
different measurement clocks. They are not a combined wall-clock comparison.
Setup/install/build costs are separate.

- CUA failed-baseline attempt: **21.8 seconds**, summed tool execution only.
  This excludes model reasoning and orchestration time; the app did not pass.
- Automated baseline six-key attempt: **0.857232 seconds**, measured inside
  the runner from private display/compositor/app startup through input and
  oracle. It excludes the outer native launcher and also failed the baseline.
- Five independently verified fixed replays: median **0.830353 seconds**,
  minimum **0.793653**, maximum **0.899778**, using that same internal runner
  boundary. Every replay retained real compositor events and reviewed pixels.
- Cleanup-inclusive five-run batch: **4.465282 seconds**. Whole runner:
  **4.529437 seconds**. These are different totals, not additive components.
- Successful outer activation tool call: **3.1 seconds**. It overlaps the
  runner; exact combined wall time was not measured. Do not add 3.1 seconds to
  the runner's measurements or present that sum as measured end-to-end time.

The raw baseline and repeat captures are preserved under the original
`automated-e2e-2` and `automated-e2e-r5` artifact sets. The earlier setup errors
and OCR history are also retained; a later corrected oracle does not rewrite
those results. The separately recorded full-profile packaged replay in
`keyboard-validation.json` is a different measurement, including its cleanup.

No cross-host latency guarantee, physical-device coverage, all-pattern pass,
or Japanese IME qualification follows from these measurements.
