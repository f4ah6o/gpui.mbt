# Official-source Mozc prefix client

This opt-in recovery recipe builds only the IBus client from Debian's exact
Mozc `2.29.5160.102+dfsg-1.4` source package and reuses the matching stock server.
It never launches an IME, changes system files, installs privileged packages,
patches binaries, or weakens executable identity validation.

## Replay after a reset

First bootstrap the normal locked desktop profile with its development SDK.
Keep that profile's `installed.json` beside its `prefix` directory. Then use a
new empty build directory:

```sh
python3 infra/linux-desktop/mozc-prefix/rebuild.py \
  --sdk-root /absolute/desktop-profile/prefix \
  --runtime-prefix /absolute/desktop-profile/prefix \
  --build-root /absolute/mozc-prefix-build \
  --cache /absolute/desktop-profile/archives
```

Additional `--cache` directories are allowed. Use `--offline` to prohibit
network downloads; every cached archive is still checksum-verified. The helper
validates the complete base SDK package manifest, the exact server ELF, all
source/build archive sizes and SHA-256 values, the reviewed generator patch,
and protected IPC/server-path source files. It requires host Debian 13 amd64,
GCC 14, Python 3.13, libc development files, `pkg-config`, `curl`, `dpkg-deb`,
`patch`, `tar` and `cp`. These host prerequisites are an explicit non-hermetic
contract; bit-identical output across different absolute prefixes is not claimed.

The source lock includes official HTTPS origin URLs and hashes recorded from
the Debian source descriptor and Debian package index. No independent archive
signature verification is claimed. Source archives total 20,555,433 bytes;
24 additional build-package archives total 10,034,836 bytes. The existing base
SDK is reused, not downloaded again by this helper.

Outputs:

- `artifacts/ibus-engine-mozc`: native x86-64 client
- `artifacts/mozc.xml`: component registration with the artifact's absolute path
- `build-result.json`: source, target/server identity, hashes, timing and doctor
- `runtime-ldd.txt`: all runtime linkage checked with the target prefix libraries
- `build.log`: exact GYP and 144-step IBus-only Ninja build

The supported official GYP flag `--server_dir` sets the intended server path to
`<runtime-prefix>/usr/lib/mozc/mozc_server`. All Debian quilt patches are kept.
The one-line additional patch restricts Linux frontend enumeration from
`unix/*/*.gyp` to `unix/ibus/*.gyp`; it avoids unrelated Fcitx/UIM SDKs without
changing any executable-identity or IPC validation code. Only `ibus_mozc` is
built, with four parallel jobs and a 900-second compilation timeout. Debian's
renderer graph still needs GTK2/pkg-config development metadata during GYP
generation, but no renderer executable or server/dictionary is generated.

## Private GTK Japanese-input baseline

The caller must use an execution context that actually permits its native
D-Bus/X11/Mozc sockets. An ELF/linkage pass does not establish Japanese conversion.
The parent test owns process launch and real-key acceptance in that context.

Before starting the engine or allowing its `--xml` discovery, create this file
under a new private `$XDG_CONFIG_HOME/mozc/ibus_config.textproto`:

```text
active_on_launch: true
engines {
  name: "mozc-jp"
  longname: "Mozc"
  layout: "default"
  rank: 80
  symbol: "あ"
  composition_mode: HIRAGANA
}
```

`active_on_launch` sets the initial property-handler state; `composition_mode:
HIRAGANA` makes every enable send `TURN_ON_IME` with Hiragana mode. The engine
name is `mozc-jp` and component bus name is `com.google.IBus.Mozc`.

Use identical `HOME` and `XDG_CONFIG_HOME` for the rebuilt client and the stock
server. Linux profile resolution is: existing `$HOME/.mozc` first, otherwise
`$XDG_CONFIG_HOME/mozc`, otherwise `$HOME/.config/mozc`. A fresh private HOME
without `.mozc` avoids old-profile precedence. Client/server IPC metadata
`.<name>.ipc` is stored under that same profile. Compile-time server relocation
does not change this profile convention.

