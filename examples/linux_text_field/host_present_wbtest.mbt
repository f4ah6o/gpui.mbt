///|
extern "C" fn field_test_monotonic_ns() -> Int64 = "gpui_field_test_monotonic_ns"

///|
const FIELD_E2E_TIMEOUT_NS : Int64 = 5000000000L

///|
const FIELD_E2E_NS_PER_MS : Int64 = 1000000L

///|
fn field_e2e_elapsed_ns(start : Int64, now : Int64) -> Int64? {
  if start < 0L || now < 0L || now < start {
    None
  } else {
    // Subtraction is safe only after validating 0 <= start <= now.
    Some(now - start)
  }
}

///|
fn field_e2e_remaining_timeout_ms(start : Int64, now : Int64) -> Int? {
  match field_e2e_elapsed_ns(start, now) {
    None => None
    Some(elapsed) =>
      if elapsed >= FIELD_E2E_TIMEOUT_NS {
        None
      } else {
        let remaining = FIELD_E2E_TIMEOUT_NS - elapsed
        // Round up so a positive sub-millisecond remainder never becomes a
        // nonblocking wait. The bounded timeout is also safe near Int64::MAX.
        let rounded = (remaining + FIELD_E2E_NS_PER_MS - 1L) /
          FIELD_E2E_NS_PER_MS
        Some(if rounded > 100L { 100 } else { rounded.to_int() })
      }
  }
}

///|
fn field_e2e_clock_now() -> Int64 raise {
  let now = field_test_monotonic_ns()
  if now < 0L {
    fail("CLOCK_MONOTONIC test clock failed")
  }
  now
}

///|
fn field_e2e_check_window(host : @native.Host) -> Unit raise {
  if host.state() != @native.Running {
    fail("live field window host stopped before frame admission")
  }
}

///|
fn field_e2e_next_event(
  host : @native.Host,
  window : @platform.WindowId,
  timeout_ms : Int,
  started_ns : Int64,
) -> @platform.Event? raise {
  field_e2e_check_window(host)
  match host.next_event(timeout_ms~) {
    Err(error) => fail("\{error.operation()}: \{error.code().label()}")
    Ok(None) => {
      field_e2e_check_window(host)
      None
    }
    Ok(Some(event)) => {
      match field_e2e_remaining_timeout_ms(started_ns, field_e2e_clock_now()) {
        None =>
          fail(
            "live field window did not settle before the five-second deadline",
          )
        Some(_) => ()
      }
      field_e2e_check_window(host)
      if event.window() == window {
        match event.kind() {
          @platform.CloseRequested | @platform.Destroyed =>
            fail("live field window closed or was destroyed while settling")
          _ => ()
        }
      }
      Some(event)
    }
  }
}

///|
fn field_e2e_drain_events(
  host : @native.Host,
  window : @platform.WindowId,
  first_timeout_ms : Int,
  started_ns : Int64,
) -> Unit raise {
  let mut event = field_e2e_next_event(
    host, window, first_timeout_ms, started_ns,
  )
  while event is Some(_) {
    let now = field_e2e_clock_now()
    match field_e2e_remaining_timeout_ms(started_ns, now) {
      None =>
        fail("live field window did not settle before the five-second deadline")
      Some(_) => ()
    }
    event = field_e2e_next_event(host, window, 0, started_ns)
  }
  field_e2e_check_window(host)
}

///|
fn field_e2e_present_ready(
  host : @native.Host,
  window : @platform.WindowId,
  initial : @text_field.TextField,
) -> @text_field.TextField raise {
  let started_ns = field_e2e_clock_now()
  let mut field = initial
  let mut wait_ms = 0
  let mut accepted : @text_field.TextField? = None
  while accepted is None {
    let now = field_e2e_clock_now()
    let remaining_ms = match field_e2e_remaining_timeout_ms(started_ns, now) {
      Some(value) => value
      None =>
        fail("live field window did not settle before the five-second deadline")
    }
    field_e2e_drain_events(
      host,
      window,
      if wait_ms > remaining_ms {
        remaining_ms
      } else {
        wait_ms
      },
      started_ns,
    )
    let (width, height, scale) = field_e2e_required(host.window_metrics(window))
    if width < 64.0 ||
      height < 88.0 ||
      scale <= 0.0 ||
      width.is_nan() ||
      width.is_inf() ||
      height.is_nan() ||
      height.is_inf() ||
      scale.is_nan() ||
      scale.is_inf() {
      fail("live window geometry cannot admit the field bounds")
    }
    let bounds = match native_field_bounds(width, height) {
      Ok(value) => value
      Err(_) => fail("live window geometry cannot admit the field bounds")
    }
    field = match field.with_bounds(bounds) {
      Ok(value) => value
      Err(_) => fail("live field bounds update failed while settling metrics")
    }
    if field.document() != initial.document() ||
      field.selection() != initial.selection() ||
      field.is_focused() != initial.is_focused() {
      fail("settling live metrics changed field document, selection, or focus")
    }
    let scene = match field_scene(field, width, height, scale) {
      Ok(value) => value
      Err(_) => fail("settled field did not produce a scene snapshot")
    }
    field_e2e_check_window(host)
    match host.present(window, scene) {
      Ok(_) => {
        match
          field_e2e_remaining_timeout_ms(started_ns, field_e2e_clock_now()) {
          None =>
            fail(
              "live field window did not settle before the five-second deadline",
            )
          Some(_) => ()
        }
        field_e2e_check_window(host)
        accepted = Some(field)
      }
      Err(error) =>
        if error.code() is @diagnostics.Busy {
          let now = field_e2e_clock_now()
          wait_ms = match field_e2e_remaining_timeout_ms(started_ns, now) {
            Some(value) => value
            None =>
              fail(
                "live field window did not settle before the five-second deadline",
              )
          }
        } else {
          fail("\{error.operation()}: \{error.code().label()}")
        }
    }
  }
  accepted.unwrap()
}

