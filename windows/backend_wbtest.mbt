///|
#borrow(rgba)
extern "C" fn native_readback(
  host : Int,
  window : Int,
  rgba : FixedArray[Double],
) -> Int = "gpui_windows_readback"

///|
extern "C" fn native_wrong_thread(host : Int, window : Int) -> Int = "gpui_windows_test_wrong_thread"

///|
extern "C" fn native_clipboard_validation() -> Int = "gpui_windows_test_clipboard_validation"

///|
extern "C" fn native_wake_stop_race(host : Int) -> Int = "gpui_windows_test_wake_stop_race"

///|
extern "C" fn native_size_message(host : Int, window : Int, phase : Int) -> Int = "gpui_windows_test_size_message"

///|
extern "C" fn native_mouse_capture(host : Int, window : Int) -> Int = "gpui_windows_test_mouse_capture"

///|
extern "C" fn native_mouse_arm_destroy(host : Int, window : Int) -> Int = "gpui_windows_test_mouse_arm_destroy"

///|
extern "C" fn native_mouse_destroy_reset(host : Int, window : Int) -> Int = "gpui_windows_test_mouse_destroy_reset"

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
  let background = match @primitives.Color::rgba(24, 28, 36, 255) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let accent = match @primitives.Color::rgba(64, 160, 240, 255) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let bounds = match @primitives.Rect::new(16.0, 16.0, 64.0, 48.0) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let scene = @scene.Scene::new([
    @scene.PaintCommand::quad(1, viewport, background),
    @scene.PaintCommand::quad(2, bounds, accent),
  ])
  match scene.snapshot_v1(viewport, scale) {
    Ok(s) => s
    Err(_) => abort("fixture")
  }
}

///|
test "Win32 status adapter returns stable framework errors" {
  let cases = [
    (1, @diagnostics.UnsupportedCapability),
    (3, @diagnostics.InvalidInput),
    (4, @diagnostics.StaleHandle),
    (5, @diagnostics.Busy),
    (6, @diagnostics.HostStopping),
    (7, @diagnostics.WrongThread),
    (8, @diagnostics.ResourceExhausted),
    (9, @diagnostics.SurfaceLost),
    (10, @diagnostics.DeviceLost),
    (11, @diagnostics.ConversionFailed),
  ]
  for (status, expected) in cases {
    let error = backend_error(status, "operation")
    assert_eq(error.code().label(), expected.label())
    assert_eq(error.operation(), "operation")
    assert_true(error.backend() == Some("windows-d3d11"))
  }
}

///|
test "Win32 event translation keeps logical input and portable key values" {
  let data = FixedArray::make(10, 0.0)
  data[0] = 7.0
  data[3] = 1.5
  data[6] = 18.25
  data[7] = 21.5
  data[9] = 3.0
  match decode_event(data) {
    Some(@platform.Input(@primitives.PointerMoved(position~))) => {
      assert_eq(position.x(), 18.25)
      assert_eq(position.y(), 21.5)
    }
    _ => fail("pointer translation")
  }
  data[0] = 8.0
  data[8] = 1.0
  assert_true(
    decode_event(data)
    is Some(
      @platform.Input(
        @primitives.PointerButtonPressed(button=@primitives.Secondary, ..)
      )
    ),
  )
  data[0] = 10.0
  data[4] = -40.0
  data[8] = 1.0
  match decode_event(data) {
    Some(@platform.Input(@primitives.Scroll(delta~, ..))) => {
      assert_eq(delta.x(), -40.0)
      assert_eq(delta.y(), 0.0)
    }
    _ => fail("horizontal scroll translation")
  }
  data[0] = 11.0
  data[6] = 0x3042.0
  data[8] = 0.0
  assert_true(
    decode_event(data)
    is Some(
      @platform.Input(
        @primitives.KeyPressed(
          key=@primitives.Character("あ"),
          modifiers=_,
          repeat=false
        )
      )
    ),
  )
  data[0] = 6.0
  data[8] = 1.0
  assert_true(decode_event(data) is Some(@platform.FocusChanged(true)))
}