Set `MOZC_IBUS_CANDIDATE_WINDOW=ibus`: the official `UseMozcCandidateWindow()`
returns false for that exact value. The existing stock Mozc renderer is therefore
unneeded. An IBus panel/candidate UI is still required to visually observe a list.
Set `GTK_IM_MODULE=ibus`, inherit the baseline's verified absolute
`GTK_IM_MODULE_FILE` cache, `GSETTINGS_SCHEMA_DIR`, target runtime library path,
and the private D-Bus environment. Copy the generated `mozc.xml` only into the
baseline's authorized private `IBUS_COMPONENT_PATH`, before daemon startup.
Its component `exec` is the built artifact plus `--ibus`; its engines discovery
`exec` is the same artifact plus `--xml`. The generated static component version
is the upstream generator's `0.0.0.0`; the compiled client/product version remains
`2.29.5160.102`, which is what the session protocol uses.

A GTK baseline must send actual Roman keys (`nihongo`), observe uncommitted
`にほんご` preedit, press Space for candidates/`日本語`, then Return to commit.
Direct `CommitText`, preconverted Japanese injection, and pasted text do not
qualify as IME acceptance. Keep cancel/Escape and repeated enable flows separate
from GPUI host IME integration, which requires its own application test.

## Verification evidence (2026-10-06)

The complete SDK lock now matches the recovered 106-package desktop profile.
The only addition to the original 105-package SDK is the separately pinned
`fonts-dejavu-extra` archive; every existing package record is unchanged. The
original 105-package recipe lock is retained with the initial build evidence.
This remains an exact full-manifest check, not a subset or unknown-package allowlist.
Fresh empty-directory offline replay against the recovered 106-package SDK and
runtime completed in 36.45 seconds (33.66 seconds configure/build). Protected
source checks and runtime linkage passed. This new prefix artifact has not been
natively conversion-tested; the native evidence below refers to the original
pinned artifact.

The initial isolated acquisition/configuration/build completed in 333 seconds;
its workspace was 688,837,270 bytes. Fresh empty-directory offline replay of
this helper completed in 38.38 seconds, with 35.35 seconds spent configuring and
building. Linkage resolved entirely on both builds. The three upstream protected
files `ipc_path_manager.cc`, `unix_ipc.cc` and `system_util.cc` were byte-identical
to the locked official source tar. No IME was launched by the builder, and native
Japanese conversion remained for the parent to validate.

Separate native GTK evidence subsequently verified real XTest `nihonn`, visible
`にほん` preedit, selected-visible `日本`, Return/CommitText, and exact final
Mousepad clipboard `日本`. Stock Mozc hides its first-conversion list: the
fixed physical sequence uses Space, Space, Up to show the list and restore the
intended candidate before Return. A task-local client transport diagnostic
cross-matches 28 sent key calls and 16 received context signals to the retained
Mousepad child. This is GTK conversion/transport provenance only. The original
strict result still reports error because IBus's private bus does not implement
`GetConnectionUnixProcessID`; no GPUI-host IME result or API-PID gate pass is claimed.

Official source anchors:

- [Linux user-profile resolution and compiled server directory](https://github.com/google/mozc/blob/2.29.5160.102/src/base/system_util.cc)
- [Server executable identity validation](https://github.com/google/mozc/blob/2.29.5160.102/src/ipc/ipc_path_manager.cc)
- [IBus configuration schema](https://github.com/google/mozc/blob/2.29.5160.102/src/unix/ibus/ibus_config.proto)
- [IBus enable/Hiragana and candidate-window handling](https://github.com/google/mozc/blob/2.29.5160.102/src/unix/ibus/mozc_engine.cc)
- [IBus component generation](https://github.com/google/mozc/blob/2.29.5160.102/src/unix/ibus/gen_mozc_xml.py)

Recipe guard tests (no IME launch or network):

```sh
python3 infra/linux-desktop/mozc-prefix/test_rebuild.py -v
python3 -m py_compile infra/linux-desktop/mozc-prefix/rebuild.py
```
