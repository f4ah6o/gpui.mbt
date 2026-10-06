# Reproducible Linux desktop development profile

This directory records the Debian 13 amd64 cloud-desktop setup for the accepted
Linux text-field/undo source (`bf8a332595aad7fb69928719cc4b25464269a4d5`). It is
infrastructure only: it does not implement GPUI IME integration or key repeat.

The profile uses official Debian archives extracted into a private user prefix,
plus MoonBit **0.10.14+7d59c7ec9** and its matching core. Exact versions, source
URLs and SHA-256 values are committed in `profile.lock.json`. All archives must
match before extraction. No `curl | sh`, floating `latest`, personal paths,
credentials, repository changes, system-service changes, or sandbox changes
are required. A 106-package prefix is about 132 MB compressed, excluding MoonBit.

This is a bounded profile, **not a hermetic OS image**. It expects a matching
Debian 13 amd64 host with a C compiler, libc development files, pkg-config,
curl, dpkg-deb, Python 3.13, D-Bus session launcher, X11 desktop, and Mesa
EGL/GLES runtime. It deliberately leaves libc, the system loader, the compiler,
the package database, and desktop authentication to the host. `doctor` checks
actual linkage rather than claiming that `.deb` extraction ran package
maintainer scripts or satisfied the entire distribution dependency graph.

The tested Debian-prefix recipe was chosen because official recovery archives,
a working package cache and the available cloud environment already supported
it. No comparison established Nix as faster for this setup. Nix could encode a
source build with the required compiled server path; this recipe does not claim
that Nix cannot address that path contract.

## Recover after a reset

Run from a new checkout, keeping installation/state outside the repository:

```sh
export GPUI_DESKTOP_ROOT="$HOME/.local/share/gpui-linux-desktop"
python3 infra/linux-desktop/gpui-desktop.py bootstrap
python3 infra/linux-desktop/gpui-desktop.py doctor --build-only
python3 infra/linux-desktop/gpui-desktop.py build
```

`--root /chosen/private/directory` can replace the environment variable and
must precede the command. Installation is idempotent for the exact lock;
`bootstrap --force` re-extracts it to repair deleted/corrupt installation files.
Generated configuration, fonts cache, logs, MoonBit output and the installed
manifest remain under that root. Only locally generated xdg-shell bindings
are written to the checkout; these files are already gitignored.

Preserve the verified archive cache across resets when possible:

```sh
python3 infra/linux-desktop/gpui-desktop.py bootstrap --cache /persistent/cache
python3 infra/linux-desktop/gpui-desktop.py bootstrap --cache /persistent/cache --offline
python3 infra/linux-desktop/gpui-desktop.py bootstrap --cache /persistent/cache --verify-only
```

The cache filenames are in the lock. A missing or corrupt offline archive is
an error. If an official URL has been retired, obtain the **same hash** from an
official Debian snapshot into that cache; do not silently choose a newer
package or edit a checksum to make a download pass. Changing the lock is a
separate reviewed infrastructure update. Metadata hashes capture provenance
and byte identity; this extractor does not claim apt's signature verification.

For other native development commands:

```sh
eval "$(python3 infra/linux-desktop/gpui-desktop.py env)"
sh scripts/test_linux_text.sh
```

The generated fonts configuration points at prefix-installed DejaVu/Noto
fixtures instead of assuming fonts are installed under system `/usr/share`.
`fonts-dejavu-extra` is required: the unchanged historical golden used DejaVu
Math TeX Gyre for the neutral `sans` request. The initial 105-package profile
omitted that file and selected DejaVu Sans, changing 1,231 glyph/caret pixels.
The new lock adds the official 2.37-8 archive, whose math-font bytes match the
historical host file. No golden or semantic target was repinned. Font inventory
and the current runtime identities are captured with every candidate.
Host runtime targets for otherwise-dangling development `.so` symlinks are
linked only when that file exists; the host ABI remains an explicit dependency.

## Execution-context boundary