///|
fn[T] field_e2e_required(
  result : Result[T, @diagnostics.FrameworkError],
) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail("\{error.operation()}: \{error.code().label()}")
  }
}

///|
fn field_e2e_drain_frame(
  host : @native.Host,
  window : @platform.WindowId,
) -> Unit raise {
  let started_ns = field_e2e_clock_now()
  let mut completed = false
  while !completed {
    let now = field_e2e_clock_now()
    let timeout_ms = match field_e2e_remaining_timeout_ms(started_ns, now) {
      Some(value) => value
      None =>
        fail("frame completion did not arrive before the five-second deadline")
    }
    match field_e2e_next_event(host, window, timeout_ms, started_ns) {
      None => ()
      Some(event) =>
        if event.window() == window && event.kind() is @platform.FrameCompleted {
          completed = true
        }
    }
  }
}

///|
fn field_e2e_with_late_malformed_text(
  valid : @scene.SceneSnapshot,
) -> @scene.SceneSnapshot raise {
  // The v1 scene envelope can hold a lone UTF-16 surrogate. Keep it after the
  // already prepared field items so Host.present exercises late serializer
  // rejection before the native frame is submitted.
  let high_surrogate = "😀".unsafe_substring(start=0, end=1)
  let invalid = @scene.TextItem(
    id=999999,
    bounds=valid.viewport(),
    text=high_surrogate,
    font_size=FIELD_FONT_SIZE,
    color=@primitives.Color::rgba(255, 255, 255, 255).unwrap(),
    transform=@scene.AffineTransform::identity(),
    opacity=1.0,
    clip_chain_id=None,
  )
  let items : Array[@scene.SceneItem] = valid.items()
  items.push(invalid)
  match
    @scene.SceneSnapshot::new(
      valid.viewport(),
      valid.scale(),
      valid.resources(),
      valid.clip_chains(),
      items,
    ) {
    Ok(value) => value
    Err(_) => fail("scene v1 should retain lone UTF-16 surrogate")
  }
}

///|
test "test-only monotonic clock is nonnegative and monotonic" {
  let first = field_test_monotonic_ns()
  let second = field_test_monotonic_ns()
  assert_true(first >= 0L)
  assert_true(second >= first)
}

///|
test "live field deadline arithmetic is checked and overflow-safe" {
  let max_int64 : Int64 = 9223372036854775807L
  assert_true(field_e2e_elapsed_ns(-1L, 0L) is None)
  assert_true(field_e2e_elapsed_ns(0L, -1L) is None)
  assert_true(field_e2e_elapsed_ns(2L, 1L) is None)
  assert_eq(field_e2e_elapsed_ns(0L, 0L), Some(0L))
  assert_eq(field_e2e_remaining_timeout_ms(0L, 0L), Some(100))
  assert_eq(field_e2e_remaining_timeout_ms(0L, 4999000000L), Some(1))
  assert_eq(field_e2e_remaining_timeout_ms(0L, 4999000001L), Some(1))
  assert_eq(field_e2e_remaining_timeout_ms(0L, 5000000001L), None)
  assert_eq(field_e2e_remaining_timeout_ms(0L, 5000000000L), None)
  assert_eq(
    field_e2e_remaining_timeout_ms(max_int64 - 5000000000L, max_int64 - 1L),
    Some(1),
  )
  assert_eq(
    field_e2e_remaining_timeout_ms(max_int64 - 5000000000L, max_int64),
    None,
  )
  assert_eq(field_e2e_remaining_timeout_ms(max_int64, max_int64), Some(100))
}

