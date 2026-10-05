# JavaScript browser proof of concept

This browser slice demonstrates one portable MoonBit app model hosted by a
single browser canvas. The app fixture uses the shared `App` entity model,
flex-tree layout, element hit testing, focus handling, common event ingress,
and `SceneSnapshot` v1 data. A small JavaScript host owns the canvas, Canvas 2D
context, browser callbacks, device-pixel-ratio measurement, wheel translation,
and animation-frame scheduling. A fixture-only ARIA layer mirrors four
framework-provided button descriptions; a migration-only DOM island occupies a
logical layout region and reports focus ownership back to the host.

This is execution evidence for the experimental JavaScript slice. It does not close
[`issues/open/0009-browser-backend.md`](../issues/open/0009-browser-backend.md)
or establish a production browser backend. WasmGC and Wasm targets, WebGPU,
text and Japanese IME, a general accessibility tree/adapter, clipboard
services, renderer recovery, and production support remain open work.
The rendered counter fixture also exercises one shared typed capability through
its GUI binding, direct API, and an in-process MCP adapter call. That adapter
does not start MCP wire transport or expose browser host privileges.

## Browser development toolchain

Browser development and production packaging use Vite+ through the `vp` CLI. The committed `pnpm-lock.yaml` is the dependency-resolution source of truth.
`vite-plugin-moonbit` resolves the MoonBit browser package through the
`mbt:` import, starts `moon build --watch` in development, and forwards
MoonBit source maps into Vite.

The Vite config performs one synchronous MoonBit JS build before Vite resolves
the first module. This keeps both `vp dev` and `vp build` valid from a clean
checkout; the MoonBit plugin then owns the normal dev watch/reload path.

Use the repository-pinned MoonBit toolchain and a Node.js release accepted by
Vite+ 1.0.0 (`^22.18.0 || ^24.11.0 || >=26.0.0`). The project pins pnpm 12.9.1 for dependency resolution. From a clean checkout:

```sh
vp install --frozen-lockfile
vp dev
```

The development server serves the browser proof directly. MoonBit edits rebuild
through the plugin and Vite refreshes the affected browser module.

`vp check` is also part of CI. Its format phase is disabled so Vite+ does not
reformat the repository's existing Markdown/document corpus; `moon fmt --check`
remains the canonical repository formatting gate, while Vite+ supplies the
browser JavaScript/TypeScript lint check.

Build the production artifact with:

```sh
vp build
```

The verified static output is written to `_build/browser-site`. Vite uses a
relative base so the same output can be served locally or from the repository's
GitHub Pages path.

Run the real-browser smoke test with Chromium installed:

```sh
vp run browser:install
vp build
vp run browser:smoke
```

Playwright is pinned at 1.63.0 as a test-only dependency and is not included in
the generated browser bundle. Vite+ is pinned at 1.0.0 and the Vite peer used by
plugins is pinned to the matching `@voidzero-dev/vite-plus-core@1.0.0`.

The CI workflow also runs formatting and MoonBit checks/tests across all
configured targets, installs the pinned Vite+ toolchain, builds through
`vp build`, installs Chromium, runs the smoke test, then uploads and deploys
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

The first hosted run of the expanded smoke
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
input, a general accessibility adapter, clipboard services,
renderer recovery, native/backend conformance, worker commands, and production
browser support remain open.

For initial repository setup, enable GitHub Pages with **Build and deployment →
Source: GitHub Actions**. The workflow uses the `github-pages` environment and
the built-in `GITHUB_TOKEN`; it does not publish a generated branch. Allow
`main` in the `github-pages` environment's deployment branch rules; feature
branch and pull request runs never target that protected environment.

## Boundaries and current capability report

The browser host reports one logical viewport, Canvas 2D quad frames, browser
pointer/keyboard/wheel input, request-animation-frame scheduling, portable
Arrow/PointingHand/Text cursor mapping, and the fixture-specific ARIA layer. It
reports no native top-level window, clipboard, IME/text input, general
accessibility bridge, renderer recovery, or worker command support.

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
query for live DPR changes. SceneSnapshot v1 resources must be empty and items
must be quads; rectangle clip chains are applied in viewport space before each
item's affine transform, and opacity is carried to Canvas 2D. Unsupported or
invalid snapshots, missing canvas/context, invalid viewport measurements, and
context loss surface typed framework diagnostics in the page.

The fixture ARIA layer uses the app's `host_layout_json` descriptions for four
buttons, including role, name, focus, disabled state, and logical bounds. Proxy
buttons are visually hidden from pointer hit testing; focus and actions are
translated back into the app's normal keyboard/event queue. This fixture does
not provide the shared semantic tree, dynamic-node lifetime rules, full value
mapping, or screen-reader coverage required for a general browser adapter.

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
