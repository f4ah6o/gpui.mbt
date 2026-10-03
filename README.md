# gpui.mbt

gpui.mbt is an independent MoonBit implementation of the GPUI programming model. GPUI is developed by Zed Industries. This project is not affiliated with or endorsed by Zed Industries.

The project aims to let a MoonBit desktop application use GPUI-like concepts without carrying a Rust GPUI runtime or another application framework. It now contains an M1 headless core runtime, plus a first Ubuntu/Wayland native window and quad-rendering slice, but no production release or supported native platform. Compatibility is behavioral and conceptual; Rust source and binary compatibility are out of scope.

## Current state

M0 contracts define the App/Entity/Context model, architecture, dependency rules, and compatibility baseline. M1 implements logical IDs, app/entity/context lifetimes, subscriptions, structured errors, and a deterministic scheduler with headless tests. M2 now includes the platform-neutral deterministic flex-line layout foundation plus a flat pre-order element tree with hit testing, capture/bubble routing metadata, focus state, and deterministic headless background-quad scene generation. Render/IntoElement lifecycle semantics and recursive auto layout remain pending. Callback dispatch now supports deterministic capture/bubble execution with stop-propagation; immutable subtree removal normalizes focus, and seeded event/focus properties exercise those invariants. The scene layer validates strict clip nesting before emitting deterministic scene data. The provisional canonical `CommandSnapshot` remains available, and a versioned `SceneSnapshot` v1 subset now exposes viewport/scale, resource and rectangle clip-chain tables, ordered quad items, affine transforms, opacity, and canonical serialization. The full v1 content model and richer scene primitives remain pending. Compatibility rows remain `planned` until behavior has been compared with the pinned GPUI revision; implementation is not a global compatibility claim.

- [Product and core behavior contract](docs/product.md)
- [Architecture and dependency contract](docs/architecture.md)
- [GPUI concept compatibility matrix](docs/compatibility.md)
- [Open implementation packets](issues/open/)
- [Ubuntu Wayland native app, setup and evidence](docs/ubuntu.md)
- [JavaScript browser proof of concept](docs/browser-demo.md)

M1 generic entity payloads use an immutable or copy-on-write discipline. MoonBit cannot deeply copy arbitrary `T`, so retaining a mutable alias and changing it outside `App::update` can bypass revision and notification tracking. The core API does not claim to prevent this. M1 also has no windows, rendering, background executor, IME, accessibility adapter, or native platform backend.

No user application should depend on this repository for production use yet.

## Headless core example

The M1 example uses an entity update and explicit notification, then drains the app queue before checking the listener. Its implementation is in [examples/headless/example.mbt](examples/headless/example.mbt), and the separate API test is in [examples/headless/example_test.mbt](examples/headless/example_test.mbt). Run it with `moon test examples/headless`.

```moonbit
pub fn increment(
  app : @core.App,
  entity : @core.Entity[Int],
) -> Result[Unit, @diagnostics.FrameworkError] {
  app.update(entity, context =>
    match context.get() {
      Err(error) => Err(error)
      Ok(value) =>
        match context.set(value + 1) {
          Err(error) => Err(error)
          Ok(_) => context.notify()
        }
    })
}
```

