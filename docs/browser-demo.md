# Browser demos: Weekboard and interaction lab

The JavaScript browser slice has two entry points, both backed by portable
MoonBit application state and `SceneSnapshot` v1 data:

| Page | Purpose |
| --- | --- |
| [`index.html`](../examples/browser/site/index.html) | **Weekboard**, a small website-launch task board with real task titles, lane moves, filtering, history, scrolling, and responsive layout. |
| [`proof.html`](../examples/browser/site/proof.html) | The retained **interaction lab** for the GUI/direct/MCP counter, browser services, fixed ARIA proxies, legacy DOM island, and lifecycle proofs. |

A JavaScript host owns each canvas, Canvas 2D context, browser callbacks,
device-pixel-ratio measurement, wheel translation, and animation-frame
scheduling. Application state, board layout, hit testing, and scene generation
remain in MoonBit.

This is execution evidence for the experimental JavaScript slice. It does not close
[`issues/open/0009-browser-backend.md`](../issues/open/0009-browser-backend.md)
or establish a production browser backend. WasmGC and Wasm targets, WebGPU,
full text editing and Japanese IME, a general accessibility tree/adapter,
GPU recovery, and production support remain open work. The current JS slice
adds scoped plain-text clipboard services, committed-text ingress, and
event-driven Canvas 2D context restoration as described below.
The rendered counter fixture also exercises one shared typed capability through
its GUI binding, direct API, and an in-process MCP adapter call. That adapter
does not start MCP wire transport or expose browser host privileges.

## Weekboard increment — 2026-10-05

Weekboard starts with 12 website-launch tasks: seven in Backlog, three in
In progress, and two in Done. Selecting a card shows its detail and lane-move
actions. Dragging moves a card between lanes; the detail buttons provide the
same move without dragging. Moving within the same lane does not reorder cards.
Search matches task titles and details without case sensitivity. Add accepts
a nonempty, trimmed title of at most 80 UTF-16 code units, rejects control
characters, and allows at most 100 tasks. A successful addition clears the
filter and reveals the new Backlog task. Search is also bounded to 80 UTF-16
code units. Undo retains the last 32 additions or lane moves; task IDs are
never reused. There is no redo or storage service: reloading restores the
seeded board.

Each lane has its own clamped vertical scroll state. Hit testing uses the
visible intersection of a card and its lane viewport, and keyboard navigation
reveals the selected card. Below 700 logical pixels of board width, the view
shows one lane with lane selectors and explicit scroll buttons. Pointer
gestures distinguish a click from a drag and cancel on focus loss, page hiding,
renderer loss, or pointer-capture loss without committing an abandoned move.
The page also exposes explicit task-summary copying through the shared
plain-text clipboard adapter.

The [task model](../examples/task_board/model.mbt) owns these state changes and
history. Its [view](../examples/task_board/view.mbt) uses shared flex layout,
clipping, [ScrollState](../element/scroll.mbt), and
[DragGesture](../element/drag.mbt). The
[JS-only adapter](../examples/browser_board/adapter.mbt) exposes copied input,
status, layout, and scene values. The HTML search/add fields and detail controls
are host UI; their native browser editing does not implement the framework's
text editor or IME contract.

### Bounded text and visible-card semantics

The shared [TextItem](../scene/snapshot.mbt) describes one plain-text run with
bounds, font size, color, transform, opacity, and an optional rectangle clip
chain. [The Canvas renderer](../examples/browser/site/canvas-renderer.js)
draws it left-aligned from the top of its bounds using `system-ui, sans-serif`
and clips overflow. Font size must be finite and in `(0, 1024]`; each run is
limited to 65,536 UTF-16 code units. Snapshot validation applies to constructor
calls and direct enum values. Unicode/control/quote escaping is canonical,
and existing quad JSON remains unchanged. Native renderers explicitly return
`UnsupportedCapability` for text items.

This supplies labels, not portable shaping, font metrics, wrapping, selection,
caret positioning, bidi compatibility, or a rich text/editor contract. It does
not complete the design's resource-backed `TextRun` or Japanese IME support.

The [DOM projection](../examples/browser/site/canvas-accessibility.js) mirrors
the view's currently visible cards as buttons with stable task IDs, names,
selected state, and clipped logical bounds. It updates node order and lifetime
when filtering, scrolling, moving, or undoing changes the visible set. Focus
and keyboard actions return to the portable model. Cards outside the visible
set lose their proxies; suspension retains proxy identity and focus while
blocking action admission. This is a demo-specific projection, not the
shared generational semantic tree or a qualified screen-reader/native adapter.

