# Windows native backend roadmap

Status: open
Parent: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md)
Updated: 2026-10-04

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