///|
test "Win32 frame serializer preserves quad transform opacity and clip" {
  let viewport = rect(100.0, 80.0)
  let bounds = match @primitives.Rect::new(5.0, 10.0, 40.0, 30.0) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let clip = match @primitives.Rect::new(15.0, 20.0, 40.0, 40.0) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
  let color = match @primitives.Color::rgba(12, 34, 56, 128) {
    Ok(c) => c
    Err(_) => abort("fixture")
  }
  let transform = match
    @scene.AffineTransform::new(0.0, 1.0, -1.0, 0.0, 50.0, 5.0) {
    Ok(t) => t
    Err(_) => abort("fixture")
  }
  let item = match
    @scene.SceneItem::quad(1, bounds, color, transform, 0.5, Some(7)) {
    Ok(i) => i
    Err(_) => abort("fixture")
  }
  let scene = match
    @scene.SceneSnapshot::new(
      viewport,
      1.5,
      [],
      [@scene.ClipChain::new(7, [viewport, clip])],
      [item],
    ) {
    Ok(s) => s
    Err(_) => abort("fixture")
  }
  match frame_data(scene) {
    Err(_) => fail("supported v1 quad")
    Ok(data) => {
      assert_eq(data.length(), 24)
      assert_eq(data[0], 0.0)
      assert_eq(data[2], 100.0)
      assert_eq(data[4], 1.5)
      assert_eq(data[5], 5.0)
      assert_eq(data[13], 0.0)
      assert_eq(data[14], 1.0)
      assert_eq(data[19], 0.5)
      assert_eq(data[20], 15.0)
      assert_eq(data[21], 20.0)
      assert_eq(data[22], 40.0)
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
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) => fail("resource table is unsupported")
  }
}

///|
fn[T] required(result : Result[T, @diagnostics.FrameworkError]) -> T {
  match result {
    Ok(value) => value
    Err(error) => abort("\{error.operation()}: \{error.code().label()}")
  }
}

///|
test "non-Windows native stub never claims a real host" {
  if @env.get_env_var("GPUI_WINDOWS_E2E") != Some("1") {
    match Host::start() {
      Err(error) => assert_eq(error.code().label(), "unsupported_capability")
      Ok(host) => required(host.stop())
    }
  }
}

