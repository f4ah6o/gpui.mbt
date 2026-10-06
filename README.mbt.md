# gpui.mbt

Build GPUI-style user interfaces in MoonBit.

`gpui.mbt` gives MoonBit programs a deterministic application/entity model, flex layout and element trees, input routing, scene snapshots, and experimental native/browser hosts. Portable UI state, layout, events, and scene data stay in MoonBit; native backends call platform APIs directly and do not carry a Rust GPUI runtime.

## What you can use today

- **Application state** — `App`, typed `Entity[T]`, scoped updates, subscriptions, explicit notifications, deterministic queued work, and manually advanced timers.
- **Layout and interaction** — deterministic row/column flex layout, recursive layout trees, hit testing, capture/bubble pointer dispatch, stop-propagation, focus state, and portable [scroll state](element/scroll.mbt) and [drag gestures](element/drag.mbt).
- **Scene data** — ordered quads and bounded plain-text items, rectangle clip chains, affine transforms, opacity, and canonical `SceneSnapshot` data. The browser uses its system font; the experimental Ubuntu and macOS renderers draw documented grayscale subsets. Windows still rejects text items explicitly.
- **Linux text** — merged [PR #27](https://github.com/f4ah6o/gpui.mbt/pull/27) provides copied PangoFT2 measurement, caret, and hit-test geometry; Ubuntu's GLES host now also presents supported plain-text items through grayscale masks. This is not text input, an editor, or a general Linux support claim; see the [Linux text guide](docs/linux-text.md).
- **macOS text field** — an experimental single-line CoreText field uses the shared selection, editing, scrolling, clipboard, undo/redo, and rollback model. AppKit supplies committed text by default; per-window Japanese composition is opt-in with `GPUI_FIELD_MACOS_IME=1`. See the [macOS text guide](docs/macos-native.md#experimental-single-line-text-field).
- **Semantic capabilities** — one typed operation can be bound to GUI actions, direct MoonBit calls, and optional MCP dispatch with shared domain validation. A checked JavaScript stdio fixture exercises the pinned stateless MCP wire adapter.
- **macOS** — an AppKit + Metal native host with windows, input, clipboard/cursors, scale/resize events, quad and bounded grayscale text presentation, and an experimental renderer-recovery path.
- **Ubuntu / Wayland** — a Wayland + EGL/OpenGL ES 2 native host with window lifecycle, input, clipboard/cursor services, scale handling, quad presentation, and bounded grayscale text frames.
- **Windows** — an experimental one-window Win32/D3D11 hardware-or-WARP slice with basic input and quad presentation. For prior HEAD `0f7bdfd`, the hosted [Windows Server 2025/MSVC run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37189793257) passed portable checks (6/6), native GPU E2E (1/1), shared backend conformance (1/1), and the example smoke. This is evidence for the experimental slice, not a Windows support-tier or production claim; see the [Windows native guide](docs/windows-native.md).
- **Browser** — Weekboard, a small website-launch task board using the shared MoonBit app/layout/event/scene model and a Canvas 2D host, plus the retained interaction lab for service and lifecycle proofs.
- **Headless testing** — portable model, layout, event, focus, and scene behavior can be exercised without a window system.

The native and browser hosts are development slices rather than production support. See [status, limits, and roadmap](docs/status.md) for the current boundary.

## Try it

### Headless MoonBit model

```sh
moon test examples/headless
```

The example in [`examples/headless/example.mbt`](examples/headless/example.mbt) updates an entity and notifies its subscribers through the framework-owned update path.

### macOS

On macOS 13+ with Xcode command-line tools:

```sh
./script/build_and_run.sh
```

The default demo opens an AppKit window and renders with Metal. Click the quad or press Space to change it. Run `./script/build_and_run.sh --demo text-field` for the bounded single-line field. See [the macOS guide](docs/macos-native.md) for build, test, and actrun acceptance commands.

### Ubuntu / Wayland

After installing the system packages listed in [the Ubuntu guide](docs/ubuntu.md), including PangoFT2 and Fontconfig development packages for the native text renderer:

```sh
sh scripts/prepare_ubuntu.sh
moon run examples/ubuntu --target native
```

The demo opens a Wayland window and presents the shared scene model through EGL/OpenGL ES 2.

### Headless Linux text geometry

Install the native development libraries and fixture fonts listed in the [Linux text guide](docs/linux-text.md), then run:

```sh
sh scripts/test_linux_text.sh
```

This is a separate headless test from the Wayland window/backend smoke. It covers measurement and the private grayscale-mask raster oracle, not GPU text-frame presentation.

### Browser

With Vite+ and a supported Node.js release available:

```sh
vp install --frozen-lockfile
vp dev
```

Open the URL printed by Vite+ to use **Weekboard**: 12 initial tasks across Backlog, In progress, and Done. Search, add tasks, move cards between lanes by drag or buttons, undo changes, and scroll each lane. Narrow viewports show one lane with lane selectors and scroll buttons. Data stays in the current page session; reloading starts again with the sample tasks.

The board's state, filtering, history, layout, hit testing, scrolling, drag gestures, and scene data live in [the portable task-board package](examples/task_board/). The browser hosts the canvas, ordinary HTML search/add controls, and visible-card focus proxies. This is bounded text presentation and a demo-specific accessibility projection, not a complete text editor or general accessibility adapter.

The original interaction lab remains at **`/proof.html`**, linked from Weekboard. It retains the GUI/direct/MCP counter, clipboard, committed-input, legacy-island, and renderer-restoration proofs. Use `vp build` for both pages in `_build/browser-site`. See [the browser guide](docs/browser-demo.md) for limits and separate test commands.

### MCP stdio adapter

Run the compiled MoonBit reference server and its endpoint/drift checks with:

```sh
sh scripts/run_mcp_stdio.sh
sh scripts/test_mcp_stdio.sh
```

See [the MCP adapter guide](docs/mcp-adapter.md) for the supported wire surface and lifecycle limits.

## MoonBit programming model

The headless API can be used independently of a native window backend. This is the same entity update used by the checked example:

```mbt nocheck
pub fn increment(
  app : @core.App,
  entity : @core.Entity[Int],
) -> Result[Unit, @diagnostics.FrameworkError] {
  app.update(entity, context => {
    match context.get() {
      Err(error) => Err(error)
      Ok(value) =>
        match context.set(value + 1) {
          Err(error) => Err(error)
          Ok(_) => context.notify()
        }
    }
  })
}
```

Subscriptions are explicitly canceled with `unsubscribe`. Deterministic timer tests use `App::advance_time_by`. Generic entity payloads should use immutable or copy-on-write values; the ownership caveat is documented in [status and limits](docs/status.md).

## Packages

| Package | What it provides |
| --- | --- |
| `core/` | Application lifetime, entities, scoped contexts, subscriptions, scheduler and timers |
| `primitives/` | Shared geometry, colors, input values, and portable primitives |
| `text/` | UTF-16 documents, strict UTF-8 scalar-offset conversion, directional selections, and immutable composition values; no host IME or rendering |
| `text_layout/` | Portable intrinsic text-measurement contract and copied layout/caret/hit values; depends only on `text/` and `primitives/` |
| `platform/linux_text/` | Linux-only PangoFT2 implementation of copied measurement geometry and a private grayscale-mask raster boundary; native handles stay behind the FFI boundary |
| `layout/` | Deterministic flex layout and recursive layout trees |
| `element/` | Element trees, hit testing, event routing, focus, scroll state, drag gestures, and element-to-scene bridging |
| `scene/` | Quad paint commands, bounded text snapshot items, validation, canonical snapshots, transforms, opacity, and clips |
| `platform/` | Portable backend/window/event contracts plus the macOS backend |
| `ubuntu/` | Ubuntu Wayland/EGL/GLES2 native backend |
| `windows/` | Experimental Win32/D3D11 WARP backend slice |
| `capability/` | Typed semantic capabilities, validation, schema projection, and registry |
| `mcp/` | Optional modern MCP inventory, schema projection, stateless wire router, and in-process dispatch adapter |
| `migration/host_services/` | Bounded portable service requests/completions and default-deny host-service policy |
| `examples/` | Headless, macOS, Ubuntu, Windows, browser, and MCP stdio fixtures |

## Documentation

- [Status, current limits, and roadmap](docs/status.md)
- [Product model](docs/product.md)
- [Architecture and dependency boundaries](docs/architecture.md)
- [Portable text value model](docs/text-model.md)
- [Linux text measurement and Ubuntu grayscale drawing](docs/linux-text.md)
- [GPUI compatibility matrix](docs/compatibility.md)
- [macOS native host](docs/macos-native.md)
- [Ubuntu / Wayland host](docs/ubuntu.md)
- [Reproducible Debian cloud desktop](infra/linux-desktop/README.md)
- [Browser demos and interaction lab](docs/browser-demo.md)
- [MCP adapter and stdio fixture](docs/mcp-adapter.md)
- [Testing strategy and gates](docs/testing.md)
- [Open implementation packets](issues/open/)

## Relationship to GPUI

`gpui.mbt` is an independent MoonBit implementation of GPUI-style programming concepts. GPUI is developed by Zed Industries; this project is not affiliated with or endorsed by Zed Industries. Compatibility is behavioral and conceptual rather than Rust source or binary compatibility. The pinned comparison target and source-provenance rules are documented in [compatibility](docs/compatibility.md) and [provenance](docs/provenance.md).
