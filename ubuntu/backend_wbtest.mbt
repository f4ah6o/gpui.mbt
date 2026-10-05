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
fn[T] require_ok(result : Result[T, @diagnostics.FrameworkError]) -> T raise {
  match result {
    Ok(value) => value
    Err(e) => fail("\{e.operation()}: \{e.code().label()}")
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
    assert_true(Host::start() is Err(_))
    for iteration = 0; iteration < 24; iteration = iteration + 1 {
      println("GPUI_UBUNTU_E2E iteration=\{iteration} stage=create")
      let window = require_ok(
        host.create_window(160, 120, "gpui.mbt E2E 日本語"),
      )
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
      require_ok(
        host.present(
          window,
          snapshot(width.to_double(), height.to_double(), scale),
        ),
      )
      let mut completed = false
      for _attempt = 0; _attempt < 40 && !completed; _attempt = _attempt + 1 {
        for event in require_ok(host.dispatch(100)) {
          assert_true(event.sequence() > sequence)
          sequence = event.sequence()
          if event.kind() is @platform.FrameCompleted {
            completed = true
          }
          scale = event.scale()
        }
      }
      assert_true(completed)
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
      require_ok(host.present(window, snapshot(180.0, 140.0, scale)))
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
