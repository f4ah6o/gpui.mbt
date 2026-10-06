///|
#borrow(rgba)
extern "C" fn native_readback(
  host : Int,
  window : Int,
  rgba : FixedArray[Double],
) -> Int = "gpui_windows_readback"

///|
#borrow(expected_rgba, output)
extern "C" fn native_test_readback_region(
  host : Int,
  window : Int,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
  expected_rgba : FixedArray[Double],
  output : FixedArray[Double],
) -> Int = "gpui_windows_test_readback_region"

///|
#borrow(counts)
extern "C" fn native_test_renderer_counts(
  host : Int,
  window : Int,
  counts : FixedArray[Int64],
) -> Int = "gpui_windows_test_renderer_counts"

///|
extern "C" fn native_wrong_thread(host : Int, window : Int) -> Int = "gpui_windows_test_wrong_thread"

///|
extern "C" fn native_clipboard_validation() -> Int = "gpui_windows_test_clipboard_validation"

///|
extern "C" fn native_wake_stop_race(host : Int) -> Int = "gpui_windows_test_wake_stop_race"

///|
extern "C" fn native_size_message(host : Int, window : Int, phase : Int) -> Int = "gpui_windows_test_size_message"

///|
#borrow(mouse_diagnostic)
extern "C" fn native_mouse_capture(
  host : Int,
  window : Int,
  mouse_diagnostic : FixedArray[Int],
) -> Int = "gpui_windows_test_mouse_capture"

///|
extern "C" fn native_mouse_arm_destroy(host : Int, window : Int) -> Int = "gpui_windows_test_mouse_arm_destroy"

///|
extern "C" fn native_mouse_destroy_reset(host : Int, window : Int) -> Int = "gpui_windows_test_mouse_destroy_reset"

///|
#borrow(failed_stage)
extern "C" fn native_text_session_staging(
  failed_stage : FixedArray[Int],
) -> Int = "gpui_windows_test_text_session_staging"

///|
fn rect(w : Double, h : Double) -> @primitives.Rect {
  match @primitives.Rect::new(0.0, 0.0, w, h) {
    Ok(r) => r
    Err(_) => abort("fixture")
  }
}

///|
fn required_scene_text_run(
  id : UInt64,
  bounds : @primitives.Rect,
  origin : @primitives.Point,
  text : String,
  font_size : Double,
  color : @primitives.Color,
  transform : @scene.AffineTransform,
) -> @scene.SceneItem {
  match
    @scene.SceneItem::text_run(
      id,
      bounds,
      origin,
      text,
      font_size,
      color,
      transform,
      1.0,
      None,
    ) {
    Ok(item) => item
    Err(_) => abort("text run fixture")
  }
}

