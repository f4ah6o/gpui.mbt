# Windows native backend roadmap

Status: open
Parent: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md)
Updated: 2026-10-07

## Current-head acceptance triage — 2026-10-04

Basis: merged main HEAD `1dea499e34a36a64927791c94f35965a91c305a2`; PR #13
head `d70b1255aa5dc1eaaea04a67a9ea748d29317cbd`.

- [x] The experimental one-HWND Win32/D3D11 hardware-or-WARP path has current
  hosted evidence. The [Windows run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649277)
  passed the MSVC shim build, portable tests (6/6), native GPU/lifecycle E2E
  (1/1), shared backend conformance, and example smoke.
- [x] Regressions cover minimize/restore sizing, independent mouse-button
  tracking, actual capture ownership, focus/capture loss, and teardown.
- [ ] Multiple windows, physical multi-monitor DPI, Japanese IME/text shaping,
  accessibility, menus, device-loss recovery, clipboard interoperability
  beyond the bounded independent Win32 fixture, sustained resource lifetime,
  and performance remain open.

The successful one-window run does not promote a Windows support tier.

## Bounded clipboard process-interoperability slice — 2026-10-07

### Purpose

Close the evidence gap between an in-process clipboard round trip and a
separate Win32 process exchanging exact `CF_UNICODETEXT` with the experimental
one-HWND backend. This slice qualifies the existing production clipboard
adapter and its current UTF-8/UTF-16/error contracts. General third-party
application compatibility remains open.

### Scope

- Compile `tests/windows/clipboard_fixture.c` as a standalone Win32 executable.
  It owns a hidden HWND and uses `OpenClipboard`, `GetClipboardData`,
  `EmptyClipboard`, and `SetClipboardData` directly.
- From the opt-in native E2E, verify that the fixture reads gpui's exact
  Japanese, emoji, combining-mark, LF, and CRLF payload, then have it publish
  its own exact Unicode payload for `Host::read_clipboard` to consume.
- Have the fixture publish a sentinel and hold the clipboard open while
  `Host::read_clipboard` and `Host::write_clipboard` return `Busy`. After
  release, read the intact sentinel and complete a successful write/read.
- Exercise the fixture's bounded lock expiry and verify that the clipboard
  becomes readable afterward. The parent launches only the configured
  absolute executable path, verifies its image path plus PID/nonce handshake,
  and reaps only the created process through its process/job handles.

### Acceptance

- [x] Independent-process exact Unicode read and write pass in the local
  Windows native E2E.
- [x] A real independent `OpenClipboard` lock returns `Busy` for production
  reads and writes, preserves its sentinel, and permits later operations.
- [x] Bounded fixture expiry releases the clipboard and the child process is
  reaped; the sent-message wait pump preserves an ordinary queued wake event.
- [x] Run the Windows native runner with the fixture in its evidence directory
  and the fixture path set for the opt-in native E2E gate; the pinned local
  actrun run recorded below passed against implementation source
  `dfa0695bc1903a55824635a5506f68b377548279`.

### Dependencies

The native gate needs the pinned MoonBit toolchain, x64 MSVC/Windows SDK, and a
Windows desktop session for the existing D3D11 HWND test. The fixture is built
by the runner from the repository source and requires no installed clipboard
utility or external application.

### Validation and progress

On 2026-10-07, the fixture and backend passed MSVC C compilation, MoonBit
formatting, the native Windows package type check, and the focused native E2E
on Windows 11 x64. That E2E exercised exact read/write, real lock contention,
sentinel preservation, queued-wake preservation, expiry, and recovery. The
first run exposed a test-harness deadlock: `EmptyClipboard` synchronously
notified the gpui owner HWND while the test thread waited for the child. The
bounded wait now services sent messages with `PM_NOREMOVE`; the focused E2E
passes with the normal clipboard notification and leaves the queued wake for
the backend dispatcher. The standard and pinned local-actrun runner paths are
wired to retain fixture/build/E2E logs under `_build/windows-native/` and
`_build/windows-actrun/`. On 2026-10-07, the pinned local actrun native and
portable profiles both completed run 1 with exit code 0 and all required tasks
successful on Windows 11 x64, against the unchanged implementation source
`dfa0695bc1903a55824635a5506f68b377548279`. The run recorded WasmGC, JavaScript,
and Wasm tests at 382/382 each; contract tests at 30/30 plus repository
validation; Windows package tests at 12/12; DirectWrite and field tests at
4/4 and 12/12; native GPU/clipboard E2E and lifecycle at 1/1 each; and both
startup smokes through `FrameCompleted`. No fixture processes remained. The
manifest and task logs are retained under `_build/windows-actrun/`. This
qualifies only the bounded fixture cases on this host; the broader roadmap
gates above remain open.

## Goal

Provide a real native gpui.mbt desktop backend for Windows using the same core,
element, layout, scene, and backend contracts as macOS and Ubuntu.

The first native success criterion is:

`MoonBit executable -> Win32 message loop -> HWND -> native GPU surface -> SceneSnapshot frame -> input -> clean close`.

