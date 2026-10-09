# Native UI integration contract

Both repositories implement this bounded contract together. Existing Web APIs,
HTML output and CSS remain compatible.

- Yami-kumo adds an independent `native/` MoonBit module named
  `f4ah6o/yami_kumo_native`; the root Web module gains no gpui dependency.
  It reuses the root public ButtonVariant, TextVariant and ControlSize enums.
- Theme colors and sizes derive from the checked-in pinned Kumo 2.14.0 styles.
  Light/dark byte-RGBA values document OKLCH conversion and the bounded visual
  subset (plain system text and quads; no gradient, radius or font-weight claim).
- Component lowering uses existing gpui Element/Flex tree layout, stable
  caller-owned UInt64 IDs, ElementTree focus/hit testing and SceneSnapshot v1.
  Text and Button are required; Card and the semantic AppShell use the same
  portable layout where available. No OS code enters component packages.
- Intrinsic measurement is injected as
  `(String, Double) -> Result[@text_layout.TextMeasurement, @diagnostics.FrameworkError]`.
  OS entrypoints adapt existing Linux/Windows providers and a new macOS
  provider. Measurement and rendering must use the same fixed system-sans face
  (Linux sans, Windows Segoe UI, macOS documented system face) and logical size.
- TextRunItem.text_origin is the layout origin, not the baseline. Components
  use the union of measured ink/logical extents when sizing and placing runs,
  translating negative minima so measured ink fits the item bounds. Bounds
  retain item-local clipping. Existing scene schema and public text semantics
  remain unchanged; unsupported features return errors rather than dropping.
- State and behavior stay in MoonBit. ElementTree dispatch, explicit focus and
  matching primary press/release activate a Button once; disabled, canceled,
  focus-loss and resize-invalid gestures cannot activate. Application actions
  update App/Entity through Context.set/notify and regenerate the common view.
- A shared sample/controller renders labeled Button and Text and increments
  state on click using the same component/state/layout/event code on all OSes.
  Host startup, measurement and Backend event/presentation adapter selection
  are small platform entrypoints in the native module.
- gpui owns all OS FFI and native host/rendering behavior. macOS gains the
  display-only measurement/rendering seam; this contract adds no Input/IME.
  Input editing, focus ownership and IME qualification are assessed per OS and
  documented as an independent later stage.
- Headless component/state/layout/event tests, native builds, actual native
  frame/readback and host-delivered click evidence are reported separately.
  Linux/Windows hosted native CI and local macOS native execution are used.
  A build, direct model event, or historical run cannot prove new native UI.
- gpui PR merges first after final-commit review and required CI. Yami PR then
  pins the merged gpui revision in its native build/CI recipe and is reviewed
  on its final commit before merge. Root Web checks remain independently runnable.

## GPUI native E2E evidence seam

- `f4ah6o/gpui/platform/testing` exposes `capture_frame(host, window)` as an
  owned top-left RGBA8 copy of the last completed native GPU frame, with
  dimensions and scale. Capture requires `GPUI_NATIVE_E2E=1`, validates the
  dimensions and allocation budget before copying, and can write a P6 PPM file
  for CI artifacts. It never synthesizes a scene or reads Yami model state.
- The macOS host additionally exposes window-scoped test click and Escape
  methods. They require `GPUI_NATIVE_E2E=1` and a `--test-hooks` dylib, validate
  the owned window and click bounds, and send NSEvents through its normal
  `NSWindow` path into the application event loop. This is synthetic host-event
  delivery evidence, not physical hardware input. Linux and Windows continue
  to use their OS-level CI input drivers.