///|
fn required_scene_quad(
  id : UInt64,
  bounds : @primitives.Rect,
  color : @primitives.Color,
  transform : @scene.AffineTransform,
) -> @scene.SceneItem {
  match @scene.SceneItem::quad(id, bounds, color, transform, 1.0, None) {
    Ok(item) => item
    Err(_) => abort("quad fixture")
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
  data[0] = 16.0
  data[6] = 0x3042.0
  data[8] = 0.0
  assert_true(
    decode_event(data)
    is Some(@platform.Input(@primitives.TextInput(text="あ"))),
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
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) => fail("bounded text must not silently render as a native quad")
  }
  let text_origin = match @primitives.Point::new(3.5, 4.25) {
    Ok(value) => value
    Err(_) => abort("fixture")
  }
  let text_run = match
    @scene.SceneItem::text_run(
      3,
      bounds,
      text_origin,
      "Origin-aware browser text",
      16.0,
      color,
      transform,
      1.0,
      None,
    ) {
    Ok(value) => value
    Err(_) => abort("fixture")
  }
  let text_run_scene = match
    @scene.SceneSnapshot::new(
      viewport,
      1.0,
      [],
      [@scene.ClipChain::new(7, [viewport])],
      [item, text_run],
    ) {
    Ok(value) => value
    Err(_) => abort("fixture")
  }
  match frame_data(text_run_scene) {
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) =>
      fail("origin-aware text must be unsupported before quad serialization")
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
fn await_frame_completed(host : Host, last_sequence : Int64) -> Int64 {
  let mut completed = false
  let mut polls = 0
  let mut last = last_sequence
  while !completed && polls < 40 {
    let events = required(host.dispatch(16))
    for event in events {
      if event.sequence() <= last {
        abort("frame event sequence did not advance")
      }
      last = event.sequence()
      if event.kind() is @platform.FrameCompleted {
        completed = true
      }
    }
    polls += 1
  }
  if !completed {
    abort("frame did not complete")
  }
  last
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
test "Win32 production IMM session staging is atomic" {
  let failed_stage = FixedArray::make(1, -1)
  let status = native_text_session_staging(failed_stage)
  if status == 1 {
    // The portable non-Windows backend keeps the experimental native path
    // explicitly unavailable.
    assert_eq(failed_stage[0], -1)
    return
  }
  assert_eq(status, 0)
  assert_eq(failed_stage[0], 0)
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
    required(host.require_capability(@platform.GrayscaleTextFrames))
    match host.require_capability(@platform.TextInput) {
      Err(error) => assert_eq(error.code().label(), "unsupported_capability")
      Ok(_) => fail("private IMM ingress must not advertise public TextInput")
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

    // Core DirectWrite masks are copied and clipped before touching the
    // backbuffer; the staging readback scans actual D3D11 output, not a model.
    let text_viewport = rect(128.0, 96.0)
    let white = match @primitives.Color::rgba(255, 255, 255, 255) {
      Ok(value) => value
      Err(_) => abort("text color fixture")
    }
    let run_bounds = match @primitives.Rect::new(16.0, 20.0, 40.0, 32.0) {
      Ok(value) => value
      Err(_) => abort("text clip fixture")
    }
    let run_origin = match @primitives.Point::new(16.0, 20.0) {
      Ok(value) => value
      Err(_) => abort("text origin fixture")
    }
    let identity = @scene.AffineTransform::identity()
    let clipped_run = required_scene_text_run(
      70, run_bounds, run_origin, "MMMMMMMMMMMM", 22.0, white, identity,
    )
    let clipped_scene = match
      @scene.SceneSnapshot::new(text_viewport, scale, [], [], [clipped_run]) {
      Ok(value) => value
      Err(_) => abort("bounded text snapshot fixture")
    }
    required(host.present(window, clipped_scene))
    last_sequence = await_frame_completed(host, last_sequence)
    let transparent = FixedArray::make(4, 0.0)
    let clipped_stats = FixedArray::make(4, 0.0)
    required(
      outcome(
        native_test_readback_region(
          host.token,
          window.value().to_int(),
          16.0,
          20.0,
          40.0,
          32.0,
          transparent,
          clipped_stats,
        ),
        "text_mask_readback",
      ),
    )
    assert_true(clipped_stats[1] > 0.0)
    assert_true(clipped_stats[2] > 0.0)
    let clipped_outside = FixedArray::make(4, 0.0)
    required(
      outcome(
        native_test_readback_region(
          host.token,
          window.value().to_int(),
          56.0,
          20.0,
          16.0,
          32.0,
          transparent,
          clipped_outside,
        ),
        "text_clip_readback",
      ),
    )
    assert_eq(clipped_outside[1], 0.0)

    // The run's local origin is outside the global viewport coordinates, but
    // its item translation places it at the viewport's top-left. Raster
    // preflight must stay in item-local space; the viewport is applied after
    // the transform by the D3D scissor and vertex mapping.
    let offset_viewport = match @primitives.Rect::new(40.0, 24.0, 128.0, 96.0) {
      Ok(value) => value
      Err(_) => abort("offset viewport fixture")
    }
    let local_bounds = match @primitives.Rect::new(0.0, 0.0, 64.0, 32.0) {
      Ok(value) => value
      Err(_) => abort("translated text bounds")
    }
    let local_origin = match @primitives.Point::new(0.0, 0.0) {
      Ok(value) => value
      Err(_) => abort("translated text origin")
    }
    let translated = match
      @scene.AffineTransform::new(1.0, 0.0, 0.0, 1.0, 40.0, 24.0) {
      Ok(value) => value
      Err(_) => abort("translated text transform")
    }
    let translated_run = required_scene_text_run(
      73, local_bounds, local_origin, "MMMM", 24.0, white, translated,
    )
    let translated_scene = match
      @scene.SceneSnapshot::new(offset_viewport, scale, [], [], [translated_run]) {
      Ok(value) => value
      Err(_) => abort("translated text snapshot")
    }
    required(host.present(window, translated_scene))
    last_sequence = await_frame_completed(host, last_sequence)
    let translated_pixels = FixedArray::make(4, 0.0)
    required(
      outcome(
        native_test_readback_region(
          host.token,
          window.value().to_int(),
          0.0,
          0.0,
          32.0,
          32.0,
          transparent,
          translated_pixels,
        ),
        "translated_text_readback",
      ),
    )
    assert_true(translated_pixels[1] > 0.0)
    assert_true(translated_pixels[2] > 0.0)

    // A later opaque quad masks the right side of an earlier text run. The
    // left side retains real fractional glyph coverage, proving both item
    // ordering and the alpha-texture draw path.
    let overlap_bounds = match @primitives.Rect::new(16.0, 20.0, 80.0, 32.0) {
      Ok(value) => value
      Err(_) => abort("overlap text clip")
    }
    let overlap_run = required_scene_text_run(
      71, overlap_bounds, run_origin, "MMMMMMMM", 24.0, white, identity,
    )
    let overlay_bounds = match @primitives.Rect::new(80.0, 16.0, 32.0, 40.0) {
      Ok(value) => value
      Err(_) => abort("overlay bounds")
    }
    let red = match @primitives.Color::rgba(255, 0, 0, 255) {
      Ok(value) => value
      Err(_) => abort("overlay color")
    }
    let overlay = required_scene_quad(72, overlay_bounds, red, identity)
    let overlap_scene = match
      @scene.SceneSnapshot::new(text_viewport, scale, [], [], [
        overlap_run, overlay,
      ]) {
      Ok(value) => value
      Err(_) => abort("overlap snapshot fixture")
    }
    required(host.present(window, overlap_scene))
    last_sequence = await_frame_completed(host, last_sequence)
    let text_region = FixedArray::make(4, 0.0)
    required(
      outcome(
        native_test_readback_region(
          host.token,
          window.value().to_int(),
          20.0,
          20.0,
          50.0,
          32.0,
          transparent,
          text_region,
        ),
        "interleaved_text_readback",
      ),
    )
    assert_true(text_region[1] > 0.0)
    assert_true(text_region[2] > 0.0)
    let red_pixel = FixedArray::make(4, 0.0)
    red_pixel[0] = 255.0
    red_pixel[3] = 255.0
    let overlay_region = FixedArray::make(4, 0.0)
    required(
      outcome(
        native_test_readback_region(
          host.token,
          window.value().to_int(),
          84.0,
          20.0,
          24.0,
          32.0,
          red_pixel,
          overlay_region,
        ),
        "ordered_quad_readback",
      ),
    )
    assert_eq(overlay_region[3], overlay_region[0])

    // An invalid final UTF-8 run fails after an earlier mask was staged. The
    // payload bypasses the high-level serializer deliberately; actual native
    // clear/draw/present call counts prove rejection precedes GPU submission.
    let rejected_frame = FixedArray::make(55, 0.0)
    rejected_frame[0] = 0.0
    rejected_frame[1] = 0.0
    rejected_frame[2] = 128.0
    rejected_frame[3] = 96.0
    rejected_frame[4] = scale
    for run_index = 0; run_index < 2; run_index = run_index + 1 {
      let record = 5 + run_index * 25
      let q = record + 1
      rejected_frame[record] = 2.0
      rejected_frame[q] = 16.0
      rejected_frame[q + 1] = 20.0
      rejected_frame[q + 2] = 80.0
      rejected_frame[q + 3] = 32.0
      rejected_frame[q + 4] = 255.0
      rejected_frame[q + 5] = 255.0
      rejected_frame[q + 6] = 255.0
      rejected_frame[q + 7] = 255.0
      rejected_frame[q + 8] = 1.0
      rejected_frame[q + 11] = 1.0
      rejected_frame[q + 14] = 1.0
      rejected_frame[q + 15] = 0.0
      rejected_frame[q + 16] = 0.0
      rejected_frame[q + 17] = 128.0
      rejected_frame[q + 18] = 96.0
      rejected_frame[q + 19] = run_index.to_double()
      rejected_frame[q + 20] = 1.0
      rejected_frame[q + 21] = 24.0
      rejected_frame[q + 22] = 16.0
      rejected_frame[q + 23] = 20.0
    }
    let invalid_utf8 = Bytes::makei(2, index => {
      if index == 0 {
        (77).to_byte()
      } else {
        (255).to_byte()
      }
    })
    let renderer_counts_before = FixedArray::make(3, Int64::from_int(0))
    required(
      outcome(
        native_test_renderer_counts(
          host.token,
          window.value().to_int(),
          renderer_counts_before,
        ),
        "renderer_counts_before_reject",
      ),
    )
    assert_eq(
      native_present_text(
        2,
        host.token,
        window.value().to_int(),
        rejected_frame,
        rejected_frame.length(),
        invalid_utf8,
        invalid_utf8.length(),
      ),
      1,
    )
    let renderer_counts_after = FixedArray::make(3, Int64::from_int(0))
    required(
      outcome(
        native_test_renderer_counts(
          host.token,
          window.value().to_int(),
          renderer_counts_after,
        ),
        "renderer_counts_after_reject",
      ),
    )
    for index = 0; index < 3; index = index + 1 {
      assert_eq(renderer_counts_after[index], renderer_counts_before[index])
    }
    let after_reject_text = FixedArray::make(4, 0.0)
    required(
      outcome(
        native_test_readback_region(
          host.token,
          window.value().to_int(),
          20.0,
          20.0,
          50.0,
          32.0,
          transparent,
          after_reject_text,
        ),
        "atomic_text_readback",
      ),
    )
    let after_reject_overlay = FixedArray::make(4, 0.0)
    required(
      outcome(
        native_test_readback_region(
          host.token,
          window.value().to_int(),
          84.0,
          20.0,
          24.0,
          32.0,
          red_pixel,
          after_reject_overlay,
        ),
        "atomic_overlay_readback",
      ),
    )
    for index = 0; index < 4; index = index + 1 {
      assert_eq(after_reject_text[index], text_region[index])
      assert_eq(after_reject_overlay[index], overlay_region[index])
    }

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

    let mouse_diagnostic = FixedArray::make(10, 0)
    let mouse_status = native_mouse_capture(
      host.token,
      window.value().to_int(),
      mouse_diagnostic,
    )
    let mouse_stage = match mouse_diagnostic[0] {
      0 => "initial_state"
      1 => "left_down"
      2 => "right_down"
      3 => "left_up"
      4 => "right_up"
      5 => "xbutton1_down"
      6 => "xbutton2_down"
      7 => "xbutton1_up"
      8 => "xbutton2_up"
      9 => "middle_down"
      10 => "middle_up"
      11 => "capture_loss_down"
      12 => "capture_changed_reset"
      13 => "capture_changed_release"
      14 => "focus_loss_down"
      15 => "focus_lost_reset"
      16 => "focus_lost_release"
      _ => "unknown"
    }
    let mouse_operation = if mouse_status == 0 {
      "mouse_capture_probe"
    } else {
      "mouse_capture_probe stage=\{mouse_stage}(\{mouse_diagnostic[0]}) expected_buttons=\{mouse_diagnostic[1]} actual_buttons=\{mouse_diagnostic[2]} expected_capture=\{mouse_diagnostic[3]} actual_capture=\{mouse_diagnostic[4]} message=\{mouse_diagnostic[5]} wparam_low=\{mouse_diagnostic[6]} wparam_high=\{mouse_diagnostic[7]} capture_change_count=\{mouse_diagnostic[8]} last_capture_target=\{mouse_diagnostic[9]}"
    }
    if mouse_status != 0 {
      println(mouse_operation)
    }
    required(outcome(mouse_status, mouse_operation))
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