Subscriptions are explicitly canceled with `unsubscribe`; deterministic tests advance timers with `App::advance_time_by`. Generic entity values should be immutable or copy-on-write, as described in the [product contract](docs/product.md#entity-identity-and-lifetime).

## Platform support

The support tiers are evidence-based:

- **Tier 0 — builds:** the project compiles for that target. This is build evidence only.
- **Tier 2 — experimental:** usable for development but missing one or more Tier 1 gates.
- **Tier 1 — production supported:** native E2E, IME and accessibility baselines, multi-DPI, renderer recovery, release performance budgets, and sustained-run resource checks all pass.

The MoonBit core packages compile and test on the configured local targets, and the first Ubuntu/Wayland backend has local Debian/Weston native build and E2E evidence. Its pinned Ubuntu CI workflow has not yet been observed; real Ubuntu desktop, IME/accessibility and production gates remain pending. Therefore no platform is assigned Tier 0, Tier 2, or Tier 1. macOS, Windows, and Linux remain unsupported until each passes the applicable gates.

| Platform | Status | Evidence |
|---|---|---|
| JavaScript browser | Proof of concept; unsupported | Canvas 2D `SceneSnapshot` v1 slice, shared MoonBit app/layout/event model, and real-Chromium smoke workflow; WebGPU and browser production gates remain open. |
| macOS | Planned; unsupported | Core-only MoonBit checks; no native backend or E2E evidence. |
| Windows | Planned; unsupported | Core-only MoonBit checks; no native backend or E2E evidence. |
| Ubuntu / Wayland | First native slice; unsupported | Local Debian 13/Weston 14 native window, GPU readback and lifecycle E2E; Ubuntu 24.04 CI configured, real desktop gates pending. |
| X11 / XWayland | Unimplemented; unsupported | No build or E2E evidence. |

## Milestones

| Milestone | Scope | State |
|---|---|---|
| M0 — contracts | Product model, compatibility format, dependency policy, test strategy, platform boundary, release gates | Delivered; machine-readable checks are available. |
| M1 — deterministic core | IDs, App/Entity/Context, subscriptions, deterministic scheduler, headless lifecycle tests | Implemented; covered by the current all-target headless suite on wasm, wasm-gc, js, and native. |
| M2 — element system | Render/IntoElement/Element, layout, hit testing, event dispatch, focus, headless scenes | In progress; deterministic flex-line and recursive flex-tree layout, seeded layout properties, flat element trees, hit testing, capture/bubble callback dispatch with stop-propagation, subtree-removal focus normalization, seeded event/focus properties, and background-quad headless scenes are implemented. Render/IntoElement lifecycle and recursive auto container sizing remain pending. |
| M3 — rendering core | Stable scene data, primitives, text runs, renderer abstraction, headless snapshots | In progress; ordered quad/rectangle-clip commands, the provisional canonical `CommandSnapshot`, and a versioned `SceneSnapshot` v1 subset with resource/clip-chain/item tables, affine transforms, opacity, and canonical serialization are implemented. Full v1 quad border/corner data, path clips, paths/images/text runs and resources, and full renderer contracts remain pending; the shared Backend contract and Ubuntu GLES quad subset now have an initial native implementation. |
| M4 — first native platform | Window lifecycle, input, clipboard, timers, text input/IME baseline, GPU surface, diagnostics | In progress; the Ubuntu Wayland host/window/GLES quad slice is implemented. Full native services and the planned macOS backend remain pending. |
| M5 — text and interaction completeness | Shaping/fallback, accessibility, IME correctness, menus/cursors, high-DPI/multi-display | Planned. |
| M6 — multi-platform | Tier definitions and Tier 1 gates for macOS, Windows, and Linux | Planned. |
| M7 — production-ready 1.0 | Release gates, current compatibility evidence, and sustained use by a non-demo app | Planned. |

M7 is not a promise to implement every upstream GPUI feature. It requires a stable documented API, supported-platform matrix, no release-blocking correctness issues, reproducible tests/releases, performance and accessibility evidence, diagnostics, and an audited provenance/dependency boundary.

## Validation

The repository contains the M0 design contracts, M1 MoonBit core, the M2 layout/element foundations, and the first M3 headless scene command package. Run the contract and dependency checks with:

```sh
python3 scripts/check_contracts.py
# Install native system packages as documented in docs/ubuntu.md, then:
sh scripts/prepare_ubuntu.sh
moon check --deny-warn
moon test
```

The experimental JavaScript browser proof has its own static build and
real-Chromium smoke workflow. See [the browser proof guide](docs/browser-demo.md)
for local steps and its current capability limits.

Formatting can be checked with:

```sh
moon fmt --check
```

The checks establish contract structure, package boundaries, formatting, compilation, and package tests. All tests are expected to pass on wasm, wasm-gc, js, and native; those headless results do not establish native desktop platform support. Broader property/mutation tests, visual artifacts, and native E2E gates are defined in the [production and test issue packets](issues/open/).

## Upstream reference and independence

The compatibility target is GPUI at the immutable revision [`zed-industries/zed@d9afb21688e04f89d9e94d96d33eb530aef90886`](https://github.com/zed-industries/zed/tree/d9afb21688e04f89d9e94d96d33eb530aef90886). The upstream GPUI crate manifest identifies Apache-2.0 for that crate. This does not make all source in the Zed repository Apache-2.0; verify the exact file context before any source adaptation. This project does not port Zed application-specific UI code or depend on Zed GPL components. M0 documentation and M1 core behavior are written independently from the pinned comparison target; no upstream implementation code is copied.

## macOS native demo

On macOS with Xcode command-line tools, run `./script/build_and_run.sh` to open
the MoonBit/AppKit/Metal quad demo. `./script/test_macos.sh` runs native GPU,
input, and lifecycle checks. See [the native slice guide](docs/macos-native.md)
for build, ABI, CI evidence, and remaining production gates.
