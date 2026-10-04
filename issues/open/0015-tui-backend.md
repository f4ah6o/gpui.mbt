# Terminal UI backend and shared application semantics

Status: open
Parent: [0001-product-charter-and-compatibility.md](0001-product-charter-and-compatibility.md)
Related: [0004-platform-rendering-and-native-boundaries.md](0004-platform-rendering-and-native-boundaries.md), [0012-semantic-capability-model.md](0012-semantic-capability-model.md)
Updated: 2026-10-04

## Goal

Add a production-usable terminal UI surface to gpui.mbt without turning the
graphical scene model into a terminal emulation layer and without forking the
application state model.

The TUI surface should reuse the parts of gpui.mbt that are genuinely
presentation-independent:

- App / Entity / Context lifecycle
- deterministic scheduling
- actions and key bindings
- focus ownership and navigation semantics where applicable
- semantic capabilities
- application notifications and invalidation
- diagnostics and error contracts

Terminal rendering is a sibling presentation surface, not an ANSI renderer for
arbitrary graphical `SceneSnapshot` data.

## Scope decision

A terminal is a cell grid with terminal-specific input and capability
negotiation. Mapping pixel geometry, paths, images, GPU resources, native IME,
or graphical accessibility APIs directly onto that grid would produce a leaky
and misleading abstraction.

Therefore the architecture is:

```text
                         -> graphical Element / SceneSnapshot -> native/browser renderer
App / Entity / actions --|
                         -> TUI view -> CellScene -> terminal renderer

semantic capabilities ------------------------------^
```

The two surfaces share application semantics before presentation. They do not
need to share the final layout tree or scene representation.

TUI support is additive. It does not expand the graphical GPUI compatibility
claim and does not block the GUI-oriented 1.0 release gates unless the project
later explicitly promotes TUI into the 1.0 support matrix.

## Non-goals

- render arbitrary graphical `SceneSnapshot` commands in a terminal
- emulate CSS/pixel flex layout at cell resolution
- require ncurses, termbox, ratatui, or another runtime framework dependency
- expose ANSI escape sequences in portable application APIs
- promise terminal image protocols in the first implementation
- make every GUI widget automatically available as a TUI widget
- claim native accessibility/IME parity merely because text can be printed

## Package boundary

Prefer a dedicated portable package such as `tui/` with a small terminal host
boundary below it.

Portable TUI code owns:

- cell coordinates and dimensions
- styles represented semantically, not as ANSI bytes
- `CellScene`
- deterministic layout helpers
- focus order
- TUI view/widget contracts
- event normalization
- scene diffing inputs
- headless snapshots

Host/platform code owns:

- raw/cooked terminal mode
- terminal size discovery and resize notification
- byte input and escape-sequence decoding
- output writes and flush
- alternate-screen lifecycle
- cursor visibility/shape where supported
- bracketed paste and mouse-mode enable/disable
- terminal capability detection
- restoration after normal exit and recoverable failure

Application-facing packages must not depend on a Unix file descriptor, Win32
console handle, PTY implementation, or ANSI parser type.

## Cell scene

Define a deterministic terminal scene independent from output encoding.

A first `CellScene` should contain:

- width and height in cells
- ordered rows/cells or a deterministic sparse equivalent
- grapheme/text payload
- foreground/background semantic color
- style flags such as bold/italic/underline where supported
- optional semantic cursor position
- stable focus/selection metadata only when required by the TUI contract

The scene serializer used by tests must be versioned or explicitly marked
provisional before public stability is claimed.

Text width is not `String.length`. The contract must explicitly handle:

- ASCII
- Japanese full-width characters
- combining marks
- emoji
- zero-width code points
- ambiguous-width policy
- clipping at a cell boundary

Until MoonBit provides all required Unicode width primitives, implement the
smallest deterministic table/algorithm in-repository rather than adding a
runtime dependency.

## Rendering

The terminal renderer consumes `CellScene` and emits the smallest safe update
sequence for the active terminal capabilities.

Start with correctness over aggressive diffing:

1. deterministic full-frame renderer
2. row/cell diff renderer
3. optional damage/coalescing optimization

Required invariants:

- no style state leaks across frame boundaries
- cursor position after a frame is deterministic
- resized terminals cannot reuse stale dimensions
- unsupported style/color features degrade explicitly
- terminal restoration is attempted after renderer/host failure
- one logical frame produces bounded output

The output encoder may support capability tiers such as:

- plain / no-color
- ANSI 16 color
- 256 color
- truecolor

Capability detection must not silently assume truecolor.

## Input model

Normalize terminal input before application dispatch.

Initial events:

- printable text
- Enter / Tab / Backspace / Escape
- arrows, Home/End, PageUp/PageDown
- function keys where reliably decoded
- Ctrl/Alt/Shift modifiers where representable
- resize
- focus in/out where the terminal reports it
- bracketed paste

Mouse input is optional for the first slice but should have a reserved event
shape so enabling SGR mouse reporting later does not require an API redesign.

Escape parsing must handle incomplete byte sequences incrementally and must
bound buffered input. Malformed or unsupported sequences must not wedge the
event loop.

## Focus, actions, and key bindings

TUI focus is terminal-widget focus, not graphical hit-test focus.

Reuse shared action dispatch and key-binding concepts, but keep the mapping from
terminal key events to focused TUI nodes inside the TUI layer.

Acceptance requires that a semantic action invoked from:

- a graphical control,
- a TUI key binding, and
- a direct capability invocation

can converge on the same domain operation and produce the same application state
transition when the application deliberately exposes all three surfaces.

## Semantic capability integration

The TUI is a first-class consumer of the capability model from issue 0012.

