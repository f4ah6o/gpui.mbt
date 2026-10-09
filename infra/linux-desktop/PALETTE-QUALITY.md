# Focused command-palette feedback

The application slice is the reusable `controls/command_palette` model and row
painter plus the Linux native palette fixture. This local gate helps test that
slice during development. The original `quality` mode retains its 15 foundation
stages; no new proof obligation or mutation-score threshold is added.

Use only the already-prepared profile and pinned official actrun 0.32.0 runner:

```sh
python3 infra/linux-desktop/actrun-feedback.py \
  --root /absolute/prepared-profile \
  --actrun-cli /absolute/actrun/node_modules/@mizchi/actrun/dist/actrun.js \
  --run-dir /absolute/new-external-run-directory \
  --mode palette
```

`palette` runs the component's reference/PBT/lifecycle tests on wasm and native.
It is the fast iteration path. `palette-quality` adds two bounded observations:

- Fresh official turtles 0.3.0 mutations of both complete declared state files,
  `picker.mbt` and `palette.mbt`, using all five configured operator groups.
  Discovery, exact source/test fingerprints, fresh outcome rows, attributed
  kills, unresolved diffs and raw logs are retained. Survivors are investigated
  as test gaps or invariant-equivalent changes. Counts remain honest; no score
  threshold, test skip, or reviewed-survivor suppression is applied. Actual
  `moon check` replays retain each UNVIABLE compiler log and distinguish
  warning-only rejection from compiler errors, separately from test kills.
- Seven alternating instrumented/plain pairs of the same native executable,
  with 128 commands, Japanese committed query and preview/commit composition,
  exact filtering, bounded eight visible rows, real Linux Pango shaping and
  admission, the shared `Picker.paint_items` native row builder, field painting,
  and `SceneSnapshot` assembly. Input, composition, filtering, visible-list and
  scene CPU spans are observed with the pinned hotpath runtime. Numeric state
  and canonical scene digests must agree in every on/off pair. Metrics contain
  no user text; exact source, compiler, libraries, fonts, executable, raw JSONL,
  clock diagnostics and empty-wrapper calibration are bound and retained.

Supply `--turtles-bin /absolute/official/turtles` and
`--hotpath-root /absolute/pinned/hotpath-checkout` for `palette-quality`.
Neither mode installs software or publishes a hosted workflow. All required
steps must complete, and source changes revoke a run's scoped green result.

Performance is observe-only. It measures a controlled headless CPU workload,
not Wayland transport, GPU rendering/presentation, scanout or hardware
input-to-display latency. Native app usability and real Japanese IME acceptance
are verified separately by the existing private-display palette probe. A scoped
palette pass does not claim the full foundation quality suite or native probe
passed.
