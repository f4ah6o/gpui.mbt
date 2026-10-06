# Private native-Wayland IME runtime qualification

The original own-cloud Weston 14.0.2 / IBus 1.5.32 / Mozc stack is qualified for a native v1 client. **This is an environment baseline, not GPUI IME support.** The unmodified GPUI binary only observes the newly available manager; it does not bind or activate it.

## Verified result

`gpui-wayland-ime-runtime-evidence/runs/native-4/result.json` passed in 3.57 seconds, including owned-process cleanup. Its independent `transport-evidence.json` replay matches:

- 38 exact task-driver key press/release events to 38 actual grabbed `wl_keyboard` events and 38 genuine private IBus `ProcessKeyEvent` calls, each with a successful typed reply
- 21 exact owned IBus v1 preedit/commit outputs to the stock `weston-editor` client's receipts, preserving serials and complete strings
- The exact typed reply to `CreateInputContext("wayland")`, followed by `FocusIn` on that context before its first key
- Real `nihonn` → `にほん` → `日本` → Return commit, with the client publishing its actual surrounding text `日本` and UTF-8 cursor/anchor byte offsets 6
- A new conversion, Escape reverting to `にほん`, and a second Escape clearing preedit with no extra commit and unchanged actual client text
- SHA-256-linked pre-shutdown logs, injected events, source/deployment snapshots and six captured private-display screenshots

GPUI observes `zwp_text_input_manager_v1` version 1. Stock IBus binds `zwp_input_method_v1` and `zwp_input_panel_v1` without a permission error. The compositor itself launches IBus through its privileged inherited `WAYLAND_SOCKET`; the wrapper preserves the FD and executes the existing `ibus-ui-gtk3 --enable-wayland-im`.

Candidate prediction pixels appeared during kana preedit. The final run's popup contents/highlight can lag the editor preedit, and its popup remains visible after commit/cancel. Popup contents/lifetime and expanded conversion candidate-table selection are **not qualified**. Physical hardware input, API sender/PID lookup, reset-based composition flushing, deactivate/reactivate isolation, and GPUI IME integration are also unqualified. In particular, IBus 1.5.32's v1 reset handler is empty. No claim that reset cancels a composition is made.

## Bounded private recipe

`deployment.lock.json` names the exact original runtime, native-tested original Mozc engine/component, stock server, built GPUI binary and its build manifest, frozen PrivateX and baseline utilities, frozen Gio diagnostic parser, schema compiler/XML, selected XKB bytes, support fonts/component XML and host executables. Preflight verifies every enumerated SHA-256 before launch. The recovered 106-package Mozc engine is a different, native-untested artifact and is never silently substituted.

This is path-bound original-stack reproduction on the authorized own-cloud desktop, not a hermetic OS image or an arbitrary-machine installer. Distribution ABI, dynamically loaded host/prefix libraries, fontconfig behavior, and the approved native launch context remain prerequisites. The prior desktop profile's package archive lock and Mozc official-source build recipe provide stack recovery; different absolute build paths can change the engine bytes and require separately reviewed pins and qualification.

Each run creates a new authenticated private Xvfb, Xauthority, HOME/XDG directories, foreground stock Mozc server, private session bus and private IBus bus. No inherited desktop display, bus, credentials or Wayland socket is used. The private IBus daemon has `--panel=disable`; only Weston's `[input-method]` launches its native UI. The UI clears GTK/QT IM modules, uses `GDK_BACKEND=wayland` and the stock synchronous mode `IBUS_ENABLE_SYNC_MODE=1`.

The private schema override preloads/orders only `mozc-jp` and keeps the system keyboard layout. Without that override, the stock UI initializes the empty default list with English and can replace the previously selected Mozc engine. Schema compilation and every setting are private to this run. No system schema installation or user setting is changed.

Weston uses desktop-shell, its pinned desktop-shell client, no panel/locking and no startup animation. Kiosk-shell never initializes this text backend and remains unchanged for the separate keyboard catalog. The editor target is located from captured private pixels, then activation/keyboard-grab/native-context readiness is required before sending keys.