The board frame shows a visible focus outline while either the canvas or a
card proxy owns focus. The frame paints the outline outside the clipped card
surface, so it remains visible when the selected card is offscreen or removing
a focused proxy returns focus to the canvas.

### Verification for this increment

The implementation is covered by [task-board model tests](../examples/task_board/task_board_wbtest.mbt),
[scroll tests](../element/scroll_test.mbt), [drag tests](../element/drag_test.mbt),
[text snapshot tests](../scene/snapshot_text_test.mbt),
[Canvas renderer tests](../tests/browser/canvas-renderer.test.mjs), and
[DOM projection tests](../tests/browser/canvas-accessibility.test.mjs).
The separate [Weekboard Chromium smoke](../tests/browser/board.mjs) exercises
the built production page, including search/add/move/undo, clipped scrolling,
keyboard and proxy focus, cancellation/restoration, mobile touch/page scrolling,
DPR changes, and recovery from the 100-task limit. Screenshot-based focus checks
cover tabbing into the canvas with an offscreen selection, removing a focused
card proxy by scrolling, and clearing the board's focus indicator on exit.
Browser CI retains the focus screenshots and measured edge coverage with its
smoke diagnostics.

Initial integration checks at `9e112cb3` on 2026-10-05 passed MoonBit
formatting/checks/tests across all configured targets with warnings denied,
56 browser/host Node tests, 61 Python contract checks, Vite+ checks and production
build, the dev-watch and source-map gate, all 15 Weekboard smoke groups, and the
retained interaction-lab Chromium smoke. These are local results; hosted
execution is reported separately by this change's PR checks.
The hosted runs recorded below belong to earlier interaction-lab revisions.

## Browser development toolchain

Browser development and production packaging use Vite+ through the `vp` CLI. The committed `pnpm-lock.yaml` is the dependency-resolution source of truth.
`vite-plugin-moonbit` resolves the MoonBit browser package through the
`mbt:` import, starts `moon build --watch` in development, and forwards
MoonBit source maps into Vite.

The Vite config builds both MoonBit JS entry packages before Vite resolves
the first module. This keeps both `vp dev` and `vp build` valid from a clean
checkout; the MoonBit plugin then owns the normal dev watch/reload path.

Use the repository-pinned MoonBit toolchain and a Node.js release accepted by
Vite+ 1.0.0 (`^22.18.0 || ^24.11.0 || >=26.0.0`). The project pins pnpm 12.9.1 for dependency resolution. From a clean checkout:

```sh
vp install --frozen-lockfile
vp dev
```

The development server opens Weekboard at `/`; the interaction lab is at
`/proof.html`. MoonBit edits rebuild through the plugin and Vite refreshes the
affected browser module.

`vp check` is also part of CI. Its format phase is disabled so Vite+ does not
reformat the repository's existing Markdown/document corpus; `moon fmt --check`
remains the canonical repository formatting gate, while Vite+ supplies the
browser JavaScript/TypeScript lint check.

Build the production artifact with:

```sh
vp build
```

The static output for both pages is written to `_build/browser-site`. Vite uses a
relative base so the same output can be served locally or from the repository's
GitHub Pages path.

Run the real-browser smoke test with Chromium installed:

```sh
vp run browser:install
vp build
vp run browser:canvas:test
vp run browser:services:test
vp run browser:board:smoke
vp run browser:smoke
```

Playwright is pinned at 1.63.0 as a test-only dependency and is not included in
the generated browser bundle. Vite+ is pinned at 1.0.0 and the Vite peer used by
plugins is pinned to the matching `@voidzero-dev/vite-plus-core@1.0.0`.

The CI workflow also runs formatting and MoonBit checks/tests across all
configured targets, installs the pinned Vite+ toolchain, builds through
`vp build`, installs Chromium, runs both smoke tests, then uploads and deploys
that same verified static artifact with GitHub Pages Actions. Pull requests run
verification and package the artifact but do not deploy. Pushes to `main` and
manual runs started from `main` deploy the artifact.

The headless browser smoke injects a synthetic hidden `Document` state and
dispatches the browser's `visibilitychange` event to exercise the suspension
path. It does not claim to validate operating-system tab switching behavior.
The DPR check changes viewport dimensions and device scale together to produce
a real browser resize signal; the smoke does not isolate DPR-only changes.
For direct and in-process MCP counter mutations, the smoke waits until the
sampled Canvas 2D pixel changes before it checks the app value. The app's
observer updates before the host's next animation-frame paint, so waiting only
for the semantic value could inspect the old pixels.

