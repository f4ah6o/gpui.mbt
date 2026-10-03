# Browser development toolchain: Vite+ and MoonBit plugin

Status: open
Parent: [0009-browser-backend.md](0009-browser-backend.md)
Updated: 2026-10-04

## Goal

Replace the hand-written browser development/build loop with a reproducible
Vite+-based toolchain while keeping gpui.mbt itself MoonBit-first and keeping
browser/runtime dependencies outside portable framework packages.

The standard browser development entry point becomes `vp` (Vite+), with
`vite-plugin-moonbit` providing MoonBit/Vite integration.

This packet changes development and packaging infrastructure only. It must not
change gpui.mbt application semantics, SceneSnapshot contracts, the platform
boundary, or the requirement that application code remain independent of the
browser host.

## Toolchain decision

Use:

- Vite+ with the `vp` CLI as the browser development/build entry point
- `vite-plugin-moonbit` for MoonBit module resolution and browser build/watch
- Vite-compatible configuration/plugins through the Vite+ compatibility layer
- Playwright only for black-box browser smoke/E2E evidence
- the repository-pinned MoonBit toolchain for MoonBit compilation

Do not introduce a JavaScript UI framework. Vite+ is development/build
infrastructure, not an application runtime abstraction.

The existing `scripts/build_browser_demo.sh` + copied static-site flow is
transitional. Keep it working until the Vite+ path has equivalent build and
smoke evidence, then remove the redundant path instead of maintaining two
first-class browser toolchains.

## Why Vite+

Vite+ provides one project-local/global `vp` entry point for the browser
workflow, including dependency installation, development server, production
builds, checks, and CI setup. The browser work should therefore converge on:

```text
vp install
vp dev
vp check
vp build
```

Repository-specific tasks that are not Vite+ built-ins may use `vp run <task>`.

The configuration must retain Vite plugin compatibility so
`vite-plugin-moonbit` and other narrowly justified Vite integrations resolve
against the Vite implementation bundled by Vite+ rather than a second,
independent Vite installation.

## MoonBit plugin

Adopt `mizchi/vite-plugin-moonbit` as the default MoonBit/Vite bridge unless a
repository-owned replacement is later required by a concrete compatibility or
maintenance problem.

Required capabilities for this repository:

- `mbt:` import resolution where useful for the browser host
- `moon build --watch` integration during development
- HMR/reload behavior that does not bypass gpui.mbt lifecycle teardown
- JavaScript target support
- WasmGC support when packet 0009 reaches that target
- source maps that preserve useful `.mbt` debugging in browser developer tools
- MoonBit workspace/package resolution without application-specific generated
  path hacks

The plugin is tooling only. Portable MoonBit packages must not depend on its
JavaScript API.

## Target shape

Prefer one browser workspace at the repository root or under a clearly named
browser tooling directory. Avoid a separate package-manager island for every
browser test/demo unless isolation is required.

The expected structure is approximately:

```text
package.json
vite.config.ts
examples/browser/
  site/
tests/browser/
```

The exact placement may differ if the migration proves a cleaner layout, but
there must be one documented `vp` workflow for normal development and CI.

The Vite config should:

- use the MoonBit plugin for the selected target
- keep the existing browser host/page as the app shell initially
- emit a deterministic static artifact suitable for GitHub Pages
- use a repository-relative base path that works in local dev and Pages
- avoid leaking generated MoonBit paths into application-facing imports
- make the production output directory explicit
- keep browser backend code below the platform boundary

## Development flow

The desired local workflow is:

1. install/resolve the Vite+ toolchain with `vp install`
2. run `vp dev`
3. edit MoonBit or browser-host sources
4. let the MoonBit plugin rebuild/watch and let Vite refresh the page/module
5. use browser developer tools with MoonBit source maps where available
6. run `vp build` for the production artifact
7. run browser smoke/E2E against the production-equivalent output

The development server must not become a correctness dependency. CI and release
evidence must run against a production build.

## CI migration

Replace the standalone Node/npm setup for browser tooling with the official
Vite+ setup flow once the project-local configuration is committed.

Requirements:

- pin the Vite+ project version
- pin the GitHub Action by an exact release or commit SHA
- use the Node version required by the selected Vite+ release
- install dependencies through `vp install`
- run the production browser build through `vp build`
- install the Playwright browser needed by the existing smoke suite
- run the real Chromium smoke against the Vite+ production artifact
- upload the same verified artifact to GitHub Pages
- retain current MoonBit all-target check/test coverage

Do not claim the migration complete from a dev-server smoke alone.

## Dependency policy

Pin the browser toolchain sufficiently for reproducible CI.

Vite+ and its Vite compatibility alias must stay on matching releases according
to the Vite+ migration guidance. Avoid installing an unrelated second copy of
Vite merely to satisfy a plugin peer dependency.

Keep Playwright test-only.

The MoonBit plugin is an allowed browser-development dependency. This is an
exception to the framework's normal preference for MoonBit standard/core-only
runtime dependencies because it does not enter gpui.mbt runtime or portable
packages.

## Migration steps

### A. Introduce Vite+ project configuration

- add project-local Vite+ metadata/configuration
- pin Vite+ and the compatible Vite alias
- add `vite-plugin-moonbit`
- preserve the existing browser host as the first entry
- document `vp install/dev/build/check`

### B. Route MoonBit output through the plugin

- remove manual generated-JS copying from the primary path
- prove JS target imports and source maps
- preserve explicit MoonBit target selection
- verify clean checkout development startup

### C. Move browser smoke to Vite+ artifact

- build the production bundle with `vp build`
- serve/preview the resulting artifact in a deterministic way
- run existing Chromium assertions unchanged where possible
- retain failure screenshot/status artifacts

### D. Migrate CI and Pages packaging

- use the pinned Vite+ setup action
- remove redundant Node/npm setup that Vite+ owns
- upload the Vite+ production output
- keep deploy gating equivalent to the current workflow

### E. Remove the transitional static builder

Only after A-D are green:

- remove or reduce `scripts/build_browser_demo.sh`
- remove duplicate copy/serve instructions
- update `docs/browser-demo.md`
- update packet 0009 evidence notes

## Acceptance

This packet is complete when all of the following hold:

- `vp install` succeeds from a clean checkout
- `vp dev` starts the browser demo and MoonBit edits are rebuilt through the
  MoonBit plugin
- `vp build` produces the deployable static artifact
- `vite-plugin-moonbit` is the active MoonBit/Vite integration rather than a
  documented-but-unused dependency
- the JavaScript browser proof still renders and handles input/resize/teardown
- the existing real Chromium smoke passes against the production build
- browser developer tools can map generated JavaScript back to useful MoonBit
  sources where the compiler/plugin provide maps
- GitHub Pages deploys the same artifact that passed smoke
- MoonBit all-target checks/tests remain green
- portable gpui.mbt packages have no Vite/Vite+/Node dependency
- the old manual copy-based build path is removed or explicitly demoted to a
  diagnostic fallback, not maintained as a second normal workflow

## Follow-up

Packet 0009 remains responsible for browser backend functionality: WasmGC/Wasm
parity, WebGPU, input/text/IME, accessibility, capabilities, renderer recovery,
and production support. This packet only standardizes the browser development,
build, and CI toolchain used to deliver that work.