## Backend boundary

Use a thin repository-owned native shim around Windows APIs:

- Win32 application/window/message-loop integration
- a native GPU presentation path behind the shared renderer contract
- Windows clipboard/cursor/display APIs
- native text/IME services
- Windows accessibility APIs

Choose the concrete GPU API during implementation based on the renderer
contract and MoonBit/native FFI constraints. That choice must remain below the
renderer/backend boundary; core and SceneSnapshot must not expose HWND, COM,
GPU handles, or Windows-only types.

## Work packets

### A. Host/message loop and one window

Implement:

- process/UI-thread initialization
- message pump and wake mechanism
- one `HWND` lifecycle
- title/logical-size updates
- close request vs destruction
- typed Win32/FFI errors

Acceptance:

- a MoonBit native executable opens one visible Windows window
- wake/request-exit semantics match the common host contract
- repeating destruction of the most recently destroyed window in the same
  host generation succeeds; other stale window handles are rejected
- callbacks/messages for destroyed generations cannot revive stale state

### B. Native GPU surface and first frame

Implement:

- device/queue/context initialization for the selected backend
- window-bound presentation surface
- resize lifecycle
- rendering of the supported SceneSnapshot v1 subset
- present/completion handling

Acceptance:

- a deterministic quad scene renders in a real native window
- resize/DPI changes cannot render through stale surface dimensions
- teardown releases GPU/window resources cleanly

This is the minimum bar for saying "gpui.mbt runs a native Windows GUI app".

### C. Input, focus, DPI, clipboard

Implement:

- pointer/mouse
- keyboard
- focus
- cursor
- close/resize
- per-monitor DPI/display metadata
- clipboard

Acceptance:

- native event ordering is preserved by the shared event model
- logical coordinates remain independent of physical pixels
- per-monitor DPI transitions update scale before later input/frame use
- focus and clipboard native E2E pass

### D. Text and Japanese IME

Implement the shared composition/caret contract using the selected Windows
text/IME integration.

Acceptance:

- composition start/update/commit/cancel
- candidate placement tracks caret
- focus transitions during composition are deterministic
- Japanese input smoke passes
- Latin/Japanese/emoji/combining/bidi fixtures render correctly for the
  supported text stack

### E. Accessibility and native services

Bridge the semantic accessibility tree to the selected Windows accessibility
API.

Acceptance:

- role/name/value/state/focus/action baseline
- native accessibility smoke
- unsupported capabilities return typed errors

### F. Multi-window, resource lifetime, recovery

Acceptance:

- multiple windows can coexist and close independently
- repeated create/destroy is bounded
- stale HWND/message/native callback cases are ignored safely
- renderer/device/surface loss follows the shared recovery state machine
- failure leaves the application alive when the common contract defines the
  error as recoverable

### G. Windows CI/support evidence

Add:

- native Windows build
- executable smoke
- native E2E
- DPI/input evidence
- retained failure artifacts
- release-ledger evidence hooks

Tier 0 means build evidence only. Tier 1 requires issue 0005's native E2E,
IME, accessibility, multi-DPI, multi-window, renderer recovery, performance,
and sustained resource-lifetime evidence.

## Testing

Required layers:

1. shared backend conformance tests
2. Win32 lifecycle/message translation tests
3. native Windows E2E
4. visual/render smoke
5. Japanese IME smoke
6. accessibility smoke
7. repeated create/destroy and resize/input stress
8. renderer recovery fault injection

Use vlmkit only as an optional external black-box oracle and never as the sole
native correctness gate.

## Non-goals for the first native slice

Do not block first-window success on:

- full SceneSnapshot v1 content
- every Windows version
- every GPU vendor
- full accessibility/text completeness
- Tier 1 production support

Those require separate evidence before support claims are promoted.

## Implementation progress — 2026-10-04

An experimental one-window Win32/DXGI/D3D11 backend and runnable example now
exist; the implementation and evidence boundary are in
[docs/windows-native.md](../../docs/windows-native.md). The slice includes
per-monitor-v2 logical sizing, WARP fallback, basic pointer/keyboard/focus,
Unicode clipboard, cursors, D3D readback, and synchronized cross-thread
wake/exit posting during host teardown. Portable MoonBit tests and strict
MinGW syntax compilation pass locally. The hosted [Windows Server 2025 run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37189457500)
for PR head `a1f6e523dc41317064c5657179baa20456dcf6b1` passed the MSVC shim build,
portable tests (6/6), native GPU E2E (1/1), shared backend conformance (1/1),
and example app smoke. This verifies the experimental one-HWND slice on that
hosted configuration. The one-window limit and implementation details remain
as described in the guide; no Windows support tier or production claim is
promoted by this run.

The one-HWND limit remains. Multi-window behavior, physical multi-monitor DPI
transitions, Japanese IME/text shaping, accessibility, menus, renderer/device
loss recovery, external clipboard interoperability, sustained resource
lifetime, physical-GPU coverage, and performance remain open. No Windows
support tier or production claim is promoted.
