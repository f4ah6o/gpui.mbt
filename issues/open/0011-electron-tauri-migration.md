# Electron / Tauri migration path

Status: open
Parent: [0009-browser-backend.md](0009-browser-backend.md)
Updated: 2026-10-04

## Goal

Provide a low-risk migration path from existing Electron and Tauri applications
to gpui.mbt without requiring a full rewrite of the application shell, native
integration, packaging, updater, or all UI surfaces at once.

The migration model should support progressive replacement:

```text
existing Electron/Tauri application
  -> gpui.mbt mounted inside the existing web host
  -> gpui.mbt becomes the primary renderer/frontend
  -> host/native services move behind a portable contract
  -> optional final move to a gpui.mbt native backend
```

The browser backend is the initial bridge. Electron and Tauri are migration
hosts, not permanent application semantics.

## Principles

1. Do not require a big-bang rewrite.
2. Reuse the same gpui.mbt application/layout/element/scene/event model used by
   native and browser backends.
3. Keep Electron, Tauri, DOM, WebView, JavaScript, and Rust host details below
   explicit host/service boundaries.
4. Preserve existing packaging, signing, updater, installer, native plugins, and
   privileged backend logic until the application chooses to migrate them.
5. Allow screen-by-screen or region-by-region adoption where practical.
6. Do not make DOM/CSS layout part of gpui.mbt's portable UI semantics.
7. Migration-only compatibility features must not become required by ordinary
   gpui.mbt applications.

## Migration lanes

### A. Electron: renderer island -> full renderer -> native

Initial topology:

```text
Electron main
  -> preload / contextBridge
  -> existing renderer
       -> gpui.mbt browser mount
            -> canvas viewport
```

The first supported Electron migration should allow an application to mount one
gpui.mbt viewport inside an existing renderer while keeping:

- Electron main-process code
- preload/contextBridge APIs
- existing IPC
- installer/signing/update setup
- existing web UI outside the migrated region

A practical progression is:

1. mount one gpui.mbt canvas-backed region
2. move one complete screen or pane into gpui.mbt
3. move global focus/input/state ownership to gpui.mbt
4. replace the normal renderer UI with gpui.mbt
5. optionally replace Electron itself with a gpui.mbt native backend

The migration must not require portable gpui.mbt code to call Electron APIs
directly.

### B. Tauri: frontend replacement -> service migration -> native

Initial topology:

```text
Tauri shell / Rust commands / plugins
  -> WebView frontend
       -> gpui.mbt browser frontend
```

Tauri is especially suitable as an intermediate host because an application can
retain its Rust backend, commands, plugins, packaging, updater, and signing while
replacing only the frontend.

A practical progression is:

1. keep the existing Tauri shell and backend
2. replace or partially replace the frontend with the gpui.mbt browser build
3. route Tauri commands through the shared host-service contract
4. migrate backend services only when useful
5. optionally move to a fully native gpui.mbt application later

A Tauri application that chooses to remain on Tauri permanently should still be
able to use gpui.mbt as its frontend without being treated as incomplete.

## Host service contract

Define a portable host-service boundary so gpui.mbt application code does not
depend directly on Electron preload APIs, Tauri `invoke()`, or browser globals.

Candidate service families include:

- filesystem
- dialogs
- clipboard
- notifications
- shell/open-url
- persistent storage
- application metadata
- window controls
- menu/tray integration
- process/environment access where supported
- update integration
- application lifecycle

Possible implementations:

- `BrowserHostServices`
- `ElectronHostServices`
- `TauriHostServices`
- `NativeHostServices`
- test/headless fake services

The contract must:

- expose capability differences explicitly
- represent asynchronous completion explicitly
- use typed errors
- prevent stale completion from targeting destroyed logical objects
- avoid exposing JavaScript/Rust/WebView/Electron handles in portable packages
- remain mockable for deterministic tests

Do not mirror every Electron or Tauri API one-for-one. The service vocabulary
should represent application capabilities that can also make sense on native
gpui.mbt backends.

## Migration-only legacy web islands

Some existing applications contain expensive web-only components such as:

- Monaco or CodeMirror editors
- complex HTML data grids
- maps
- browser-specific rich text editors
- embedded third-party widgets
- existing React/Vue/Svelte feature surfaces

Investigate an optional migration-only mechanism that allows a gpui.mbt layout
region to reserve a rectangle for a legacy DOM/WebView surface.

This must be strictly isolated from portable layout/rendering semantics.

Requirements:

- gpui.mbt remains the source of truth for the reserved region's logical bounds
- the legacy surface is positioned by the host adapter
- focus/input ownership transitions are explicit
- clipping and visibility are synchronized
- teardown cannot leave orphaned DOM nodes/listeners
- portable gpui.mbt packages do not gain DOM element types
- native-only applications do not need the compatibility package
- applications can measure remaining legacy-island count as migration debt

The preferred endpoint is zero legacy islands. Long-lived islands are allowed
only where the application intentionally keeps a web-native component.

## Contract-first migration

Do not attempt to mechanically translate React/Vue/Svelte components into
MoonBit as the primary migration strategy.

Instead, preserve externally observable behavior first.

Useful source artifacts include:

