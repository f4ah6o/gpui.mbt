# Ubuntu native backend roadmap

Status: open
Parent: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md)
Updated: 2026-10-03

## Goal

Provide a real native gpui.mbt desktop backend for Ubuntu while preserving the
same platform-neutral core and SceneSnapshot contracts used by macOS and
Windows.

Ubuntu is tracked separately from generic "Linux" so the project can define a
repeatable distro/session/toolchain test matrix instead of making an
unverifiable blanket Linux support claim.

## Initial backend boundary

Target a native Linux desktop path with:

- Wayland as the primary window/input protocol
- xdg-shell for toplevel windows
- a native GPU surface/backend selected behind the shared renderer contract
- system clipboard/data-device integration
- native text-input/IME integration
- Linux accessibility bridge appropriate to the supported desktop session

X11/XWayland compatibility is a separate compatibility decision. Do not imply
it from a working Wayland backend.

Do not expose Wayland objects, file descriptors, GPU handles, or desktop-bus
implementation types through core/public application APIs.

## Work packets

### A. Session detection and host loop

Implement:

- backend/session initialization
- display connection ownership
- event-loop wakeup and dispatch
- clean disconnect/error handling
- typed unsupported-session errors

Acceptance:

- a MoonBit executable starts under the supported Ubuntu desktop session
- host wake/request-exit semantics match the common backend contract
- initialization failure leaves no half-live backend state

### B. One native window and GPU surface

Implement:

- xdg toplevel creation/configuration/destruction
- logical size/title updates
- surface creation and resize
- rendering of the supported SceneSnapshot v1 subset
- frame presentation and completion

Acceptance:

- one visible native Ubuntu window renders a deterministic quad scene
- configure/resize sequencing cannot present against stale dimensions
- clean close releases window and surface resources

This is the minimum bar for saying "gpui.mbt runs a native Ubuntu GUI app".

### C. Input, focus, scale, clipboard

Implement:

- pointer
- keyboard
- focus
- cursor
- output/display metadata
- fractional/integer scale behavior required by the supported compositor path
- clipboard/data transfer

Acceptance:

- logical-coordinate input reaches the shared event model in source order
- focus transitions match headless semantics
- scale changes take effect before later input/frame events
- clipboard failures are typed and observable

### D. Text and IME

Integrate the supported Linux text-input/IME path without leaking it into the
public text API.

Acceptance:

- composition start/update/commit/cancel
- caret/candidate positioning contract
- Japanese input smoke under the supported Ubuntu session
- mixed-script/emoji/combining/bidi rendering fixtures

### E. Accessibility

Bridge the internal semantic tree to the accessibility stack chosen for the
supported Ubuntu desktop environment.

Acceptance:

- role/name/value/state/focus/action baseline
- native assistive-technology smoke
- no rendering-only accessibility implementation

### F. Lifecycle stress and recovery

Acceptance:

- repeated window create/destroy
- resize storm
- input storm
- compositor/display reconnect or equivalent recoverable failure behavior where
  the selected stack permits it
- renderer/surface loss recovery
- no unbounded resource growth in sustained tests

### G. Ubuntu CI/support matrix

Before any support claim, pin and document:

- Ubuntu release(s)
- desktop/session type
- compositor used by CI/E2E
- native toolchain/system packages
- GPU/software-render configuration used for evidence

A CI build alone is Tier 0 evidence only. Tier 1 additionally requires native
E2E, Japanese IME, accessibility, DPI/scale, recovery, performance, and
resource-lifetime gates from issue 0005.

## Compatibility decisions that must stay explicit

Track separately:

- Wayland native support
- X11 native support, if later implemented
- XWayland behavior
- desktop-environment-specific differences
- GPU backend differences
- headless CI compositor behavior vs real desktop evidence

Do not label the platform simply "Linux supported" based on one Ubuntu/Wayland
configuration.

## Testing

Required layers:

1. shared backend conformance tests
2. protocol/window lifecycle tests
3. native Ubuntu E2E under a pinned session
4. visual/render smoke
5. Japanese IME smoke
6. accessibility smoke
7. lifecycle/resource stress
8. renderer/surface recovery fault tests

Use vlmkit only as an optional black-box UI oracle. All content supplied to it
must follow the repository's external-AI/data-handling policy.

## Non-goals for the first native slice

The first Ubuntu window does not require:

- X11 parity
- every desktop environment
- every GPU vendor
- full text/accessibility completeness
- Tier 1 status

Those are later compatibility/support gates.
