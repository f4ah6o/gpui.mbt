# macOS native backend roadmap

Status: open
Parent: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md)
Updated: 2026-10-03

## Goal

Make gpui.mbt launch and run as a real macOS GUI application using the shared
platform contract. This is the first native backend and the first point where
the project may claim that a minimal native app actually runs.

The initial success criterion is not production readiness. It is:

`MoonBit app -> native event loop -> native window -> SceneSnapshot -> GPU frame -> input -> clean close`.

## Backend choice

Use a thin repository-owned native shim around:

- AppKit for application/window/event-loop integration
- Core Animation for the window-backed layer
- Metal for the native GPU surface and frame presentation
- native macOS clipboard, cursor, text-input/IME, menus, and accessibility APIs

Keep Objective-C/C implementation details behind a narrow C ABI. Core,
element, layout, scene, and public application APIs must not expose AppKit,
Metal, Objective-C object pointers, or other backend-specific handles.

## Work packets

### A. Native host and one window

Implement:

- application startup/shutdown
- UI-thread ownership
- wake/request-exit integration
- one `NSWindow` lifecycle
- title and logical-size updates
- close-request vs final destruction
- typed initialization/window errors

Acceptance:

- a MoonBit executable launches from a clean checkout
- one visible native window opens without a Rust/JS/browser host
- close exits without a leaked or stale logical window
- repeated start/stop failure paths are deterministic

### B. Metal surface and first frame

Implement:

- `CAMetalLayer` ownership
- Metal device/queue setup
- surface creation/resizing
- conversion of the supported SceneSnapshot v1 subset into draw work
- present/frame completion lifecycle

Acceptance:

- a deterministic quad scene renders in a real window
- resize produces a correctly sized drawable
- logical points and backing scale are kept separate
- no GPU/native handle enters SceneSnapshot or core APIs

This milestone is the minimum bar for saying "gpui.mbt runs a native macOS
GUI app".

### C. Input, focus, and DPI

Implement:

- pointer move/down/up
- keyboard events
- focus changes
- window resize/move notifications
- backing-scale/display changes
- cursor selection
- clipboard read/write

Acceptance:

- native input ordering maps to the shared event contract
- hit testing uses logical coordinates
- moving between displays updates scale before subsequent input/frame use
- focus and close behavior pass native E2E

### D. Text and Japanese IME

Implement the shared text-input contract through the macOS text-input client
surface.

Acceptance:

- composition start/update/commit/cancel
- candidate rectangle follows the active caret
- focus changes during composition are handled deterministically
- Japanese input smoke test passes
- Latin, Japanese, emoji, combining-mark and bidi fixtures render through the
  chosen text path

### E. Accessibility and native services

Implement:

- semantic tree to macOS accessibility bridge
- role/name/value/state/focus/action mapping
- native menus if exposed publicly

Acceptance:

- controls are discoverable through the macOS accessibility API
- focus/action round trips work
- unsupported services return typed capability errors rather than succeeding
  silently

### F. Multi-window, teardown, and renderer recovery

Acceptance:

- create/use/close multiple windows
- repeated create/destroy has no unbounded resource growth
- stale callbacks are ignored after logical destruction
- surface/device-loss path follows the shared recovery contract
- explicit renderer recovery is testable

### G. Packaging and CI evidence

Add:

- native macOS build job
- executable/app-bundle smoke
- native E2E runner
- failure artifacts/logs
- release-gate evidence hooks

Do not promote macOS above Tier 0/2 until the evidence required by
`docs/platform.md` and issue 0005 exists. Tier 1 requires IME,
accessibility, multi-DPI, multi-window, renderer recovery, performance, and
sustained resource-lifetime evidence.

## Testing

Required layers:

1. headless backend-contract/model tests
2. native lifecycle/input E2E
3. scene-vs-frame visual checks where deterministic enough
4. Japanese IME smoke
5. accessibility integration smoke
6. repeated window/surface churn
7. renderer recovery fault injection

Use vlmkit only as an external black-box visual/input oracle where it adds
evidence; native correctness must not depend on an external AI service.

## Non-goals for the first native slice

Do not block the first visible window on:

- full SceneSnapshot v1 completion
- complete text shaping
- accessibility completeness
- all production performance work
- Windows or Ubuntu parity

Those remain required before the corresponding support/release claims.
