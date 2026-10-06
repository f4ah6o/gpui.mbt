# GPUI native Wayland IME acceptance

This GPUI-only harness extends the immutable private native environment recipe. It does not replace `probe.py`, `evidence.py`, `deployment.lock.json` or `qualification.json`. The original stock editor result is an environment baseline, never GPUI qualification.

## Scope and current result

The experimental Linux field opts in with `GPUI_FIELD_WAYLAND_IME=1` and its read-only accepted-presentation observer with `GPUI_FIELD_E2E_STATE=1`. It starts at `Hello 日本`. The native route is real OSdriver XTest → authenticated owned Xvfb → Weston 14 desktop-shell → privileged synchronous stock IBus native v1 UI → original Mozc → GPUI ABI3 ordered owner ingress. No observer write, callback edit, synthetic native text event, global settings change or inherited desktop display/bus is used.

The first candidate's immediate-shortcut diagnostic `runs/gpui-4` has 17 complete presented checkpoints, 70 exact injected/received/native IBus key events, 734 strict Gio frames and 34 exact native preedit/commit deliveries into GPUI. It passed real replacement, conversion, one commit, atomic history, cancellation and fresh-session reactivation; cleanup was verified in 6.101 seconds. Independent read-only replay is retained in the owner evidence directory. This is `qualified-partial`: at that diagnostic snapshot the required 100ms held-shortcut regression tier had not yet passed. Fresh full qualification requires the exact-current held tier described below.

Actual GPUI pixels show the native candidate popup during kana/conversion and its disappearance after commit, cancellation, blur and final cancellation. GPUI sends actual show/hide requests. Expanded candidate-table contents/highlight can lag GPUI's conversion, so candidate-table selection correctness is still unqualified. A stock editor result is never substituted for GPUI panel evidence.

Four native startup critical assertions remain visible and disclosed: IBus substring offset/self assertions and Gdk get/set-events window assertions. These occur before the first native activation and match the frozen baseline's startup diagnostics. The GPUI-specific launcher preserves Gio stdout separately from Wayland/Gdk stderr. Nothing is discarded or repaired. The strict replayer records each known diagnostic line/hash and timing; unknown or post-activation diagnostics fail. It never claims a warning-free native runtime.

## Acceptance tiers

Every run must complete all these steps using real input, native protocol, accepted observer states and captured private pixels:

1. Before each checkpoint, bind its accepted observer presentation to the exact preceding own Default Queue main-surface frame callback and require its subsequent done. Independently locate actual GPUI viewport and admitted field pixels before any input; click inside its field and require native Enter plus the newest matching IBus context FocusIn/keyboard grab.
2. OS Ctrl+A selects UTF-16 `[0,8]`. Typing `nihonn` gives preview `にほん` while committed text stays `Hello 日本`, with marked `[0,3]`.
3. Space, Space, Up converts to `日本`; Return produces exactly one genuine native commit. The selection collapses to UTF-16 `[2,2]`; committed native surrounding text is `日本` with UTF-8 cursor/anchor `[6,6]`.
4. Ctrl+Z restores the entire initial text and directional selection. Ctrl+Shift+Z restores `日本` as one transaction. Preedit adds no undo records. Actual selected→undone field pixels must be byte-identical; committed→redone/cancelled/final must also be byte-identical, and replacement must visibly change real glyph pixels. Mutation tests corrupt each paired image and fail closed.
5. A separate `nihonn` conversion followed by Escape reverts to kana; a second Escape clears preview without any extra commit or committed-text change.
6. Another kana preedit is cancelled by actual private-window keyboard focus-away. Refocusing the field creates a newer epoch and actual IBus context. Fresh `ka` yields only `か`, then Escape returns to `日本`; prior composition cannot revive.
7. Strict replay matches the entire exact keycode, keysym, modifier/release state, typed replies, context ownership and native output sequence. For all three held shortcuts the old genuine IBus grab must receive Ctrl release and modifier0 before deactivation; actual GPUI leave/new activation/Entered must follow. It rejects zero-case, incomplete/reordered observer/checkpoints, extra commits, leaked provisional surrounding text, changed source/deployment/log/pixel bytes, malformed Gio diagnostics and failed owned cleanup.

The full qualification additionally requires `--held-shortcuts`, holding Ctrl+A, undo and redo chords for 100ms before genuine OS releases. The immediate tier is diagnostic. A complete `passed` status requires this held tier and actual panel show/hide pixels. Panel failures remain explicit `qualified-partial`; they never become zero-case Green. A failure has exit 1, a qualified partial has exit 2, and only the complete suite has exit 0.

## Immutable original runtime and candidate overlay

`prepare-gpui-deployment.py` generates an evidence-local candidate overlay above the SHA-256-pinned frozen baseline lock. Candidate-specific pins stay outside the source checkout to avoid a build-manifest self-reference. Before overlay preparation, launcher preparation, --check and native execution, established build_manifest.verify_build_manifest verifies the exact current commit/tree/worktree and binary, including verify_runtime over tools, generated protocols, fonts and runtime trees. The verified source/binary identities and closure inventory are retained. Preflight also verifies every frozen baseline byte. Historical read-only replay uses saved bytes and identities without requiring today’s source; an old diagnostic cannot claim the new exact-current held tier. It does not substitute the recovered engine.