- TypeScript types
- JSON schema
- Electron IPC contracts
- Tauri command signatures
- state machines
- keyboard shortcuts
- persisted-state formats
- accessibility roles/names/states
- screenshots and visual fixtures
- Playwright tests
- application E2E workflows

The migration tooling and documentation should encourage:

```text
existing behavior/contracts
  -> deterministic migration fixtures
  -> gpui.mbt implementation
  -> differential/black-box verification
```

This allows applications to rewrite implementation structure while retaining
behavioral compatibility.

## State ownership

Mixed-mode applications need an explicit answer to which runtime owns state.

Recommended progression:

1. existing application remains authoritative
2. migrated gpui.mbt regions consume copied/serialized state through a narrow
   boundary
3. state ownership moves into gpui.mbt one domain at a time
4. compatibility bridges are removed after no old consumers remain

Avoid shared mutable JavaScript/MoonBit object graphs across the host boundary.

For migration boundaries, prefer JSON-compatible or otherwise explicitly
versioned values until a more efficient stable transport is justified.

## Focus and input

Mixed gpui.mbt + legacy web UI creates focus hazards.

Define conformance rules for:

- pointer routing at island boundaries
- keyboard ownership
- tab traversal
- IME ownership
- clipboard commands
- drag/drop if later supported
- modal dialogs
- browser/Electron/Tauri menu shortcuts

Only one surface should own a given input sequence at a time.

The migration host must not dispatch the same event independently into both the
legacy UI and gpui.mbt.

## Build and development workflow

Provide documented reference integrations for:

- Electron + existing renderer + gpui.mbt island
- Electron + full gpui.mbt renderer
- Tauri + existing frontend + gpui.mbt island where feasible
- Tauri + full gpui.mbt frontend

The browser build should reuse the Vite+ / MoonBit integration established by
the browser backend packet rather than introducing a second custom bundler path.

Reference examples should keep host glue small enough that downstream projects
can copy or generate it.

## Migration tooling opportunities

After the manual reference integrations are stable, consider tooling that can:

- detect Electron or Tauri project structure
- generate the gpui.mbt browser entrypoint
- generate host-service adapter skeletons
- inventory Electron IPC or Tauri commands
- inventory legacy DOM islands
- produce a migration report
- scaffold differential E2E tests

This tooling is optional and should follow stable contracts rather than define
them.

## Testing

Required test layers:

1. shared gpui.mbt core/browser/native tests remain unchanged
2. host-service contract tests with fake implementations
3. Electron integration smoke
4. Tauri integration smoke
5. mixed legacy/gpui focus and input tests
6. repeated mount/unmount/remount tests
7. async completion after teardown tests
8. state serialization/version boundary tests
9. full-renderer migration example tests
10. differential black-box E2E against selected legacy fixtures

VLMKit or browser automation may be used as external visual/interaction evidence,
but deterministic framework and contract tests remain authoritative for portable
semantics.

## Acceptance criteria

The initial migration packet is successful when all of the following are true:

- an existing Electron application can mount a gpui.mbt screen/region without
  replacing its main process or preload architecture
- an Electron application can run a full gpui.mbt renderer while retaining
  existing privileged host APIs behind the host-service contract
- a Tauri application can use gpui.mbt as its frontend while retaining its Rust
  commands/plugins/packaging
- portable gpui.mbt application code contains no Electron/Tauri/WebView handles
- host services are capability-aware, async-safe, typed, and testable
- at least one mixed legacy-web/gpui migration example demonstrates explicit
  focus/input ownership
- migrating from hosted browser mode to native gpui.mbt does not require
  rewriting ordinary UI/application code
- documentation describes which assets can be retained at each migration stage

## Non-goals

Do not require the first implementation to provide:

- automatic source-to-source conversion from React/Vue/Svelte to MoonBit
- one-to-one compatibility with every Electron or Tauri plugin
- arbitrary DOM embedding on native gpui.mbt backends
- pixel-identical rendering with the old application
- complete backend-service migration
- removal of Electron or Tauri as a mandatory completion criterion

## Definition of done

The packet is complete when a real reference Electron application and a real
reference Tauri application can each demonstrate an incremental migration from
an existing web frontend to gpui.mbt, preserving their existing host/native
infrastructure during the transition, with a documented optional path to native
gpui.mbt afterward.

The migration story must make adoption materially easier than a full rewrite:
applications should be able to move one coherent UI surface at a time while
retaining working production infrastructure around it.

## Implementation progress — 2026-10-04

The repository now has a bounded, versioned host-service bridge with logical
scope/request IDs, typed capability states, copied values, queue and payload
limits, cancellation of late completions, and default-deny grants. Renderer
adapters use a fixed Electron IPC channel or explicit Tauri command mapping;
the examples grant no privileged service by default. A browser legacy-island
fixture exercises logical bounds and focus handoff. See
[docs/electron-tauri-migration.md](../../docs/electron-tauri-migration.md).

Node contract tests use fake IPC/invoke functions; there is no real Electron
main-process service handler or Tauri Rust command implementation, and neither
desktop runtime has an integration smoke. Complete envelope-size validation,
adapter validation, and late-scope completion handling are implemented, while
real host integrations, mixed-runtime input/focus E2E, serialization/version
fixtures against a production host, and full-renderer migration examples remain
acceptance work. The implemented v1 JSON adapter is not a framed wire protocol
and has no transport negotiation. This progress does not close the migration
packet.
