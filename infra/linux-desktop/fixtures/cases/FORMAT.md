# OS-input cases, version 1

This is a bounded Linux XTest → private authenticated Xvfb → Weston X11 →
actual `wl_keyboard` → GPUI test catalog, not a general UI automation language.
`input_cases.py` is the authoritative strict schema/validator. It uses the
Python standard library; running cases additionally needs the declared desktop
profile and its Pillow/ImageMagick/Tesseract host oracle prerequisites.

## Select and validate

From the repository root:

```sh
python3 infra/linux-desktop/input_cases.py --list
python3 infra/linux-desktop/input_cases.py --case basic-text-shift
python3 infra/linux-desktop/input_cases.py --all
python3 infra/linux-desktop/case_runner.py --validate --all
```

`--case` accepts a catalog name or a JSON filename. `--cases-dir` selects a
separate reviewed catalog. These commands never connect to a display, load
Xlib or launch an application.

In an **authorized native process-launch context**, select one case or all:

```sh
python3 infra/linux-desktop/case_runner.py \
  --case basic-text-shift \
  --prefix /private/profile/prefix \
  --repo /reviewed/source-checkout \
  --app /reviewed/linux_text_field.exe \
  --app-sha256 REVIEWED_SHA256 \
  --fontconfig /reviewed/fonts.conf \
  --source-patch /reviewed/native-unmapped-key.patch \
  --output /new/artifact-directory
# Replace --case basic-text-shift with --all for the catalog.
```

The exact app, source commit/tree, source patch and font configuration must
match each ready case. Before process startup, the prefix must also contain
the locked `xkb-data` rules/keycodes/symbols/types/compat resources. A minimal
prefix missing these stops with a clear setup error; it does not silently use
host XKB data. Resource hashes are recorded with runtime provenance. The output directory must be new. `--all` uses a single
reviewed app/source profile and records skipped coverage explicitly; exit 0
means its **executed** cases met their oracles, not that pending/unsupported
cases passed. If none are runnable, it writes explicit skipped coverage and
exits 3. A selected blocked case exits 3 before runtime input/process
access. An existing output directory is never silently reused. The desktop
launcher helper accepts an explicit `--runner` for this runner; it does not
turn a denied shell/IPC context into an authorized one.

## Record structure

Every JSON case has these required fields. Unknown fields are errors.

- `version`: integer 1. Other versions are rejected.
- `id`, `description`: a stable lowercase hyphenated name and purpose.
- `platform`: exactly `linux-x11-weston`.
- `disposition`, `reason`: `supported`, `pending`, `unsupported`, or
  `expected-failure`, with an explanation. Support is distinct from a run's
  pass/fail status.
- `timeout_ms`: whole-case budget, 1–60 seconds, with bounded cleanup afterward.
- `initial`: expected text, directional selection `{anchor, head}` and
  `focused` boolean before case input. Offsets are UTF-16 code units, within
  the text and never inside a surrogate pair.
- `focus_click`: a concrete pointer click in the private 960×480 display.
- `steps`: named phases with `events` and an exact `expect` state. Final state
  is the last phase's expectation. At most 32 phases/256 events are allowed.
- `oracle`: a reviewed oracle or an explicit pending reason.
- `expected_failure`: null, or an exact known mismatching observed state for
  an `expected-failure` case. A different failure does not count as its xfail.
- `artifacts`: the mandatory fixed artifact list. Cases cannot choose output
  paths or omit logs/pixels.
- `provenance`: reviewed source commit/tree, app/patch/fontconfig SHA-256 pins
  and explanatory notes. Pending cases may leave runtime pins null. Pinning
  bytes does not assert they were compiled from the recorded source.

The five event types are intentionally small:

- `key`: `keysym` and `modifiers` (`Control_L`, `Shift_L` only), expanded into
  actual balanced modifier/key presses and releases.
