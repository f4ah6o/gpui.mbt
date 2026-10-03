# JavaScript browser proof of concept

This first browser slice demonstrates one portable MoonBit app model hosted by a
single browser canvas. The app fixture uses the shared `App` entity model,
flex-tree layout, element hit testing, focus handling, common event ingress,
and `SceneSnapshot` v1 data. A small JavaScript host owns the canvas, Canvas 2D
context, browser callbacks, device-pixel-ratio measurement, and animation-frame
scheduling.

This is execution evidence for the first JavaScript slice. It does not close
[`issues/open/0009-browser-backend.md`](../issues/open/0009-browser-backend.md)
or establish a production browser backend. WasmGC and Wasm targets, WebGPU,
text and Japanese IME, accessibility, clipboard/cursor services, renderer
recovery, and production support remain open work.

## Browser development toolchain

Browser development and production packaging use Vite+ through the `vp` CLI.
`vite-plugin-moonbit` resolves the MoonBit browser package through the
`mbt:` import, starts `moon build --watch` in development, and forwards
MoonBit source maps into Vite.

The Vite config performs one synchronous MoonBit JS build before Vite resolves
the first module. This keeps both `vp dev` and `vp build` valid from a clean
checkout; the MoonBit plugin then owns the normal dev watch/reload path.

Use the repository-pinned MoonBit toolchain and a Node.js release accepted by
Vite+ 1.0.0 (`^22.18.0 || ^24.11.0 || >=26.0.0`). From a clean checkout:

```sh
vp install
vp dev
```

The development server serves the browser proof directly. MoonBit edits rebuild
through the plugin and Vite refreshes the affected browser module.

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

For initial repository setup, enable GitHub Pages with **Build and deployment →
Source: GitHub Actions**. The workflow uses the `github-pages` environment and
the built-in `GITHUB_TOKEN`; it does not publish a generated branch. Allow
`main` in the `github-pages` environment's deployment branch rules; feature
branch and pull request runs never target that protected environment.

## Boundaries and current capability report

The browser host reports one logical viewport, Canvas 2D quad frames, browser
pointer/keyboard input, and request-animation-frame scheduling. It reports no
native top-level window, clipboard, cursor control, IME/text input, accessibility
bridge, renderer recovery, or worker command support. Browser callbacks enqueue
framework-owned events; only a scheduled frame drains them into the app. Hidden
pages cancel pending frames and wait for visibility before requesting another.

Canvas coordinates and layout use CSS pixels. The canvas backing store follows
the measured device-pixel ratio. A device-pixel content-box `ResizeObserver`
tracks backing-size changes, with a CSS-size fallback and a resolution media
query for live DPR changes. SceneSnapshot v1 resources must be empty and items
must be quads; rectangle clip chains are applied in viewport space before each
item's affine transform, and opacity is carried to Canvas 2D. Unsupported or
invalid snapshots, missing canvas/context, invalid viewport measurements, and
context loss surface typed framework diagnostics in the page.