The original native-tested server remains `/workspace/scratch/72d79608add1/gpui-desktop-runtime/prefix/usr/lib/mozc/mozc_server`, SHA-256 `020f50a6cd53b3a0a5e6c66a30f698b05d5c68df4b5be73e663c1435bc8c432e`; the original engine and component remain the frozen baseline pins. Each run snapshots its actual candidate build manifest and deployment, helpers, complete pre-shutdown diagnostic streams, physical events and checkpoint pixels. The bounded render-readiness audit retains every frame wait and unsuccessful pixel capture; ambiguous geometry or timeout fails before input. Mesa/EGL callbacks and unrelated/reused sync IDs cannot settle the owner frame. Replay recomputes each ready callback binding from retained native log bytes. Failures retain their original evidence.

This remains path-bound authorized own-cloud reproduction, with the frozen prefix's distribution ABI/shared-library/font prerequisites. It is not an arbitrary-machine installer, hermetic OS or production-wide IME support claim.

## Reproduction

Static/read-only checks launch no input or services. Commands with /path/to placeholders require replacement with the exact generated overlay/build-manifest path; test_gpui_probe.py is portable and requires no live candidate:

```sh
/usr/bin/python3 infra/linux-desktop/wayland-ime/test_gpui_probe.py
/usr/bin/python3 infra/linux-desktop/wayland-ime/gpui_probe.py --check \
  --deployment /path/to/generated-evidence-overlay.json
```

After building the clean source union, generate an unused overlay from its exact consistent build manifest. The output must be a new file in the frozen private evidence root, outside source:

```sh
/usr/bin/python3 infra/linux-desktop/wayland-ime/prepare-gpui-deployment.py \
  --candidate-manifest /path/to/reviewed-final-build.json \
  --output /workspace/scratch/72d79608add1/gpui-wayland-ime-runtime-evidence/gpui-final-overlay.json
```

Prepare an unused launcher only for an authorized fresh native run:

```sh
/usr/bin/python3 infra/linux-desktop/wayland-ime/prepare-gpui-launcher.py \
  --deployment /path/to/generated-evidence-overlay.json \
  --run-name gpui-held-new --held-shortcuts
```

Review its source, deployment and exact Desktop Entry Exec. Open the owned task evidence folder with the already approved own-cloud File Manager mouse route and double-click that entry. Coordinate exclusive CUA ownership. The known keyhelper XOpenDisplay failure is terminal for that helper route; do not retry it, use a terminal, alter permissions or access a restricted socket. Native input connects exactly once to the new authenticated private display; failed XOpenDisplay stops that run without fallback.

The native Python startup library/type-library paths are those in the prepared launcher. Read-only replay uses those same environment paths with `/usr/bin/python3 infra/linux-desktop/wayland-ime/gpui_evidence.py RUN_DIRECTORY`. No native processes/input are launched by replay. A default 60-second total budget bounds startup, input, observations and service lifetime; private schema compilation has a separate 3-second bound. Cleanup uses retained identities and pidfds, never process names; unverifiable cleanup retains its private runtime and fails.

## Preserved development attempts

- GPUI-1: held Ctrl+A selected correctly, then genuine IBus key calls retained Ctrl mask4 after the release crossed session recreation. Kana timed out; cleanup verified. This is the held-shortcut regression blocker, not a passed Japanese case.
- GPUI-2: replacement/conversion/commit/history/Escape/blur/refocus passed. The test clicked at a valid mid-text point after refocus, so `ka` correctly inserted at offset1 (`日か本`) rather than the test's intended end. The test now clicks far-right inside the pixel-located field; the original attempt remains unchanged.
- GPUI-3: all 17 live checkpoints passed, but Gdk stderr assertions interleaved into a Gio stdout frame; strict mixed-stream replay correctly failed. The GPUI-specific wrapper now captures the actual streams separately without filtering or repairing them.
- GPUI-4: all 17 live checkpoints and strict separate-stream replay passed, with real GPUI panel lifetime pixels. Required held tier remains pending; startup diagnostic assertions are retained.
- GPUI-held-5: exact-current source/runtime gates passed on the clean final candidate, but its first accepted presentation preceded compositor frame completion/readback visibility. Initial pixels were blank, so the geometry gate correctly stopped before any keys; cleanup verified. The bounded frame and independent pixel readiness fence now preserves these observations and applies to every checkpoint.

## Observed native include-cache caveat

After editing Ubuntu native files included by `backend.c`, including
`ime_transport.inc.c`, `ime_reader.inc.c` or `ime_transport.h`, use a new unused
`--target-dir` / output directory for candidate builds and native MoonBit
verification. In the pinned toolchain here, a reused native `backend.o` was not
invalidated by an include-only edit; an up-to-date message therefore does not
establish that changed included code was compiled. The direct ingress script
recompiles production C each run. Record the fresh directory in the exact-source
build manifest. This is an observed bounded-toolchain caveat, not a claim about
all Moon versions.