`doctor --ipc` probes Unix socket creation/binding in **the executor where it
runs**. An `EPERM` result blocks compositor/D-Bus launch there; it does not mean
the real desktop cannot run them. Do not change sandbox settings or use an
indirect terminal workaround to evade a denial. A separately supported native
desktop application launcher can be used when authorized for that desktop.
Run the same script in that permitted execution context, inheriting its real
`DISPLAY`. No X display or user identity is guessed. Explicit `XAUTHORITY` is
preserved; when it is unset, a verified existing caller `~/.Xauthority` path is
preserved before assigning the isolated task HOME. Its contents are not copied
or logged. An inherited `WAYLAND_SOCKET` fd is removed so GPUI uses the private
`WAYLAND_DISPLAY` rather than an unrelated existing compositor connection.

The observed cloud setup allowed the official Weston binary to start from the
native application launcher while its restricted command executor denied
AF_UNIX sockets. The checked source changes here have not themselves been
accepted as an IME smoke pass. The native input reference described below has
separate proven compositor/pixel evidence; parameterized recovery adapters
still need their own replay before being described as runtime-verified.

In the permitted desktop execution context, use `doctor --ipc` before launch.
Build-only diagnostics deliberately make no claim about display or IPC access.

## Nested Weston and native-key baseline

From the permitted X11 desktop context, after `build`:

```sh
python3 /path/to/checkout/infra/linux-desktop/gpui-desktop.py launch
```

The launcher uses a private D-Bus session/runtime directory, official Weston
14.0.2's X11 backend, `pixman` compositor rendering and kiosk shell. Absolute
module paths are supplied through `WESTON_MODULE_MAP`; application EGL/GLES
uses the host's software Mesa driver. GPUI receives `XDG_SESSION_TYPE=wayland`
and its private socket. It must not inherit the outer X11 session-type value.
The script terminates only its own processes when the field window exits.

The accepted PR32 baseline lacks Ctrl+A/select-all and the native unmapped
modifier fix. It can fail when Shift is delivered. The final integrated source
provides those fixes; build that current candidate for the ready semantic
cases. This infrastructure's copied PR32 app source is not itself that final
integration. The historical golden retains its independently reviewed origin.

Optional manual smoke against the final integrated source, using real keys:

1. Click the native field. Check the initial `Hello 日本` text renders.
2. Select all with Ctrl+A; type `abc` as keyboard events. Confirm one insertion
   per press and correct caret movement with Left/Right, Home/End and Backspace.
3. Undo with Ctrl+Z and redo with the field's documented shortcut. Click outside
   the field, type, then refocus; unfocused typing must not change the document.
4. Close the window. Confirm the launcher exits and its private Weston stops.

Do not substitute clipboard paste, scripted document replacement, or a
render-only frame smoke for the keyboard test. The archived PR32 application
baseline in this infrastructure checkout lacks the separate held-key-repeat
change. The final integrated source includes repeat and has its independent
release/focus-loss proof, while the reusable held-repeat catalog case remains
pending its adaptive policy oracle.

## Programmatic OS-input profile

The lock also includes the exact official Xvfb/xserver-common, Xfont, Xauth,
XTest and XKB package versions for an isolated automated input route:
XTest → authenticated private Xvfb → Weston X11 → `wl_keyboard` → GPUI.
It requires no physical-device permissions or `/dev/uinput` access. The
controlled input runner is a separate acceptance artifact; this infrastructure
does not report it as passed merely because Xvfb libraries resolve.

```sh
python3 infra/linux-desktop/gpui-desktop.py doctor --build-only --input-e2e
```

ImageMagick's `convert`, Tesseract and Pillow are declared host oracle
prerequisites for screenshots/Latin-text OCR, not silently installed or pinned
as part of this bounded profile. Preserve raw Wayland logs and window pixels;
OCR alone does not establish native input or Japanese composition.

The private runner must allocate a fresh high-numbered display, reject the
inherited live desktop display, authenticate with a per-run cookie, and
verify the Weston output window belongs to that private X root before sending
events. Never inject a key into the existing cloud/user desktop as a fallback.
Check `_NET_WM_NAME` or the actual Weston logged window ID against the private
root child tree; a legacy `WM_NAME` title-discovery timeout can occur even when
the compositor initialized successfully. No broad desktop restart is a
recovery step for a failed isolated test.

### Reproduce the reviewed comparison

