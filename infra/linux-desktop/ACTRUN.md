# Fast local Linux text feedback

Use pinned `@mizchi/actrun` **0.32.0** for repeated Linux text checks on the
already-prepared cloud computer. This is a bounded feedback loop, not a full
GitHub Actions replacement. Existing hosted Ubuntu, macOS, Windows, browser,
contract and mutation gates are unchanged.

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

## Workload, records and safety

The local template runs exactly `sh scripts/test_linux_text.sh`: the three
private C raster/admission harnesses and the native Linux text MoonBit package.
It reuses the pinned toolchain, real PangoFT2/Fontconfig libraries and declared
font fixtures. Tests, assertions and warning policy are not weakened.

The template is stored here, outside hosted workflow discovery. Published
actrun 0.32.0 has workspace-inference quirks, so the entrypoint briefly creates a
uniquely named workflow in the checkout's `.github/workflows`, runs in explicit
local mode, and removes only that file in a `finally` block. The existing hosted
workflow files are never changed. Do not push the checkout while this temporary
workflow exists. Normal success/failure/interruption removes it; an uncatchable
process kill can leave the uniquely named file for manual inspection/removal.

Each invocation creates new external records under
`$GPUI_DESKTOP_ROOT/results/actrun-feedback/`, including doctor output, actrun
output, full task stdout/stderr, raw runner task durations and `summary.json`.
Use `--run-dir /absolute/new/external/directory` to choose the result destination.
The report distinguishes preflight, actrun and total wall time, verifies that
actrun used the candidate checkout, and fails if source state changed during the
run. Existing build caches are reused. No artificial sleeps or cache purges
are introduced. No desktop, global input, daemon or sandbox setting is touched.

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
The tested entrypoint's warm replay took **3.24 s** including doctor and source
snapshot checks; its clean replay took **10.54 s**. These are separate wrapper
measurements, not a relabeling of the original 2.11 s raw-runner median.

The complete hosted Ubuntu workflow took about 100 s in the historical run.
It includes a separate Wayland/GLES E2E job and is not comparable to this
headless subset. Keep hosted full CI and separate native-input evidence as final
gates. Published npm 0.32.0 also warned that the workflow's remote setup-moonbit
action was unsupported in its dry-run; the dedicated local workflow avoids
assuming that every hosted action is faithfully emulated.

Sources: [actrun](https://github.com/mizchi/actrun),
[official release](https://github.com/mizchi/actrun/releases/tag/v0.32.0), and
[historical hosted run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37403927714).
