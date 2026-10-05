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
fn field_e2e_drain_frame(host : @native.Host) -> Unit raise {
  let mut completed = false
  let mut attempts = 0
  while attempts < 40 && !completed {
    match host.next_event(timeout_ms=100) {
      Err(error) => fail("\{error.operation()}: \{error.code().label()}")
      Ok(None) => ()
      Ok(Some(event)) =>
        if event.kind() is @platform.FrameCompleted {
          completed = true
        }
    }
    attempts += 1
  }
  assert_true(completed)
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
    let first_scene = match field_scene(original, width, height, scale) {
      Ok(value) => value
      Err(_) => fail("real field did not produce a scene snapshot")
    }
    let (first_origin, _) = @text_field.scene_text_run_geometry(
      original.measurement(),
    ).unwrap()
    assert_true(first_origin.x() > 0.0)
    field_e2e_required(host.present(window, first_scene))

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

    field_e2e_drain_frame(host)
    field_e2e_required(host.present(window, candidate_scene))
    field_e2e_drain_frame(host)
    field_e2e_required(host.destroy_window(window))
    field_e2e_required(host.stop())
  } else {
    println("GPUI_FIELD_E2E status=skipped gate=GPUI_FIELD_E2E=1")
  }
}