`os-input-e2e.py` preserves the proven bare-`a`/Shift isolation and six-key
comparison: `a`, `b`, `c`, Shift+`d`, Left, Backspace. It runs a baseline and
candidate whose exact binary hashes must be supplied. Expected final text is
`Hello 日本abD`, with the caret between `b` and `D`. A candidate pass requires
liveness, 14 real `wl_keyboard` press/release events, the Latin OCR prefix and
suffix, and a complete RGBA match to the explicitly reviewed synthetic golden.
OCR's Japanese output is deliberately not accepted as a Japanese-text oracle.

The fixture is `fixtures/field-six-keys.png`; its predeclared state, source,
binary, patch, fontconfig and original runner hashes are recorded in
`fixtures/field-six-keys.provenance.json`. New goldens require explicit review
against a declared expected state. The runner never automatically promotes
a capture to a passing golden, and cross-host renderer/font drift fails closed.

Keep your reviewed source and binary identities in explicit variables. Run in
the permitted native desktop context, with a fresh artifact directory:

```sh
eval "$(python3 infra/linux-desktop/gpui-desktop.py env)"
python3 infra/linux-desktop/os-input-e2e.py \
  --prefix "$GPUI_DESKTOP_ROOT/prefix" --repo "$BASELINE_REPO" \
  --fixed-repo "$CANDIDATE_REPO" \
  --baseline "$BASELINE_EXE" --baseline-sha256 "$BASELINE_SHA256" \
  --fixed "$CANDIDATE_EXE" --fixed-sha256 "$CANDIDATE_SHA256" \
  --fixed-patch "$REVIEWED_SOURCE_PATCH" \
  --fontconfig "$GPUI_DESKTOP_ROOT/config/fonts.conf" \
  --golden "$PWD/infra/linux-desktop/fixtures/field-six-keys.png" \
  --output "$GPUI_DESKTOP_ROOT/results/new-comparison"
```

Prefix-fontconfig paths are parameterized; record the actual selected file hash.
A different debug-build path can change the ELF hash, so a new hash requires
the corresponding source/build provenance rather than silently reusing an old
approval label. Artifact output directories can be long: ephemeral sockets and
cookies use an owned short `/tmp/gpe-*` directory, with the AF_UNIX byte-length
limit checked before launch. Only owned child processes are terminated before
that directory is cleaned up.

### Declarative case catalog

The historical packaged `basic-text-shift` case was replayed through the generated owned
native entry and full locked prefix: 14 compositor key events, a healthy app,
the exact reviewed RGBA pixels and the ASCII OCR check passed in 1.344 seconds
including cleanup. `keyboard-validation.json` retains that historical source/build/driver/font
and XKB hashes plus the precise coverage boundary. This is a measured replay,
not a performance guarantee or a pass for every catalog case.

`input_cases.py` validates the versioned catalog and `case_runner.py` runs one
case or all currently runnable cases through the same private native route:

```sh
python3 infra/linux-desktop/input_cases.py --list
python3 infra/linux-desktop/case_runner.py --validate
```

The archived version 1 catalog has one reviewed basic pixel case and an
unresolved observer-only Ctrl+A expected-failure pilot. The default version 2
catalog supports the unchanged basic golden plus predeclared Ctrl+A replacement,
navigation/deletion/selection, standalone modifiers, undo/redo, branch-edit
redo invalidation and private focus reentry using the accepted read-only
observer. Semantic checkpoints independently require their matching completed
Default Queue compositor frame. Held repeat still needs an adaptive reusable
policy oracle; its independently passed frozen-source release/focus-loss proof
is separate. GPUI IME composition remains unsupported. `--all` records explicit skipped
pending/unsupported cases, rather than counting them as passes. The schema and
activation requirements are in `fixtures/cases/FORMAT.md`.

The following command is an exact historical version 1 replay:

```sh
python3 infra/linux-desktop/case_runner.py --case basic-text-shift \
  --cases-dir "$PWD/infra/linux-desktop/fixtures/cases-v1" \
  --prefix "$GPUI_DESKTOP_ROOT/prefix" --repo "$REVIEWED_SOURCE_REPO" \
  --app "$REVIEWED_EXE" --app-sha256 "$REVIEWED_EXE_SHA256" \
  --fontconfig "$REVIEWED_FONTCONFIG" --source-patch "$REVIEWED_SOURCE_PATCH" \
  --output "$GPUI_DESKTOP_ROOT/results/fresh-basic-case"
```

