///|
fn rect(w : Double, h : Double) -> @primitives.Rect {
  match @primitives.Rect::new(0.0, 0.0, w, h) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
}

///|
fn snapshot(w : Double, h : Double, scale : Double) -> @scene.SceneSnapshot {
  let viewport = rect(w, h)
  let color = match @primitives.Color::rgba(255, 0, 0, 255) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let scene = @scene.Scene::new([@scene.PaintCommand::quad(1, viewport, color)])
  match scene.snapshot_v1(viewport, scale) {
    Ok(s) => s
    Err(_) => abort("fixture")
  }
}

///|
fn mixed_snapshot(
  w : Double,
  h : Double,
  scale : Double,
) -> @scene.SceneSnapshot {
  let viewport = rect(w, h)
  let red = match @primitives.Color::rgba(220, 20, 30, 255) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let blue = match @primitives.Color::rgba(20, 70, 240, 255) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let green = match @primitives.Color::rgba(20, 220, 60, 255) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let shifted = match
    @scene.AffineTransform::new(1.0, 0.0, 0.0, 1.0, 7.25, 4.5) {
    Ok(t) => t
    Err(_) => abort("fixture")
  }
  let backdrop = match
    @scene.SceneItem::quad(
      1,
      viewport,
      red,
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let clipped_text = match @primitives.Rect::new(8.25, 9.5, 58.5, 31.25) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let text = match
    @scene.SceneItem::text(
      2,
      clipped_text,
      "Grayscale text 日本語",
      19.0,
      blue,
      shifted,
      0.65,
      Some(7),
    ) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let overlay = match @primitives.Rect::new(32.0, 26.0, 12.0, 9.0) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let after_text = match
    @scene.SceneItem::quad(
      3,
      overlay,
      green,
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let clip = match @primitives.Rect::new(10.5, 11.25, w - 18.75, h - 20.5) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  match
    @scene.SceneSnapshot::new(
      viewport,
      scale,
      [],
      [@scene.ClipChain::new(7, [viewport, clip])],
      [backdrop, text, after_text],
    ) {
    Ok(s) => s
    Err(_) => abort("mixed scene fixture")
  }
}

///|
test "unsupported session is typed and failed start permits retry" {
  let previous = @env.get_env_var("XDG_SESSION_TYPE")
  @env.set_env_var("XDG_SESSION_TYPE", "x11")
  for _i = 0; _i < 2; _i = _i + 1 {
    match Host::start() {
      Ok(host) => {
        ignore(host.stop())
        fail("X11 must not initialize Wayland")
      }
      Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    }
  }
  match previous {
    Some(value) => @env.set_env_var("XDG_SESSION_TYPE", value)
    None => @env.unset_env_var("XDG_SESSION_TYPE")
  }
}

///|
test "input translation retains logical pointer, scroll, focus and modifiers" {
  let buffer = FixedArray::make(10, 0.0)
  buffer[0] = 8.0
  buffer[6] = 12.5
  buffer[7] = 8.25
  buffer[9] = 3.0
  match decode_event(buffer) {
    Some(
      @platform.Input(
        @primitives.PointerButtonPressed(position~, button~, modifiers~)
      )
    ) => {
      assert_eq(position.x(), 12.5)
      assert_eq(position.y(), 8.25)
      assert_true(button == @primitives.Primary)
      assert_true(modifiers.shift() && modifiers.control() && !modifiers.alt())
    }
    _ => fail("pointer translation")
  }
  buffer[0] = 10.0
  buffer[4] = -4.5
  buffer[8] = 1.0
  match decode_event(buffer) {
    Some(@platform.Input(@primitives.Scroll(position~, delta~, ..))) => {
      assert_eq(position.x(), 12.5)
      assert_eq(position.y(), 8.25)
      assert_eq(delta.x(), -4.5)
      assert_eq(delta.y(), 0.0)
    }
    _ => fail("scroll translation")
  }
  buffer[0] = 11.0
  buffer[8] = 0xff0d
  assert_true(
    decode_event(buffer)
    is Some(@platform.Input(@primitives.KeyPressed(key=@primitives.Enter, ..))),
  )
  buffer[0] = 6.0
  buffer[8] = 0.0
  assert_true(decode_event(buffer) is Some(@platform.FocusChanged(false)))
}

///|
test "renderer preserves v1 clip intersection and rejects resource tables" {
  let viewport = rect(100.0, 100.0)
  let color = match @primitives.Color::rgba(10, 20, 30, 128) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let transform = match
    @scene.AffineTransform::new(0.0, 1.0, -1.0, 0.0, 50.0, 5.0) {
    Ok(t) => t
    Err(_) => abort("fixture")
  }
  let item = match
    @scene.SceneItem::quad(1, viewport, color, transform, 0.5, Some(7)) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let clip = match @primitives.Rect::new(10.0, 20.0, 30.0, 40.0) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let s = match
    @scene.SceneSnapshot::new(
      viewport,
      2.0,
      [],
      [@scene.ClipChain::new(7, [viewport, clip])],
      [item],
    ) {
    Ok(s) => s
    Err(_) => abort("fixture")
  }
  match frame_data(s) {
    Err(_) => fail("supported scene")
    Ok(data) => {
      assert_eq(data.length(), 24)
      assert_eq(data[4], 2.0)
      assert_eq(data[13], 0.0)
      assert_eq(data[14], 1.0)
      assert_eq(data[19], 0.5)
      assert_eq(data[20], 10.0)
      assert_eq(data[21], 20.0)
      assert_eq(data[22], 30.0)
      assert_eq(data[23], 40.0)
    }
  }
  let unsupported = match
    @scene.SceneSnapshot::new(
      viewport,
      1.0,
      [@scene.SceneResource::new(1)],
      [],
      [],
    ) {
    Ok(s) => s
    Err(_) => abort("fixture")
  }
  match frame_data(unsupported) {
    Err(e) => assert_eq(e.code().label(), "unsupported_capability")
    Ok(_) => fail("resources not implemented")
  }
  let text = @scene.TextItem(
    id=2,
    bounds=viewport,
    text="Browser text",
    font_size=16.0,
    color~,
    transform~,
    opacity=1.0,
    clip_chain_id=None,
  )
  let text_scene = match
    @scene.SceneSnapshot::new(
      viewport,
      1.0,
      [],
      [@scene.ClipChain::new(7, [viewport])],
      [item, text],
    ) {
    Ok(value) => value
    Err(_) => abort("text fixture rejected")
  }
  match frame_data(text_scene) {
    Err(e) => assert_eq(e.code().label(), "unsupported_capability")
    Ok(_) => fail("bounded text must not silently render as a native quad")
  }
}

///|
test "mixed v2 serializer preserves order, UTF-8 spans and v1 rejection" {
  let viewport = rect(100.0, 80.0)
  let clip = match @primitives.Rect::new(5.0, 7.0, 40.0, 30.0) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let red = match @primitives.Color::rgba(240, 10, 20, 200) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let cyan = match @primitives.Color::rgba(10, 180, 220, 240) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let transform = match
    @scene.AffineTransform::new(0.9, 0.2, -0.15, 1.1, 3.25, 4.5) {
    Ok(t) => t
    Err(_) => abort("fixture")
  }
  let backdrop = match
    @scene.SceneItem::quad(
      1,
      viewport,
      red,
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let first_bounds = match @primitives.Rect::new(9.25, 10.5, 20.0, 14.0) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let first_text = match
    @scene.SceneItem::text(
      2,
      first_bounds,
      "Aé",
      14.0,
      cyan,
      transform,
      0.5,
      Some(7),
    ) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let middle = match
    @scene.SceneItem::quad(3, rect(1.0, 2.0), cyan, transform, 0.75, Some(7)) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let second_text = match
    @scene.SceneItem::text(
      4,
      rect(3.5, 4.25),
      "猫",
      22.0,
      red,
      @scene.AffineTransform::identity(),
      1.0,
      Some(7),
    ) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let scene = match
    @scene.SceneSnapshot::new(
      viewport,
      1.5,
      [],
      [@scene.ClipChain::new(7, [viewport, clip])],
      [backdrop, first_text, middle, second_text],
    ) {
    Ok(s) => s
    Err(_) => abort("fixture")
  }
  let frame = match mixed_frame_data(scene) {
    Ok(value) => value
    Err(error) => fail("mixed serializer: \{error.code().label()}")
  }
  assert_eq(frame.data.length(), 5 + 4 * 23)
  assert_eq(frame.data[0], 0.0)
  assert_eq(frame.data[1], 0.0)
  assert_eq(frame.data[2], 100.0)
  assert_eq(frame.data[3], 80.0)
  assert_eq(frame.data[4], 1.5)
  assert_eq(frame.data[5], 0.0)
  assert_eq(frame.data[28], 1.0)
  assert_eq(frame.data[51], 0.0)
  assert_eq(frame.data[74], 1.0)
  assert_eq(frame.data[29], 9.25)
  assert_eq(frame.data[30], 10.5)
  assert_eq(frame.data[31], 20.0)
  assert_eq(frame.data[32], 14.0)
  assert_eq(frame.data[33], 10.0)
  assert_eq(frame.data[36], 240.0)
  assert_eq(frame.data[37], 0.9)
  assert_eq(frame.data[39], -0.15)
  assert_eq(frame.data[40], 1.1)
  assert_eq(frame.data[41], 3.25)
  assert_eq(frame.data[42], 4.5)
  assert_eq(frame.data[43], 0.5)
  assert_eq(frame.data[44], 5.0)
  assert_eq(frame.data[45], 7.0)
  assert_eq(frame.data[46], 40.0)
  assert_eq(frame.data[47], 30.0)
  assert_eq(frame.data[48], 0.0)
  assert_eq(frame.data[49], 3.0)
  assert_eq(frame.data[50], 14.0)
  assert_eq(frame.data[94], 3.0)
  assert_eq(frame.data[95], 3.0)
  assert_eq(frame.data[96], 22.0)
  try @utf8.decode(frame.text) catch {
    _ => fail("serialized UTF-8 blob is malformed")
  } noraise {
    value => assert_eq(value, "Aé猫")
  }

  // The public SceneSnapshot v1 quad ABI intentionally remains quad-only.
  match frame_data(scene) {
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) => fail("v1 serializer accepted mixed text")
  }

  let high = "😀".unsafe_substring(start=0, end=1)
  let low = "😀".unsafe_substring(start=1, end=2)
  for lone_surrogate in [high, low] {
    let lone = @scene.TextItem(
      id=5,
      bounds=rect(1.0, 2.0),
      text=lone_surrogate,
      font_size=14.0,
      color=cyan,
      transform=@scene.AffineTransform::identity(),
      opacity=1.0,
      clip_chain_id=None,
    )
    let invalid_scene = match
      @scene.SceneSnapshot::new(viewport, 1.0, [], [], [lone]) {
      Ok(value) => value
      Err(_) => abort("snapshot should retain v1 UTF-16 string")
    }
    match mixed_frame_data(invalid_scene) {
      Err(error) => assert_eq(error.code().label(), "unsupported_capability")
      Ok(_) => fail("isolated surrogate reached the native UTF-8 ABI")
    }
  }
}

///|
fn[T] require_ok(result : Result[T, @diagnostics.FrameworkError]) -> T raise {
  match result {
    Ok(value) => value
    Err(e) => fail("\{e.operation()}: \{e.code().label()}")
  }
}

///|
fn trace_ubuntu_e2e_stage(
  enabled : Bool,
  stage : Int,
  iteration : Int,
  scale : Double,
  window_generation : Int,
) -> Unit {
  // 1/2 bracket first present; 3/4 bracket dispatch polls; 5 means frame complete.
  if enabled {
    println(
      "GPUI_UBUNTU_E2E_STAGE stage=\{stage} iteration=\{iteration} scale=\{scale} generation=\{window_generation}",
    )
  }
}

///|
/// Clipboard and cursor depend on compositor seat resources. Headless
/// compositors may omit those resources, so require a typed result and record
/// the observed service status without weakening the window/render E2E.
fn record_optional_service(
  host : Host,
  capability : @platform.Capability,
  service : String,
) -> Unit raise {
  match host.require_capability(capability) {
    Ok(_) => println("GPUI_UBUNTU_E2E service=\{service} status=available")
    Err(error) => {
      assert_eq(error.operation(), "require_capability")
      assert_eq(error.code().label(), "unsupported_capability")
      println(
        "GPUI_UBUNTU_E2E service=\{service} status=unsupported error=unsupported_capability",
      )
    }
  }
}

///|
/// Opt-in native E2E: normal headless tests never silently claim native evidence.
test "Wayland E2E lifecycle, stale snapshots, completion, recovery and stress" {
  if @env.get_env_var("GPUI_UBUNTU_E2E") == Some("1") {
    let host = require_ok(Host::start())
    assert_true(host.state() == Running)
    record_optional_service(host, @platform.Clipboard, "clipboard")
    record_optional_service(host, @platform.Cursor, "cursor")
    require_ok(host.require_capability(@platform.GrayscaleTextFrames))
    assert_true(Host::start() is Err(_))
    let lifecycle_trace_enabled =
      @env.get_env_var("GPUI_UBUNTU_E2E_STAGE_TRACE") == Some("1")
    let mut window_generation = 0
    for iteration = 0; iteration < 24; iteration = iteration + 1 {
      println("GPUI_UBUNTU_E2E iteration=\{iteration} stage=create")
      let window = require_ok(
        host.create_window(160, 120, "gpui.mbt E2E 日本語"),
      )
      window_generation = window_generation + 1
      let events = require_ok(host.dispatch(0))
      let mut width = 160
      let mut height = 120
      let mut scale = 1.0
      let mut sequence : Int64 = 0
      for event in events {
        assert_true(event.window() == window)
        assert_true(event.sequence() > sequence)
        sequence = event.sequence()
        scale = event.scale()
        if event.kind() is @platform.Resized(width=w, height=h) {
          width = w.to_int()
          height = h.to_int()
        }
      }
      println("GPUI_UBUNTU_E2E iteration=\{iteration} stage=first-present")
      trace_ubuntu_e2e_stage(
        lifecycle_trace_enabled, 1, iteration, scale, window_generation,
      )
      require_ok(
        host.present(
          window,
          mixed_snapshot(width.to_double(), height.to_double(), scale),
        ),
      )
      trace_ubuntu_e2e_stage(
        lifecycle_trace_enabled, 2, iteration, scale, window_generation,
      )
      let mut completed = false
      for _attempt = 0; _attempt < 40 && !completed; _attempt = _attempt + 1 {
        trace_ubuntu_e2e_stage(
          lifecycle_trace_enabled, 3, iteration, scale, window_generation,
        )
        let dispatch_events = require_ok(host.dispatch(100))
        for event in dispatch_events {
          assert_true(event.sequence() > sequence)
          sequence = event.sequence()
          if event.kind() is @platform.FrameCompleted {
            completed = true
          }
          scale = event.scale()
        }
        trace_ubuntu_e2e_stage(
          lifecycle_trace_enabled, 4, iteration, scale, window_generation,
        )
        if completed {
          trace_ubuntu_e2e_stage(
            lifecycle_trace_enabled, 5, iteration, scale, window_generation,
          )
        }
      }
      assert_true(completed)
      if iteration == 0 {
        let high = "😀".unsafe_substring(start=0, end=1)
        let low = "😀".unsafe_substring(start=1, end=2)
        for lone_surrogate in [high, low] {
          let invalid_text = @scene.TextItem(
            id=8,
            bounds=rect(10.0, 8.0),
            text=lone_surrogate,
            font_size=16.0,
            color=match @primitives.Color::rgba(255, 255, 255, 255) {
              Ok(c) => c
              Err(_) => abort("fixture")
            },
            transform=@scene.AffineTransform::identity(),
            opacity=1.0,
            clip_chain_id=None,
          )
          let invalid_viewport = match
            @primitives.Rect::new(
              0.0,
              0.0,
              width.to_double(),
              height.to_double(),
            ) {
            Ok(value) => value
            Err(_) => abort("viewport fixture")
          }
          let invalid_snapshot = match
            @scene.SceneSnapshot::new(invalid_viewport, scale, [], [], [
              invalid_text,
            ]) {
            Ok(value) => value
            Err(_) => abort("lone surrogate snapshot")
          }
          match host.present(window, invalid_snapshot) {
            Err(error) =>
              assert_eq(error.code().label(), "unsupported_capability")
            Ok(_) => fail("isolated surrogate reached native submission")
          }
        }
        // A valid mixed frame still submits immediately after both serializer
        // rejections; neither failure leaves native frame state outstanding.
        require_ok(
          host.present(
            window,
            mixed_snapshot(width.to_double(), height.to_double(), scale),
          ),
        )
        let mut resumed = false
        for _attempt = 0; _attempt < 40 && !resumed; _attempt = _attempt + 1 {
          for event in require_ok(host.dispatch(100)) {
            if event.kind() is @platform.FrameCompleted {
              resumed = true
            }
          }
        }
        assert_true(resumed)
      }
      println("GPUI_UBUNTU_E2E iteration=\{iteration} stage=resize-recover")
      require_ok(host.set_size(window, 180, 140))
      match
        host.present(
          window,
          snapshot(width.to_double(), height.to_double(), scale),
        ) {
        Err(e) => assert_eq(e.code().label(), "busy")
        Ok(_) => fail("stale viewport presented")
      }
      for _resize = 0; _resize < 32; _resize = _resize + 1 {
        require_ok(host.set_size(window, 180, 140))
      }
      ignore(require_ok(host.dispatch(0)))
      require_ok(host.set_title(window, "updated"))
      match host.read_clipboard() {
        Err(e) => assert_eq(e.code().label(), "unsupported_capability")
        Ok(_) => fail("clipboard unavailable")
      }
      match host.write_clipboard("clipboard needs a real input serial") {
        Err(e) => assert_eq(e.code().label(), "unsupported_capability")
        Ok(_) => fail("clipboard write accepted without input serial")
      }
      require_ok(host.recover_renderer(window))
      println("GPUI_UBUNTU_E2E iteration=\{iteration} stage=recovered-present")
      require_ok(host.present(window, mixed_snapshot(180.0, 140.0, scale)))
      println("GPUI_UBUNTU_E2E iteration=\{iteration} stage=destroy")
      require_ok(host.destroy_window(window))
      require_ok(host.destroy_window(window))
      let terminal = require_ok(host.dispatch(0))
      assert_eq(terminal.length(), 1)
      assert_true(terminal[0].kind() is @platform.Destroyed)
      assert_true(host.present(window, snapshot(180.0, 140.0, scale)) is Err(_))
    }
    require_ok(@conformance.check_host(host))
    let restarted = require_ok(Host::start())
    require_ok(restarted.stop())
  }
}