///|
/// Live integration coverage is deliberately opt-in: normal native checks do
/// not start a host or attempt to connect to a compositor.
test "Linux field Host.present admission and serializer rejection E2E" {
  if @env.get_env_var("GPUI_FIELD_E2E") == Some("1") {
    let host = field_e2e_required(@native.Host::start())
    assert_true(host.state() == @native.Running)
    field_e2e_required(host.require_capability(@platform.GrayscaleTextFrames))
    let window = field_e2e_required(
      host.create_window(640, 240, "gpui.mbt field present E2E"),
    )

    // Read any initial configure/scale events before constructing field scenes.
    let mut width = 640.0
    let mut height = 240.0
    let mut scale = 1.0
    for event in field_e2e_required(host.dispatch(0)) {
      scale = event.scale()
      match event.kind() {
        @platform.Resized(width=w, height=h) => {
          width = w
          height = h
        }
        _ => ()
      }
    }
    assert_true(width >= 64.0 && height >= 88.0 && scale > 0.0)
    let bounds = match native_field_bounds(width, height) {
      Ok(value) => value
      Err(_) => fail("live window geometry cannot admit the field bounds")
    }
    let original = match make_field("jJ", bounds) {
      Ok(value) => value.with_focus(true).unwrap()
      Err(_) => fail("real sans/Pango field admission failed")
    }
    let original = field_e2e_present_ready(host, window, original)
    // Use the metrics snapshot after the initial readiness submission when
    // constructing the deliberate width+1 stale-viewport control case.
    let (ready_width, ready_height, ready_scale) = field_e2e_required(
      host.window_metrics(window),
    )
    width = ready_width
    height = ready_height
    scale = ready_scale
    let (first_origin, _) = @text_field.scene_text_run_geometry(
      original.measurement(),
    ).unwrap()
    assert_true(first_origin.x() > 0.0)

    // Build a real admitted edit candidate. A one-pixel-stale viewport reaches
    // the real Host.present/native metrics preflight and deterministically
    // reports typed Busy without relying on frame-callback timing.
    let end = change(original, key_event(@primitives.End)).unwrap()
    let selected = change(end, key_event(@primitives.Home, shift=true)).unwrap()
    let candidate = match
      change(selected, @primitives.TextInput(text="ÁA\u{301}")) {
      Ok(value) => value
      Err(_) => fail("real field edit candidate was not admitted")
    }
    let (candidate_origin, _) = @text_field.scene_text_run_geometry(
      candidate.measurement(),
    ).unwrap()
    assert_true(candidate_origin.y() > 0.0)
    let stale_candidate_scene = match
      field_scene(candidate, width + 1.0, height, scale) {
      Ok(value) => value
      Err(_) => fail("stale candidate did not produce a scene snapshot")
    }
    match host.present(window, stale_candidate_scene) {
      Err(error) => {
        assert_true(error.operation() == "present")
        assert_true(error.code() is @diagnostics.Busy)
      }
      Ok(_) => fail("stale viewport candidate was accepted")
    }

    let candidate_scene = match field_scene(candidate, width, height, scale) {
      Ok(value) => value
      Err(_) => fail("admitted candidate did not produce a scene snapshot")
    }

    // A malformed run appended after the valid field reaches the actual
    // Host.present serializer, which must reject the whole candidate before
    // handing it to native submission. Keep the valid field candidate and use
    // it after the first frame's completion is drained.
    let malformed_scene = field_e2e_with_late_malformed_text(candidate_scene)
    match host.present(window, malformed_scene) {
      Err(error) => {
        assert_true(error.operation() == "present")
        assert_true(error.code() is @diagnostics.UnsupportedCapability)
      }
      Ok(_) => fail("malformed late text reached native frame submission")
    }

    field_e2e_drain_frame(host, window)
    let candidate = field_e2e_present_ready(host, window, candidate)
    field_e2e_drain_frame(host, window)
    assert_true(candidate.can_undo())

    // Real control history reaches actual MoonBit serialization/presentation.
    // Navigation after the edit and after undo cannot rewrite either endpoint.
    let navigated = change(candidate, key_event(@primitives.Home)).unwrap()
    let undone = navigated.undo(measure, admit).unwrap()
    assert_true(undone.document() == selected.document())
    assert_true(undone.can_redo())
    let undone = field_e2e_present_ready(host, window, undone)
    field_e2e_drain_frame(host, window)
    let moved = change(undone, key_event(@primitives.End)).unwrap()
    let redone = moved.redo(measure, admit).unwrap()
    assert_true(redone.document() == candidate.document())
    assert_true(redone.can_undo())
    assert_false(redone.can_redo())
    let _redone = field_e2e_present_ready(host, window, redone)
    field_e2e_drain_frame(host, window)
    field_e2e_required(host.destroy_window(window))
    field_e2e_required(host.stop())
  } else {
    println("GPUI_FIELD_E2E status=skipped gate=GPUI_FIELD_E2E=1")
  }
}
