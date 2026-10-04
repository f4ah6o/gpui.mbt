# Electron and Tauri migration boundary

The migration slice keeps a current web application usable while its ordinary
screens move into gpui.mbt. It defines a portable host-service contract and
small renderer-side adapters. It does not replace an application's Electron
main process, preload architecture, Tauri Rust commands, packaging, signing, or
updater.

## What an application can retain

| Migration stage | Renderer | Host assets that can remain |
| --- | --- | --- |
| Existing app | Current React, Vue, Svelte, or other web UI | Electron main/preload, or Tauri commands/plugins, packaging, signing, and updater |
| Mixed screen | gpui.mbt canvas for selected regions plus existing web surfaces | Existing privileged service implementations and the old UI around expensive editors, grids, maps, and widgets |
| Full gpui.mbt frontend | gpui.mbt browser renderer | Electron main/preload or Tauri Rust backend, IPC/command implementations, packaging, updater, and signing |
| Optional native app | gpui.mbt native frontend | Reimplement only services that need to move out of the hosted shell; ordinary app/model/capability code stays portable |

The legacy-island example reserves a logical rectangle in the browser app's
layout DTO and positions a DOM note editor in that rectangle. The host owns the
DOM surface and focus listeners; the app owns the logical bounds. Focus inside
the island selects the legacy input owner, movement between island controls
keeps that owner, and hiding or disposing a focused island returns focus to the
framework canvas. The mixed fixture and remount path are covered by real
Chromium automation.

## Portable service contract

`migration/host_services` owns operation names, declared capability states,
logical scope/request IDs, copied `capability.Value` payloads, and async
completion handling. Requests use a version-1 JSON envelope with UInt64 IDs
encoded as decimal strings. IDs increase monotonically; replies must match both
request and scope; destroyed scopes drop queued work and late replies. The
portable bridge bounds live scopes, pending requests, payload depth, node count,
and canonical JSON size. An empty grant list denies every operation.

The bridge does not execute services or contain Electron, Tauri, DOM, process,
or native handles. Each host adapter must independently allowlist operations,
validate replies, and map host failures to typed results. The JS adapter in
`examples/migration/host-services.js` exposes only a fixed Electron IPC channel
or fixed Tauri command names. Its renderer surface does not expose
`ipcRenderer.send`, Node process APIs, arbitrary command selection, or general
host invocation.

The examples intentionally grant no privileged operations:

- `examples/migration/electron-preload.example.mjs` installs the service object
  with an empty operation allowlist. An application should add only operations
  whose main-process handlers perform their own validation and permission
  checks.
- `examples/migration/tauri-bridge.example.js` maps no commands. An application
  must bind each portable operation to one fixed Rust command.

The Node contract suite exercises these adapters with fake IPC and invoke
functions. It checks default-deny, explicit grants, fixed channel/command
binding, UInt64 precision, stale/duplicate IDs, bounded queues, payload
validation, and late completion cancellation. The repository does not include
an Electron main-process service handler or a Tauri Rust command implementation,
and CI does not launch either desktop runtime. Electron and Tauri integration
smokes remain acceptance work for a concrete host application.

## Browser proof boundary

The browser proof adds `examples/migration/legacy-island.js` and a fixture-only
ARIA proxy. The ARIA proxy mirrors four app-provided button descriptions and
returns focus and activation through the existing framework event ingress. It
is not a general adapter over a shared semantic accessibility tree. The
counter proof routes a GUI click, direct API call, and in-process MCP adapter
call through one registered command and one app-owned entity; an ordinary
`Context.observe` update changes the rendered counter quad. It is a semantic
adapter test seam, not MCP wire transport.

See [the browser proof guide](browser-demo.md) for commands and the current
browser renderer limits. The Canvas 2D output is execution evidence; WebGPU,
text/IME, full accessibility, and production browser support remain open.
