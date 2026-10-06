# Reusable OS-input cases, version 2

This is a bounded Linux XTest → private authenticated Xvfb → Weston X11 →
actual `wl_keyboard` → GPUI test catalog, not a general UI automation language.
`input_cases.py` is the authoritative strict v1/v2 schema/validator. The default
v2 catalog separates semantic expectations from candidate build identity;
`fixtures/cases-v1` preserves the original strict pinned replay catalog. It uses the
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

Build, prepare and run without editing any committed case hashes:

```sh
python3 infra/linux-desktop/gpui-desktop.py --root /private/profile build
python3 infra/linux-desktop/candidate_bundle.py prepare \
  --profile-root /private/profile --output /new/candidate-bundle
python3 infra/linux-desktop/candidate_bundle.py verify /new/candidate-bundle
# In an authorized native process-launch context:
python3 infra/linux-desktop/case_runner.py --candidate /new/candidate-bundle \
  --case basic-text-shift --output /new/artifact-directory
# Replace --case basic-text-shift with --all for the ready catalog.
```

`build` writes `field-build.json` with unchanged before/after source identity,
its exact command/output, toolchain/core/runtime/protocol identities and font
inventory. `prepare` verifies that record and copies app, tracked source patch,
Fontconfig bytes and build-manifest bytes into a fresh outside-repo bundle.
All copied files and the candidate manifest have recorded SHA-256 identities.
The live Fontconfig keeps its original base for relative paths. Runtime verifies
source HEAD/tree/dirty tracked patch/untracked file identities, copied bytes
and captured external runtime/toolchain/fonts before OS input. It executes the
copied app, so a later rebuild may overwrite the original build-output path
without silently changing an existing candidate. Source or external runtime
changes still invalidate that candidate.

An explicitly supplied existing app can be captured with `prepare --bind-app
EXE --repo SOURCE --profile-root PROFILE [--fontconfig CONFIG] --output NEW`.
That bundle is labeled `bound`: it records the association at capture time and
does not claim the executable was compiled from that source. Normal built
bundles retain recorded build derivation. Neither route alters semantic JSON,
produces a golden or accepts new outputs automatically.

V2 requires `--candidate` and refuses source/app/font runtime overrides. A new
normal build changes only its external manifest/bundle, not semantic cases.
Both output directories must be new. `--all` records skipped coverage; exit 0
means its executed cases met their oracles, not that pending/unsupported cases
passed. If none are runnable, it reports `skipped-no-runnable-cases` and exits
3, even without an output path. A selected blocked case exits 3 before runtime
input/process access. The desktop helper accepts an explicit `--runner`; it
does not turn a denied shell/IPC context into an authorized one.

Historical v1 replay remains available with `--cases-dir
infra/linux-desktop/fixtures/cases-v1` and the original exact
`--prefix/--repo/--app/--app-sha256/--fontconfig/--source-patch` inputs. V1 cannot
use a candidate override to bypass its original pins. Its source/binary/fonts
and golden provenance remain intact. Candidate preparation is read-only with
respect to source, cases, golden pixels and existing bundles.

## Record structure

Every JSON case has these required fields. Unknown fields are errors.

- `version`: integer 2 for reusable semantic cases; integer 1 for the preserved
  historical exact-profile replay. Other versions are rejected.
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
- V2 deliberately has no candidate `provenance` field. Reviewed oracle/baseline
  provenance stays in the oracle and golden metadata; live build identity is
  verified from the external candidate manifest.
- V1 `provenance` retains its original exact source/app/patch/font pins and
  explanatory notes for strict historical replay.

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
pixels are paired evidence, not automatically promoted to goldens. An observer semantic case requires the read-only observer in the candidate
build and an explicit oracle review note. The prepared bundle binds that
current build independently of the expected state.

Each executed case starts a fresh authenticated high-numbered display, Weston
and app. It excludes inherited `DISPLAY`, refuses occupied X socket/lock
numbers, and verifies the actual Weston output ID belongs to that private
X root before input. V2 waits read-only for its own PID-matching Xvfb lock,
owned socket and framebuffer, rechecks their identities after a bounded pause,
then attempts one authenticated connection. A connection failure or readiness
drift is terminal; it does not retry or use another display. The original v1
replay path remains preserved. Runtime sockets/cookie live in a new owned mode-0700
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

`basic-text-shift` and `ctrl-a-replacement` are the two ready semantic targets.
The six-key target keeps its existing full-pixel golden. The select-all target
keeps the same predeclared `abc`/UTF-16 `3→3` expectation: the preserved
observer-only source genuinely failed it, while the separate isolated
select-all source reached that exact state. A missing shortcut or missing
observer in a different candidate is a test failure, not a reason to rewrite
the target. The original v1 Ctrl+A expected-failure profile stays preserved.

Cursor/deletion, Undo/Redo, branch edits, focus reentry and standalone
modifiers remain pending their own native qualification. Held repeat remains
pending native-repeat integration and reviewed rate/delay. IME remains
unsupported until a real GPUI adapter exposes preedit, candidates, commit and
cancel; this case format cannot fake those stages.

Validation is not desktop acceptance. Keep failed artifacts and reviewed
baseline evidence intact. A new candidate is checked against the same semantic
expectations and existing reviewed oracle, rather than repinning case hashes
or automatically blessing a new capture.

## Native semantic checkpoint delivery

Version 2 waits for the actual application Default Queue frame callback before
its first focus click. Real pointer entry/motion and primary-button press/release
are independently observed before the next action. Presented-state checkpoints
require the matching completed compositor callback after their accepted observer
record. A semantic no-op must leave the entire previous revision/presentation
record unchanged after its native input delivery and settling interval. This
does not invent a redraw for a no-op or equate an accepted log with visibility.

The default catalog has seven runnable cases. Held repeat is deliberately
pending until an adaptive policy oracle is packaged; GPUI IME is unsupported.
Their skipped entries remain visible in every all-cases result.