Cleanup uses retained identities and Linux pidfds, plus an unpredictable marker and exact private HOME/config for compositor-launched descendants. No name-based kill is used. A run retains its runtime directory if cleanup cannot be verified. The sole authenticated XOpenDisplay attempt fails terminally; no alternative display or security change is attempted.

## Preparing and reviewing a fresh run

Static checks and evidence replay execute no native input or service launch:

```sh
/usr/bin/python3 infra/linux-desktop/wayland-ime/test_probe.py
/usr/bin/python3 infra/linux-desktop/wayland-ime/probe.py --check
/usr/bin/python3 infra/linux-desktop/wayland-ime/evidence.py \
  /workspace/scratch/72d79608add1/gpui-wayland-ime-runtime-evidence/runs/native-4
```

Prepare a new launcher only when a fresh native run is authorized:

```sh
/usr/bin/python3 infra/linux-desktop/wayland-ime/prepare-launcher.py --run-name replay-1
```

Preparation validates the current deployment, refuses existing launchers/output, writes an executable task-local Desktop Entry and launches nothing. Review its exact source, deployment and Exec first. In the already approved own-cloud File Manager route, open the task folder and double-click that launcher. Inputs then stay exclusively on the new private display. Coordinate exclusive CUA ownership with any other desktop worker. This native route is not permission to bypass a denied action, run through a terminal, alter security, or target a different desktop.

Native Python must start with the prefix library path and type-library path recorded in the generated launcher. Output must be a new directory inside the deployment's dedicated evidence root. Default budget is 60 seconds, selectable only from 30–90 seconds; private schema compilation has a separate 3-second bound. No external publication, merge, system installation or GPUI ABI edit is part of this probe.

## Retained attempts and limitations

- Native-1: registry and privileged bindings passed; no editor keys. Pixel location failed because the stock startup fade was still active. Cleanup verified.
- Native-2: no editor keys. The first derived click hit the editor's blank margin rather than its top text-entry widget; activation readiness stopped the run. Cleanup verified.
- Native-3: conversion/cancel/pixels/cleanup passed. Its raw shutdown log contains an interleaved Gdk broken-pipe warning and a truncated final unrelated D-Bus frame. It is a conversion tier, not a full strict Gio replay tier. The raw files and pre-correction helper snapshots remain unchanged.
- Native-4: strict replay uses actual pre-shutdown snapshots and passes all stated gates. Orderly shutdown may append Gdk broken-pipe messages and Weston's layer-finalization warning to raw logs; those raw logs are retained. The snapshot parser does not discard malformed D-Bus frames or remove arbitrary warnings.

The Gio formatter is diagnostic text, not a stable ABI. The replayer demultiplexes only complete timestamped official Wayland-debug lines and records each removed line's number/hash; remaining complete D-Bus messages go through the pinned strict parser. Unknown, interleaved fragments, incomplete messages, mismatched contexts/replies, extra commits, altered input sequences and altered evidence bytes fail closed.

## Primary source references

- [Weston desktop-shell text backend initialization](https://github.com/wayland-mirror/weston/blob/14.0.2/desktop-shell/shell.c#L4973)
- [Weston privileged input-method client check](https://github.com/wayland-mirror/weston/blob/14.0.2/frontend/text-backend.c#L887)
- [Weston compositor-launched WAYLAND_SOCKET inheritance](https://github.com/wayland-mirror/weston/blob/14.0.2/frontend/main.c#L513)
- [Stock Weston v1 editor](https://github.com/wayland-mirror/weston/blob/14.0.2/clients/editor.c)
- [IBus v1 binding and synchronous mode](https://github.com/ibus/ibus/blob/1.5.32/client/wayland/ibuswaylandim.c#L2091)
- [Gio diagnostic options](https://docs.gtk.org/gio/overview.html)

Exact tagged Weston/IBus source was inspected through the GitHub connector when raw web retrieval failed; the source tags match the enumerated installed runtime. Evidence source notes and all raw attempts are private task artifacts.