///|
/// Opt-in native Windows smoke. It verifies rendered GPU pixels from a staging
/// readback, then resize/snapshot rejection, Unicode clipboard, and teardown.
test "Windows D3D11 HWND renders and reads back first frame" {
  if @env.get_env_var("GPUI_WINDOWS_E2E") == Some("1") {
    let host = required(Host::start())
    assert_true(host.state() == Running)
    match Host::start() {
      Err(error) => assert_eq(error.code().label(), "busy")
      Ok(second) => {
        required(second.stop())
        fail("second native host should be busy")
      }
    }
    let window = required(
      host.create_window(128, 96, "gpui.mbt Windows 日本語"),
    )
    match host.create_window(32, 32, "second window") {
      Err(error) => assert_eq(error.code().label(), "busy")
      Ok(second) => {
        required(host.destroy_window(second))
        fail("second native window should be busy")
      }
    }
    let events = required(host.dispatch(0))
    let mut created = false
    let mut last_sequence : Int64 = 0
    let mut scale = 1.0
    for event in events {
      assert_true(event.window() == window)
      assert_true(event.sequence() > last_sequence)
      last_sequence = event.sequence()
      scale = event.scale()
      if event.kind() is @platform.Created {
        created = true
      }
    }
    assert_true(created)
    required(outcome(native_clipboard_validation(), "clipboard_validation"))
    required(
      outcome(
        native_wrong_thread(host.token, window.value().to_int()),
        "wrong_thread_probe",
      ),
    )
    match host.require_capability(@platform.RendererRecovery) {
      Err(error) => assert_eq(error.code().label(), "unsupported_capability")
      Ok(_) => fail("renderer recovery must remain an unclaimed capability")
    }
    match host.set_title(window, "prefix\u{0}suffix") {
      Err(error) => assert_eq(error.code().label(), "conversion_failed")
      Ok(_) => fail("a title containing NUL must be rejected")
    }
    required(host.set_title(window, "updated — gpui.mbt"))
    required(host.present(window, snapshot(128.0, 96.0, scale)))
    let pixels = FixedArray::make(12, 0.0)
    let status = native_readback(host.token, window.value().to_int(), pixels)
    required(outcome(status, "readback"))
    assert_eq(pixels[0], 24.0)
    assert_eq(pixels[1], 28.0)
    assert_eq(pixels[2], 36.0)
    assert_eq(pixels[3], 255.0)
    assert_eq(pixels[4], 64.0)
    assert_eq(pixels[5], 160.0)
    assert_eq(pixels[6], 240.0)
    assert_eq(pixels[7], 255.0)
    assert_eq(pixels[8], 24.0)
    assert_eq(pixels[9], 28.0)
    assert_eq(pixels[10], 36.0)
    assert_eq(pixels[11], 255.0)
    let mut frame_completed = false
    let mut completion_polls = 0
    while !frame_completed && completion_polls < 40 {
      let frame_events = required(host.dispatch(16))
      for event in frame_events {
        assert_true(event.sequence() > last_sequence)
        last_sequence = event.sequence()
        if event.kind() is @platform.FrameCompleted {
          frame_completed = true
        }
      }
      completion_polls += 1
    }
    assert_true(frame_completed)

    let (initial_width, initial_height, _) = required(
      host.window_metrics(window),
    )
    for phase in 0..<2 {
      required(
        outcome(
          native_size_message(host.token, window.value().to_int(), phase),
          "size_message",
        ),
      )
      let size_events = required(host.dispatch(0))
      for event in size_events {
        assert_true(event.sequence() > last_sequence)
        last_sequence = event.sequence()
      }
      assert_true(
        !size_events.any(event => event.kind() is @platform.Resized(..)),
      )
      let (width, height, _) = required(host.window_metrics(window))
      assert_eq(width, initial_width)
      assert_eq(height, initial_height)
    }
    required(
      outcome(
        native_size_message(host.token, window.value().to_int(), 2),
        "size_restore",
      ),
    )
    let restore_events = required(host.dispatch(0))
    let mut restored = false
    for event in restore_events {
      assert_true(event.sequence() > last_sequence)
      last_sequence = event.sequence()
      match event.kind() {
        @platform.Resized(width~, height~) => {
          assert_eq(width, initial_width)
          assert_eq(height, initial_height)
          restored = true
        }
        _ => ()
      }
    }
    assert_true(restored)
    let (restored_width, restored_height, _) = required(
      host.window_metrics(window),
    )
    assert_eq(restored_width, initial_width)
    assert_eq(restored_height, initial_height)

    required(
      outcome(
        native_mouse_capture(host.token, window.value().to_int()),
        "mouse_capture_probe",
      ),
    )
    let mouse_events = required(host.dispatch(0))
    let expected_buttons = [
      @primitives.Primary,
      @primitives.Secondary,
      @primitives.Primary,
      @primitives.Secondary,
      @primitives.Back,
      @primitives.Forward,
      @primitives.Back,
      @primitives.Forward,
      @primitives.Middle,
      @primitives.Middle,
      @primitives.Primary,
      @primitives.Primary,
    ]
    let expected_pressed = [
      true, true, false, false, true, true, false, false, true, false, true, true,
    ]
    let mut button_event_index = 0
    for event in mouse_events {
      assert_true(event.sequence() > last_sequence)
      last_sequence = event.sequence()
      match event.kind() {
        @platform.Input(@primitives.PointerButtonPressed(button~, ..)) => {
          assert_true(expected_pressed[button_event_index])
          assert_true(button == expected_buttons[button_event_index])
          button_event_index += 1
        }
        @platform.Input(@primitives.PointerButtonReleased(button~, ..)) => {
          assert_true(!expected_pressed[button_event_index])
          assert_true(button == expected_buttons[button_event_index])
          button_event_index += 1
        }
        _ => ()
      }
    }
    assert_eq(button_event_index, expected_buttons.length())

    let sample_text = "clipboard 日本語 😀"
    match host.write_clipboard("prefix\u{0}suffix") {
      Err(error) => assert_eq(error.code().label(), "conversion_failed")
      Ok(_) => fail("clipboard text containing NUL must be rejected")
    }
    required(host.write_clipboard(sample_text))
    assert_eq(required(host.read_clipboard()), sample_text)

    required(host.set_size(window, 160, 120))
    let resize_events = required(host.dispatch(0))
    for event in resize_events {
      assert_true(event.sequence() > last_sequence)
      last_sequence = event.sequence()
      scale = event.scale()
    }
    match host.present(window, snapshot(128.0, 96.0, scale)) {
      Err(error) => assert_eq(error.code().label(), "busy")
      Ok(_) => fail("stale viewport was presented after resize")
    }
    required(host.present(window, snapshot(160.0, 120.0, scale)))
    frame_completed = false
    completion_polls = 0
    while !frame_completed && completion_polls < 40 {
      let frame_events = required(host.dispatch(16))
      for event in frame_events {
        assert_true(event.sequence() > last_sequence)
        last_sequence = event.sequence()
        if event.kind() is @platform.FrameCompleted {
          frame_completed = true
        }
      }
      completion_polls += 1
    }
    assert_true(frame_completed)
    // The frame loop drained earlier traffic; this lone WM_CLOSE must reach
    // the window procedure during the next dispatch.
    required(host.request_close(window))
    let close_events = required(host.dispatch(0))
    assert_true(
      close_events.any(event => event.kind() is @platform.CloseRequested),
    )
    required(
      outcome(
        native_mouse_arm_destroy(host.token, window.value().to_int()),
        "mouse_arm_destroy",
      ),
    )
    required(host.destroy_window(window))
    required(
      outcome(
        native_mouse_destroy_reset(host.token, window.value().to_int()),
        "mouse_destroy_reset",
      ),
    )
    required(host.destroy_window(window))
    let terminal_events = required(host.dispatch(0))
    assert_eq(terminal_events.length(), 1)
    assert_true(terminal_events[0].kind() is @platform.Destroyed)
    assert_true(host.present(window, snapshot(160.0, 120.0, scale)) is Err(_))
    match host.set_title(window, "stale title") {
      Err(error) => assert_eq(error.code().label(), "stale_handle")
      Ok(_) => fail("stale title operation succeeded")
    }
    let next_window = required(
      host.create_window(64, 48, "next window generation"),
    )
    required(host.destroy_window(next_window))
    required(host.destroy_window(next_window))
    let next_destroyed_events = required(host.dispatch(0))
    assert_eq(next_destroyed_events.length(), 1)
    assert_true(next_destroyed_events[0].kind() is @platform.Destroyed)
    match host.destroy_window(window) {
      Err(error) => assert_eq(error.code().label(), "stale_handle")
      Ok(_) => fail("older destroyed window handle was accepted")
    }
    required(host.request_exit())
    assert_true(host.state() == Quiescing)
    required(outcome(native_wake_stop_race(host.token), "wake_stop_race"))
    required(host.stop())
    required(host.stop())
    for _ in 0..<2 {
      let restarted = required(Host::start())
      assert_true(restarted.state() == Running)
      match restarted.destroy_window(window) {
        Err(error) => assert_eq(error.code().label(), "stale_handle")
        Ok(_) => fail("previous-generation window handle was accepted")
      }
      let queued_events = required(restarted.dispatch(0))
      assert_true(
        !queued_events.any(event => {
          event.kind() is @platform.Wake ||
          event.kind() is @platform.ExitRequested
        }),
      )
      assert_true(restarted.state() == Running)
      let repeated_window = required(
        restarted.create_window(96, 72, "restart smoke 日本語"),
      )
      required(restarted.destroy_window(repeated_window))
      required(restarted.stop())
    }
  }
}

///|
test "shared backend lifecycle conformance on Windows" {
  if @env.get_env_var("GPUI_WINDOWS_E2E") == Some("1") {
    required(@conformance.check_host(required(Host::start())))
  }
}
