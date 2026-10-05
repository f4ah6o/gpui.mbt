///|
fn origin_admission_document(value : String) -> @text.TextDocument {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => abort("valid origin admission fixture document rejected")
  }
}

///|
fn origin_admission_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(point) => point
    Err(_) => abort("finite origin admission point rejected")
  }
}

///|
fn origin_admission_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(bounds) => bounds
    Err(_) => abort("valid origin admission bounds rejected")
  }
}

///|
test "origin-aware scene-run admission separates text origin and clip" {
  let document = origin_admission_document("jA\u{301}")
  assert_true(
    admit_scene_text_run_at(
      document,
      16.0,
      origin_admission_point(1.25, 2.5),
      origin_admission_rect(0.0, 0.0, 256.0, 48.0),
    )
    is Ok(_),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("H"),
      16.0,
      origin_admission_point(2.25, 3.5),
      origin_admission_rect(0.0, 0.0, 96.0, 40.0),
    )
    is Ok(_),
  )
  // A fully clipped ordinary run still runs native admission and succeeds
  // without retaining a temporary mask.
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("A"),
      16.0,
      origin_admission_point(1000000.0, -1000000.0),
      origin_admission_rect(0.0, 0.0, 64.0, 32.0),
    )
    is Ok(_),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document(""),
      16.0,
      origin_admission_point(1000000.0, -1000000.0),
      origin_admission_rect(0.0, 0.0, 0.0, 0.0),
    )
    is Ok(_),
  )
}

///|
test "origin-aware admission preflights color and unsupported text offscreen" {
  let far_origin = origin_admission_point(1000000.0, -1000000.0)
  let empty_clip = origin_admission_rect(0.0, 0.0, 0.0, 0.0)
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("👩‍💻"),
      16.0,
      far_origin,
      empty_clip,
    )
    is Err(UnsupportedColor),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("\u{378}"),
      16.0,
      far_origin,
      empty_clip,
    )
    is Err(UnsupportedInput),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("a\u{0}b"),
      16.0,
      far_origin,
      empty_clip,
    )
    is Err(UnsupportedInput),
  )
}

///|
test "origin-aware admission enforces scene caps and checked coordinates" {
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("x".repeat(4097)),
      16.0,
      origin_admission_point(0.0, 0.0),
      origin_admission_rect(0.0, 0.0, 64.0, 32.0),
    )
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("x"),
      32.01,
      origin_admission_point(0.0, 0.0),
      origin_admission_rect(0.0, 0.0, 64.0, 32.0),
    )
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("x"),
      16.0,
      origin_admission_point(0.0, 0.0),
      origin_admission_rect(0.0, 0.0, 2048.01, 32.0),
    )
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("x"),
      16.0,
      origin_admission_point(0.0, 0.0),
      origin_admission_rect(0.0, 0.0, 64.0, 128.01),
    )
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("x"),
      16.0,
      origin_admission_point(1.0e308, 0.0),
      origin_admission_rect(0.0, 0.0, 64.0, 32.0),
    )
    is Err(InvalidCoordinates),
  )
  assert_true(
    admit_scene_text_run_at(
      origin_admission_document("x"),
      0.0,
      origin_admission_point(0.0, 0.0),
      origin_admission_rect(0.0, 0.0, 64.0, 32.0),
    )
    is Err(InvalidFontSize),
  )
}
