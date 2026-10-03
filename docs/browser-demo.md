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

## Build and run

Use the repository-pinned MoonBit toolchain and Node.js 24 or newer. From a clean
checkout:

```sh
./scripts/build_browser_demo.sh
python3 -m http.server --directory _build/browser-site 8000
```

Open `http://localhost:8000`. The static directory contains the page, the
repository-owned host bootstrap, and the generated JavaScript module. Serve it
over HTTP so the browser can load the module.

Run the real-browser smoke test with Chromium installed:

```sh
npm ci --prefix tests/browser
npx --prefix tests/browser playwright install chromium
npm --prefix tests/browser run smoke
```

Playwright is pinned at 1.63.0 as a test-only dependency (Apache-2.0 in the
lockfile). It is not included in the generated browser bundle.

The CI workflow also runs formatting and MoonBit checks/tests across all
configured targets, installs Chromium, runs the smoke test, then uploads and
deploys that same verified static artifact with GitHub Pages Actions. Pushes to
`feature/browser-backend-poc` and pull requests run verification and package the
artifact but do not deploy. Pushes to `main` and manual runs started from `main`
deploy the artifact. The first live deployment follows merge to `main` and the
initial GitHub Pages Actions configuration.

The headless browser smoke injects a synthetic hidden `Document` state and
dispatches the browser's `visibilitychange` event to exercise the suspension
path. It does not claim to validate operating-system tab switching behavior.

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