Version 2 semantic cases use a separately prepared current-candidate bundle;
normal rebuilds require no edits to committed case SHAs. The legacy version 1
catalog is preserved under `fixtures/cases-v1` for exact historical replay.
Candidate bytes, source/patch, toolchain and font identities remain hash-checked
at runtime. The optional read-only presented-state observer is off by default,
reports only after successful presentation, and is never an edit/input API.
A new driver/catalog's static validation does not replace its native replay.

The current qualification is recorded separately in
`keyboard-current-validation.json`: fresh offline 106-package bootstrap,
matching source/runtime build snapshots, 80 static tests, and seven actual
private-display keyboard scenarios passed. Basic input still matches every
reviewed RGBA pixel. The held-repeat and GPUI IME entries remain explicit
skips, and the initial 1,231-pixel font mismatch evidence is preserved.

### Build, prepare, run the current candidate

Use a separate external build directory, especially when preserving an earlier
frozen executable or native evidence:

```sh
python3 infra/linux-desktop/gpui-desktop.py --root "$GPUI_DESKTOP_ROOT" build \
  --repo "$CURRENT_SOURCE_REPO" --output-dir "$GPUI_DESKTOP_ROOT/build-current"
python3 infra/linux-desktop/candidate_bundle.py prepare \
  --profile-root "$GPUI_DESKTOP_ROOT" --output "$GPUI_DESKTOP_ROOT/candidates/current-iteration"
python3 infra/linux-desktop/case_runner.py --candidate "$GPUI_DESKTOP_ROOT/candidates/current-iteration" \
  --case basic-text-shift --output "$GPUI_DESKTOP_ROOT/results/current-basic"
python3 infra/linux-desktop/case_runner.py --candidate "$GPUI_DESKTOP_ROOT/candidates/current-iteration" \
  --all --output "$GPUI_DESKTOP_ROOT/results/current-all"
```

Build writes `field-build.json` only after matching pre/post source and runtime
snapshots. It captures the actual compiler/pkg-config commands, disables Git
textconv and rejects hidden index flags. Fontconfig must be self-contained;
external XML includes need a separately captured closure and fail closed here.
Prepare makes a fresh outside-repository bundle with copied executable and
provenance bytes. It retains the original live Fontconfig base so relative
font paths are not changed by copying. Native launch still uses the supported
desktop execution context; bundle preparation does not relax IPC permissions.
Explicit `--bind-app` mode records an externally supplied artifact and does not
claim it was compiled from the sampled source. See `BUILD-MANIFEST.md`.

Source edits or runtime/font drift require a new build/preparation, while
semantic expected states and reviewed golden hashes remain unchanged. No
candidate output is automatically promoted to a golden or review approval.

### Optional native desktop entry

The shell may lack the real desktop's IPC capability. Install an opt-in native
launcher with explicit runner arguments, then open its verified entry through
the desktop's supported application launcher. If the application inventory
does not list the user entry, File Manager can open the generated `.desktop`
file. This route was independently verified for the original approved runner;
it does not modify autostart, desktop security settings or terminal access.

```sh
python3 infra/linux-desktop/desktop-entry.py \
  --root "$GPUI_DESKTOP_ROOT" install -- \
  --prefix "$GPUI_DESKTOP_ROOT/prefix" --repo "$BASELINE_REPO" \
  --fixed-repo "$CANDIDATE_REPO" \
  --baseline "$BASELINE_EXE" --baseline-sha256 "$BASELINE_SHA256" \
  --fixed "$CANDIDATE_EXE" --fixed-sha256 "$CANDIDATE_SHA256" \
  --fixed-patch "$REVIEWED_SOURCE_PATCH" \
  --fontconfig "$GPUI_DESKTOP_ROOT/config/fonts.conf" \
  --golden "$PWD/infra/linux-desktop/fixtures/field-six-keys.png" \
  --output "$GPUI_DESKTOP_ROOT/results/new-comparison"
```