A TUI control should be able to bind to the same registered command/query as a
GUI control without copying the domain handler.

Example:

```text
GUI Save button ----\
TUI "s" binding ------> document.save capability -> domain state
MCP tool -----------/
```

Presentation-specific argument construction, confirmation, labels, shortcuts,
and error display remain surface-owned.

## Terminal lifecycle and failure safety

Terminal mode changes are process-global side effects on many platforms and
must be treated as owned resources.

Required behavior:

- entering raw/alternate-screen mode is explicit and fallible
- partial initialization unwinds already-acquired terminal state
- normal shutdown restores terminal mode
- renderer/input failure attempts restoration before returning the error
- repeated create/destroy does not accumulate enabled terminal modes
- application state teardown invalidates TUI handles

Crash/signal restoration may require a platform-specific best-effort boundary;
document what is and is not guaranteed rather than claiming impossible safety.

## Platform strategy

The portable TUI layer should be cross-platform, while host bindings may differ.

### Unix-like first host

A Unix-like host may use the smallest necessary FFI for:

- TTY detection
- termios/raw mode
- terminal size
- blocking/non-blocking input as required by the scheduler boundary
- writes

Do not depend on ncurses.

### Windows host

Treat modern Windows Terminal / VT processing as the preferred path where
available, with a Win32 console boundary only where needed for mode setup,
resizing, or input compatibility.

Do not let Win32 console structures leak into portable TUI APIs.

## Testing strategy

### Headless deterministic tests

No terminal required:

- layout to cell bounds
- focus order
- input normalization fixtures
- Unicode width fixtures
- `CellScene` snapshots
- full-frame output encoding
- diff rendering equivalence
- resize invalidation
- capability fallback
- malformed/incomplete escape sequences

### Property-based tests

Use QuickCheck for invariants such as:

- diff-rendered terminal state equals full-frame terminal state
- clipping never writes outside scene bounds
- style reset leaves a known terminal state
- parser chunking does not change normalized event output
- resize sequences never retain out-of-bounds cursor/focus state

### Mutation testing

Add TUI parser, clipping, diff, width, and restoration-state logic to the
mutation ratchet once deterministic tests exist.

### PTY integration

Use a PTY/conpty-style black-box harness where available to prove:

- startup mode changes
- key/paste/resize ingress
- frame bytes
- teardown/restoration
- repeated start/stop

PTY tests are host evidence; headless tests remain the portable oracle.

## Work packets

### A. Portable cell model

Implement cell geometry, semantic styles, `CellScene`, deterministic
serialization, clipping, and Unicode-width policy.

Acceptance:

- Japanese, combining-mark, and emoji fixtures have deterministic widths
- invalid coordinates/styles fail predictably
- snapshots are byte-stable
- no ANSI or OS type appears in `CellScene`

### B. TUI view/layout/focus contract

Implement the smallest view/widget contract needed for text, rows/columns,
padding, focusable controls, labels, and selection.

Acceptance:

- a nested form-like fixture lays out deterministically
- resize recomputes cell layout
- focus traversal is deterministic
- actions can be dispatched without graphical hit testing

### C. Terminal encoder and diff renderer

Implement safe terminal output for the initial capability tier plus a
deterministic diff path.

Acceptance:

- applying diff output yields the same terminal model as a full redraw
- style/cursor state is reset or tracked deterministically
- resize forces a safe redraw
- unsupported color/style capability has a documented degradation path

### D. Unix-like host

Implement TTY lifecycle, resize, byte input, output, alternate screen, and
restoration behind the host boundary.

Acceptance:

- PTY smoke starts, renders, accepts input, resizes, and exits cleanly
- partial initialization unwinds
- repeated start/stop leaves the outer shell usable
- no host handle leaks into portable APIs

### E. Input parser

Implement bounded incremental decoding for keyboard, paste, focus, and reserved
mouse events.

Acceptance:

- parser output is invariant to chunk boundaries
- incomplete sequences wait only within documented bounds
- malformed input returns typed diagnostics or literal fallback according to
  the contract
- bracketed paste cannot be mistaken for ordinary control input

### F. Capability/action integration

Bind TUI controls and keys to shared actions/capabilities.

Acceptance:

- one fixture exposes the same write operation through GUI, TUI, direct API,
  and MCP/in-process adapter where those surfaces are available
- all paths produce the same normalized state and notifications
- TUI-only presentation behavior remains outside the domain operation

### G. Windows host

Add Windows Terminal/VT lifecycle and input/output support without changing the
portable TUI API.

Acceptance:

- the shared headless suite passes unchanged
- Windows host smoke covers start/input/resize/restore
- unsupported console environments fail or degrade explicitly

## Acceptance gate

This issue is complete when:

1. a clean checkout builds a terminal example with standard runtime
   dependencies only;
2. the example runs in a real terminal and in a PTY-style integration test;
3. text/input/resize/focus/action behavior is deterministic under the documented
   capability tier;
4. Japanese/full-width, combining-mark, emoji, and paste fixtures pass;
5. a TUI control invokes shared application semantics rather than a duplicate
   domain handler;
6. terminal teardown/restoration evidence exists for normal and injected
   failure paths;
7. the graphical `SceneSnapshot` contract remains unchanged by TUI support;
8. TUI support is documented separately from graphical GPUI compatibility and
   platform Tier 1 claims.

## Suggested implementation order

1. A — portable cell model
2. B — TUI view/layout/focus
3. E — input parser
4. C — encoder/diff renderer
5. D — Unix-like host
6. F — shared capability/action fixture
7. G — Windows host

This order keeps most correctness work headless and deterministic before adding
terminal-global side effects.
