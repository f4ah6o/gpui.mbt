# macOS native backend roadmap

Status: open
Model: gpt-6-luna
Parent: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md)
Updated: 2026-10-10

## Current-head acceptance triage — 2026-10-04

Basis: merged main HEAD `1dea499e34a36a64927791c94f35965a91c305a2`; PR #13
head `d70b1255aa5dc1eaaea04a67a9ea748d29317cbd`.

- [x] The AppKit/Metal backend, app-bundle build, and native E2E runner are
  present; the hosted [contracts/core run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649283)
  built the bundle and runner and passed the portable native tests.
- [ ] That hosted macOS job is build-only. A final-head native window/frame
  runtime result and Metal recovery runtime result are not recorded.
- [ ] Clipboard/cursor smoke, multi-display DPI, text shaping/Japanese IME,
  accessibility, menus, complete multi-window behavior, sustained resources,
  and comparable performance evidence remain open.

Keep the backend experimental; this evidence does not satisfy a macOS support
tier or release gate.

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

## Implementation progress — 2026-10-03

The first native slice is implemented; this roadmap remains open for later
packets. See [macos-native.md](../../docs/macos-native.md) for the exact boundary.

- A/B: MoonBit executable, UI-owned AppKit lifecycle, logical window identities,
  title/size/close policy, CAMetalLayer and Metal command completion, and v1
  quad/transform/opacity/rectangle-clip rendering are implemented.
- C: Pointer/key/focus/move/resize/backing-scale events, cursor and clipboard
  APIs are implemented. Real multi-display E2E and clipboard/cursor smoke remain.
- D/E: Text shaping, text-input/IME, semantic accessibility, public native menus
  and their smoke tests remain pending.
- F: Multiple windows, token/host generations, callback invalidation and 32-cycle
  churn are covered. Automatic recovery, sustained resource growth and full
  multi-window focus/display E2E remain pending. DeviceLost reporting is tested.
- G: App-bundle build, hosted macOS build/headless CI, and a manual native
  self-hosted E2E workflow with artifacts are added. Packaging/notarization and
  complete release-gate evidence remain pending.

Local validation: all four MoonBit targets pass 66 tests each with warnings
denied. Native E2E verifies GPU pixel fixtures, pointer/key delivery, logical
coordinates, resize, close policy, wrong-thread/stale rejection and churn.
MoonBit smoke verifies two GPU frames, resize and clean close. This is local
evidence; new CI workflows have not yet run. No support tier or production
release gate has been promoted.

## Implementation progress — 2026-10-04

The implemented boundary and open evidence are summarized in
[docs/macos-native.md](../../docs/macos-native.md). The native E2E source now
also injects renderer resource loss, exercises explicit Metal device/queue/
pipeline recreation and layer rebinding, then checks the following frame by
pixel readback. The manual self-hosted Metal workflow is configured, but its
runtime result has not been observed; renderer recovery remains unadvertised.

Native clipboard and cursor APIs are implemented, while clipboard/cursor smoke,
real multi-display DPI movement, Japanese IME/text shaping, accessibility,
menus, cross-thread command completion, full multi-window focus/display E2E,
sustained resource-growth evidence, and performance evidence remain open. No
support tier or release gate is promoted by source tests or workflow
configuration alone.

## Implementation progress — 2026-10-10

AppKit `scrollWheel:` now emits the shared scroll event with logical pointer
coordinates and native `scrollingDeltaX/Y` values. Precise point deltas and
non-precise line/row deltas remain unnormalized because the portable event has
no precision/unit discriminator. A portable decoder test and native responder
smoke cover signed deltas, modifiers, and both AppKit precision modes. The
responder smoke reads deltas from `NSEvent` objects created from Core Graphics
scroll events, but does not establish normal window-system delivery or
physical-device scrolling.

The native E2E also round-trips UTF-8 through a unique private pasteboard and
checks supported cursor selection and unsupported-tag handling. It does not
touch the user's General Pasteboard. General Pasteboard exchange, visible
cursor confirmation, real multi-display DPI movement, IME, accessibility,
menus, and release/support gates remain open.