Use absolute paths in native-entry arguments because File Manager's working
directory can differ. `--runner /absolute/path/to/case_runner.py` selects a
different reviewed driver; the helper is neutral about the driver's arguments.
`--applications-dir` can select the explicit application-entry directory.
Both options precede `install` or `remove`. The helper refuses unrelated
existing entries, supports repeated identical installation, and prints the
verified file/log paths. It changes only its owned launcher files:

```sh
python3 infra/linux-desktop/desktop-entry.py --root "$GPUI_DESKTOP_ROOT" remove
```

Native execution can expose a real dpkg database while the restricted shell
does not. The runner records that inventory read-only. Database visibility
alone does not grant root privileges: `/usr/lib` was root-owned/nonwritable,
the canonical Mozc directory was absent, and no sudo route was available.

## IBus/Mozc Japanese baseline

The prefix script relocates IBus component executable references, compiles
GSettings schemas, and generates the GTK3 IM-module cache. Its IME baseline
is a GTK Mousepad app on the outer X11 desktop, separate from the GPUI window.

**Stock Debian Mozc is not fully relocatable.** Its IBus client validates the
server executable against the compiled `/usr/lib/mozc/mozc_server` path.
Starting a prefixed server is insufficient. The prefix-only baseline stops
with a clear error, even if a server process could be started.

When an authorized execution context has a real Debian 13 root/apt database,
the optional helper installs the exact official Mozc server/data versions at
their expected system paths. It does not escalate itself or edit apt sources:

```sh
# In the authorized Debian 13 root context only:
sh infra/linux-desktop/install-system-mozc.sh
# Back in the permitted native desktop context:
python3 /path/to/checkout/infra/linux-desktop/gpui-desktop.py ime-baseline
```

The normal Debian repository must still offer these exact versions. Otherwise
stop and use an official archived package under a separately reviewed recovery
step. Do not patch executable security checks or fake `/proc` identities.
An official-source rebuild with a pinned `MOZC_SERVER_DIR` is another possible
opt-in stage, delivered separately from the keyboard environment. Its isolated
client compilation/offline replay is distinct from native Japanese conversion
qualification and is not silently run by this profile's bootstrap.

Manual baseline:

1. Confirm the private IBus engine is `mozc-jp`.
2. Activate Japanese/Hiragana mode in the IBus panel; type `nihongo` as keys.
3. Observe an uncommitted `にほんご` preedit and its marked composition state.
4. Press Space; observe a candidate list and `日本語` conversion. Press Enter
   and confirm the committed text. Repeat with Escape to cancel a preedit.
5. Capture engine/version, window identity, key sequence and screenshots of
   preedit, candidates and committed text. Distinguish each stage from typing
   already-converted Japanese or pasting text.

GTK conversion only qualifies this environment baseline. GPUI host IME support
is currently unimplemented. Weston 14 exposes text-input-v1 rather than
text-input-v3, so a future v3 implementation needs a suitable compositor and
its own native GPUI composition/commit acceptance test.

## Validation and maintenance

```sh
python3 -m unittest discover -s infra/linux-desktop/tests -v
python3 -m py_compile infra/linux-desktop/gpui-desktop.py
sh -n infra/linux-desktop/install-system-mozc.sh
git diff --check
```

Record `doctor` output and `installed.json` with local smoke evidence. A passing
checksum/build/doctor is not proof of visible typing, preedit or conversion.
Refresh the lock only after checking the official index/package hashes and
repeating bootstrap, native build, linkage and interactive acceptance.

References: [Weston 14 options](https://manpages.debian.org/trixie/weston/weston.1.en.html),
[IBus daemon options](https://manpages.debian.org/trixie/ibus/ibus-daemon.1.en.html),
[MoonBit archive verification](https://www.moonbitlang.com/download#verifying-binaries),
[Mozc server-path validation](https://github.com/google/mozc/blob/2.29.5160.102/src/ipc/ipc_path_manager.cc),
[Mozc compiled server directory](https://github.com/google/mozc/blob/2.29.5160.102/src/base/system_util.cc),
[Weston 14 text-input backend](https://sources.debian.org/src/weston/14.0.2-1/frontend/text-backend.c/).
