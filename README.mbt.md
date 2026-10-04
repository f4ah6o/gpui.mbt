# gpui.mbt

Build GPUI-style user interfaces in MoonBit.

`gpui.mbt` gives MoonBit programs a deterministic application/entity model, flex layout and element trees, input routing, scene snapshots, and experimental native/browser hosts. Portable UI state, layout, events, and scene data stay in MoonBit; native backends call platform APIs directly and do not carry a Rust GPUI runtime.

## What you can use today

- **Application state** — `App`, typed `Entity[T]`, scoped updates, subscriptions, explicit notifications, deterministic queued work, and manually advanced timers.
- **Layout and interaction** — deterministic row/column flex layout, recursive layout trees, hit testing, capture/bubble pointer dispatch, stop-propagation, and focus state.
- **Scene data** — ordered quads, rectangle clip chains, affine transforms, opacity, and canonical `SceneSnapshot` data.
- **Semantic capabilities** — one typed operation can be bound to GUI actions, direct MoonBit calls, and optional in-process MCP dispatch with shared domain validation.
- **macOS** — an AppKit + Metal native host with windows, input, clipboard/cursors, scale/resize events, quad presentation, and an experimental renderer-recovery path.
- **Ubuntu / Wayland** — a Wayland + EGL/OpenGL ES 2 native host with window lifecycle, input, clipboard/cursor services, scale handling, and quad presentation.
- **Windows** — an experimental one-window Win32/D3D11 hardware-or-WARP slice with basic input and quad presentation; the hosted workflow still needs a successful run.
- **Browser** — a JavaScript-target proof using the same MoonBit app/layout/event/scene model and a Canvas 2D host.
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

The demo opens an AppKit window and renders with Metal. Click the quad or press Space to change it. See [the macOS guide](docs/macos-native.md) for build, smoke, and native-test commands.

### Ubuntu / Wayland

After installing the system packages listed in [the Ubuntu guide](docs/ubuntu.md):

```sh
sh scripts/prepare_ubuntu.sh
moon run examples/ubuntu --target native
```

The demo opens a Wayland window and presents the shared scene model through EGL/OpenGL ES 2.

### Browser

With Vite+ and a supported Node.js release available:

```sh
vp install --frozen-lockfile
vp dev
```

Open the URL printed by Vite+. The browser proof uses the shared MoonBit app, flex-tree layout, element hit testing/focus, event ingress, and `SceneSnapshot` data. Use `vp build` for the production artifact in `_build/browser-site`. See [the browser guide](docs/browser-demo.md).

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
| `layout/` | Deterministic flex layout and recursive layout trees |
| `element/` | Element trees, hit testing, event routing, focus, and element-to-scene bridging |
| `scene/` | Paint commands, validation, canonical snapshots, transforms, opacity, and clips |
| `platform/` | Portable backend/window/event contracts plus the macOS backend |
| `ubuntu/` | Ubuntu Wayland/EGL/GLES2 native backend |
| `windows/` | Experimental Win32/D3D11 WARP backend slice |
| `capability/` | Typed semantic capabilities, validation, schema projection, and registry |
| `mcp/` | Optional transport-neutral inventory and in-process MCP dispatch adapter |
| `migration/host_services/` | Bounded portable service requests/completions and default-deny host-service policy |
| `examples/` | Headless, macOS, Ubuntu, Windows, and browser programs |

## Documentation

- [Status, current limits, and roadmap](docs/status.md)
- [Product model](docs/product.md)
- [Architecture and dependency boundaries](docs/architecture.md)
- [GPUI compatibility matrix](docs/compatibility.md)
- [macOS native host](docs/macos-native.md)
- [Ubuntu / Wayland host](docs/ubuntu.md)
- [Browser proof](docs/browser-demo.md)
- [Testing strategy and gates](docs/testing.md)
- [Open implementation packets](issues/open/)

## Relationship to GPUI

`gpui.mbt` is an independent MoonBit implementation of GPUI-style programming concepts. GPUI is developed by Zed Industries; this project is not affiliated with or endorsed by Zed Industries. Compatibility is behavioral and conceptual rather than Rust source or binary compatibility. The pinned comparison target and source-provenance rules are documented in [compatibility](docs/compatibility.md) and [provenance](docs/provenance.md).