- `hold`: the same fields plus `duration_ms` (1–2000). One actual press is held
  and released; native/compositor repeat is observed, never fabricated by the
  runner. A repeat case needs a reviewed repeat policy before activation.
- `focus`: `target` is `app` or `away`. Focus changes use actual XSetInputFocus
  on verified private-root windows; `away` creates a tiny owned private decoy.
  Actual Wayland keyboard leave/enter must confirm the transition. Away-target
  keys remain in the OS ledger and are excluded from GPUI delivery counts.
- `click`: integer private-display `x`/`y`; actual motion and button events.
- `wait`: bounded `duration_ms` (1–2000).

The validator accepts a deliberately small keysym set. There is no text,
paste, composition, GPUI callback, shell command or arbitrary file operation
in the case language. Japanese literals in expectations do not count as IME.

## Oracles and evidence

`reviewed_pixels` supports only the exact existing six-key scenario and its
reviewed RGBA hash. The final full frame must match, the app must stay alive,
no native/owner failure may occur, and exactly 14 native Wayland key events
must be present. OCR covers the ASCII prefix/suffix only. Initial-state
coverage for this historical scenario is the accepted source literal,
controlled end-of-field click and retained initial pixels; it has no integrated
state observer. No command creates/blesses a new golden.

The approved `presented_state` contract observes the real OS-driven field
only after successful presentation. The example's observer is off by default
and is enabled solely with `GPUI_FIELD_E2E_STATE=1`. Each stdout line starts
with `GPUI_FIELD_STATE ` and then JSON:

```json
{"version":1,"presentation":1,"text":"Hello 日本","selection":{"anchor":8,"head":8},"focused":true,"revision":1}
```

The parser enforces exact fields, integer types, UTF-16 bounds and increasing
positive presentation counters. The runner checks initial/checkpoint text,
selection and focus, captures pixels **after** matched presentation, verifies
nonblank 960×480 field pixels, retains native logs, and checks liveness and
actual keyboard-event delivery to the verified intended target. Field-level blur
keeps the client focused and still receives keyboard events; native private-window
focus loss routes keys to the owned decoy and must not deliver them to GPUI.
A no-op phase may retain its prior presentation
counter but must still receive its real native keyboard events. Retained
pixels are paired evidence, not automatically promoted to goldens. Activating
an observer case requires the reviewed observer binary/source pins and an
explicit review note.

Each executed case starts a fresh authenticated high-numbered display, Weston
and app. It excludes inherited `DISPLAY`, refuses occupied X socket/lock
numbers, and verifies the actual Weston output ID belongs to that private
X root before input. Runtime sockets/cookie live in a new owned mode-0700
short `/tmp/gpe-*` directory with an AF_UNIX pathname-length guard. Artifacts
stay in the chosen output. Only owned children are terminated; the runtime
and ephemeral cookie are removed after cleanup. There is no live-display
fallback or retry around an access denial.

`events.jsonl` records both semantic intent and successful concrete XTest
key/motion/button events. `app.log` contains the actual Wayland protocol events;
intent alone is never the delivery oracle. Each result records hashes,
expectations, checkpoint pixels/state, timing, process health and status.
`summary.json` reports executed/skipped totals and whether all cases actually
executed.

## Current cases

Only `basic-text-shift` is ready under the frozen modifier-fix profile.
`ctrl-a-replacement` is a planned expected failure because the accepted
control handles Ctrl+Z/Y/C/X/V but does not implement Ctrl+A. Cursor/deletion,
Undo/Redo, branch edits, focus reentry and standalone modifiers remain pending
exact-state observation. Held repeat remains pending native-repeat integration
and reviewed rate/delay. IME remains unsupported until a real GPUI adapter can
expose preedit, conversion/candidates, commit and cancel; version 1 cannot fake
those stages.

Validation is not desktop acceptance. Preserve actual failed evidence before
changing a fixture's disposition or source pins; review new behavioral results
before promoting them.