### Historical interaction-lab hosted evidence

The first hosted run of the expanded interaction-lab smoke
([37186910745](https://github.com/f4ah6o/gpui.mbt/actions/runs/37186910745))
reached Chromium but failed the direct-counter redraw assertion because the
test checked the model update before the scheduled paint. The smoke now waits
on the actual canvas pixel. The corrected run
([37187979407](https://github.com/f4ah6o/gpui.mbt/actions/runs/37187979407))
at head [`1dfad6a`](https://github.com/f4ah6o/gpui.mbt/commit/1dfad6a) passed
the full verify-and-package job, including the
all-target checks/tests, Vite+ checks, dev-watch/source-map exercise, production
build, Chromium install and real-browser smoke. The smoke passed Canvas2D
snapshot rendering, DPR updates, pointer/wheel/focus input, GUI/direct/MCP
redraw, ARIA and island focus ownership, resize and hidden-page scheduling,
context-loss handling, and repeated teardown. The Pages artifact was packaged;
deployment was skipped for the pull request.

This is browser execution evidence for the experimental JavaScript Canvas 2D
slice. WasmGC and Wasm browser targets, WebGPU, Japanese IME and broader text
input, a general accessibility adapter,
native/backend conformance, worker commands, and production
browser support remain open.

## Browser service increment — 2026-10-05

The interaction lab at `proof.html` has explicit **Copy text**, **Paste text**, and **Start text input**
controls. The latter displays the last committed insert and its event count in
the inspector; it is an input proof, not a text editor. The canvas still renders
the shared quad scene.

### Plain-text clipboard

The browser adapter uses `navigator.clipboard.readText` and `writeText` through
the existing version-1 host-service request/completion envelope. Operations
must be explicitly allowed and belong to a live logical scope. Requests retain
the existing payload, in-flight, scope, and decimal-ID bounds. The native API
is invoked during the button callback before the first asynchronous yield so
the browser can apply its user-activation policy.

Availability is measured separately from permission. An insecure context or a
missing method produces `unsupported_capability`; browser permission or
user-activation rejection produces `permission_denied`. Other failures retain
the typed service envelope and do not stop rendering. The page never reads
the clipboard at startup. Remount closes the old adapter and ignores late
completion messages; an already-started native write cannot be rolled back.

`clipboard` in the live capability report requires both text methods and a
secure context. Individual Copy/Paste controls reflect their method's
availability. A supported method can still be denied when the user invokes it.

### Committed-text ingress

An opt-in hidden textarea receives browser editing/composition events and sends
only committed inserts through `gpui_browser_text_input` into the existing
`EventIngress` queue and `InputEvent.TextInput`. Input callbacks do not dispatch
the MoonBit app directly. The next scheduled frame exposes
`lastCommittedText` and `textCommitCount` from the shared app model.

Provisional composition is discarded on cancellation, blur, hiding, teardown,
or renderer loss. A composition commit is delivered once even when the browser
also sends its trailing input event. Each commit is bounded to 65,536 UTF-16
code units. Starting text input is explicit; the bridge does not take input
from the existing canvas actions or the legacy web island on its own.

A paste reported as a noncomposing insert is an independent commit even while
a composition is active. Its original plain text is delivered without clearing
the native textarea's provisional composition; the later composition commit or
cancellation does not consume that paste.

The new `committedTextInput` capability is distinct from `textInputIme`, which
remains false. Selection/replacement, deletion, caret/candidate positioning,
editable text layout, native Japanese IME qualification, and a full editor
contract remain open work.

### Canvas 2D restoration

`contextlost` suspends frame scheduling and input while preserving the live
MoonBit application. The handler leaves this event uncancelled so the browser
can restore its backing storage, following the
[HTML context-lost steps](https://html.spec.whatwg.org/multipage/webappapis.html#context-lost-steps).
A `contextrestored` event attempts to reacquire the 2D
context, resynchronizes the latest logical size and DPR, and schedules the
current scene. Only a successful repaint clears the loss diagnostic and
re-enables input. Hidden pages defer that repaint until visible. Focus and
visibility and the active ARIA semantic target are sampled again immediately
before the restored frame drains events so focus moves during that wait are
preserved and the next keyboard activation reaches the focused target.
Semantic selection and clearing are also remembered while input is suspended.
Moving from an ARIA proxy to the legacy island clears the old action target,
including when the canvas regains focus before the restored repaint. A later
ARIA selection supersedes that clearing intent.

The host also cancels its admitted pointer and keyboard holds across loss.
Queued input is retained in acceptance order; each outstanding hold gets
a matching release before the first restored drain, whether its press was
still queued or had already reached the app. This cleanup does not depend on
the browser delivering `lostpointercapture` or a native release while rendering
is suspended. A release is recorded as delivered when the framework accepts
it, so a failed repaint or repeated restoration cannot send it twice. Late
native releases and repeats from the cancelled hold are ignored until a fresh
press starts another gesture. Cancellation releases clear modifier flags as
well. Semantic navigation and activation helpers send
balanced key taps through the same portable input stream.

Restoration is event-driven: one acquisition attempt per restoration event,
with no polling or automatic retry loop. Failed acquisition stays unavailable
until another restoration event or an explicit remount. Remount continues to
create a new logical app. This browser-specific path does not implement the
timed native/GPU recovery policy in [the platform design](platform.md).

### Verification scope

`vp run browser:services:test` covers the service and text-bridge contracts.
The production-artifact Chromium smoke adds clipboard round trips and denial,
committed input and composition/lifecycle cases, and state/pixel preservation
across context restoration. Regressions include real Ctrl+V during CDP
composition and ARIA-to-legacy focus clearing across restoration followed by a
return to the canvas and Enter. Pointer/key regressions cross the boundary from
an accepted press through loss and a suspended release to restoration; they
inspect the shared app model's held inputs, release counts, and modifier flags
after the drain.
Context loss/restoration and hidden-document cases
use explicitly dispatched browser lifecycle events; they do not establish real
GPU fault recovery or operating-system tab/IME behavior. Test-only clipboard
permissions apply only to the isolated Chromium context.

For initial repository setup, enable GitHub Pages with **Build and deployment →
Source: GitHub Actions**. The workflow uses the `github-pages` environment and
the built-in `GITHUB_TOKEN`; it does not publish a generated branch. Allow
`main` in the `github-pages` environment's deployment branch rules; feature
branch and pull request runs never target that protected environment.

## Interaction-lab boundaries and capability report

The browser host reports one logical viewport, Canvas 2D quad frames, browser
pointer/keyboard/wheel input, request-animation-frame scheduling, portable
Arrow/PointingHand/Text cursor mapping, committed-text ingress, event-driven
Canvas 2D restoration, and the fixture-specific ARIA layer. Plain-text clipboard
availability is detected by the host. It reports no native top-level window,
full IME/text editing, general accessibility bridge, or worker command support.

Cursor intent stays framework-owned: the portable demo derives a
`platform.Cursor` from its post-dispatch hover state, the host reads that state
after the scheduled frame drain, and only then maps `Arrow`, `PointingHand`,
and `Text` to the browser's `default`, `pointer`, and `text` CSS cursor
values. Browser callbacks still only enqueue framework-owned events; they do not
directly re-enter framework dispatch. Only a scheduled frame drains them into
the app. Hidden pages cancel pending
frames and wait for visibility before requesting another.

Canvas coordinates and layout use CSS pixels. The canvas backing store follows
the measured device-pixel ratio. A device-pixel content-box `ResizeObserver`
tracks backing-size changes, with a CSS-size fallback and a resolution media
query for live DPR changes. The shared Canvas renderer accepts SceneSnapshot
v1 quads and bounded text items with empty resources; rectangle clip chains are
applied in viewport space before each item's affine transform, and opacity is
carried to Canvas 2D. Text bounds add an item-local clip after the transform.
Unsupported or
invalid snapshots, missing canvas/context, invalid viewport measurements, and
context loss surface typed framework diagnostics in the page.

The interaction lab's fixture ARIA layer uses the app's `host_layout_json` descriptions for four
buttons, including role, name, focus, disabled state, and logical bounds. Proxy
buttons are visually hidden from pointer hit testing; focus and actions are
translated back into the app's normal keyboard/event queue. This fixture does
not provide the shared semantic tree, dynamic-node lifetime rules, full value
mapping, or screen-reader coverage required for a general browser adapter.
Weekboard's dynamic visible-card projection is described separately above.

The migration island reserves region 8 in the app-provided layout DTO. The JS
host positions an existing-style note editor there, keeps its tab sequence
inside the island, and reports its current input owner. Hiding or disposing a
focused island returns focus to the framework canvas. The Chromium smoke covers
the island alongside pointer, wheel, GUI/direct/MCP capability redraw, resize,
visibility, renderer loss, and repeated remount behavior.

The shared migration service envelope and JS contract adapters are described
in [Electron and Tauri migration](electron-tauri-migration.md). Contract tests
run with fake IPC/invoke functions. No real Electron or Tauri application is
built or launched by this repository's current browser proof.
