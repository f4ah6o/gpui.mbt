///|
fn field_admission_document(value : String) -> @text.TextDocument {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => abort("valid field admission fixture document rejected")
  }
}

///|
test "scene-run raster admission accepts generic sans Unicode runs" {
  for
    value in [
      "office affine", "日本語かな", "a\u{301}", "a\u{200d}b", "✈︎",
    ] {
    assert_true(
      admit_scene_text_run(field_admission_document(value), 16.0, 256.0, 48.0)
      is Ok(_),
    )
  }
}

///|
test "scene-run raster admission rejects actual generic sans color before crop" {
  assert_true(
    admit_scene_text_run(
      field_admission_document("👩‍💻"),
      16.0,
      0.0,
      0.0,
    )
    is Err(UnsupportedColor),
  )
}

///|
test "scene-run raster admission rejects unknown glyph fallback" {
  assert_true(
    admit_scene_text_run(field_admission_document("\u{378}"), 16.0, 128.0, 48.0)
    is Err(UnsupportedInput),
  )
}

///|
test "scene-run raster admission accepts empty and whitespace without a mask" {
  assert_true(
    admit_scene_text_run(field_admission_document(""), 16.0, 0.0, 0.0) is Ok(_),
  )
  assert_true(
    admit_scene_text_run(field_admission_document(" \t"), 16.0, 64.0, 32.0)
    is Ok(_),
  )
}

///|
test "scene-run raster admission enforces byte font and bounds caps" {
  assert_true(
    admit_scene_text_run(
      field_admission_document("x".repeat(4097)),
      16.0,
      64.0,
      32.0,
    )
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run(
      field_admission_document("界".repeat(1366)),
      16.0,
      64.0,
      32.0,
    )
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run(field_admission_document("x"), 32.01, 64.0, 32.0)
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run(field_admission_document("x"), 16.0, 2048.01, 32.0)
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run(field_admission_document("x"), 16.0, 64.0, 128.01)
    is Err(ResourceLimit),
  )
  assert_true(
    admit_scene_text_run(field_admission_document("x"), 16.0, -1.0, 32.0)
    is Err(InvalidCoordinates),
  )
  assert_true(
    admit_scene_text_run(field_admission_document("x"), 16.0, 64.0, 1.0 / 0.0)
    is Err(InvalidCoordinates),
  )
  assert_true(
    admit_scene_text_run(field_admission_document("x"), 0.0, 64.0, 32.0)
    is Err(InvalidFontSize),
  )
}

///|
test "field admission rejects nul and malformed byte inputs at the native boundary" {
  assert_true(
    admit_scene_text_run(field_admission_document("a\u{0}b"), 16.0, 64.0, 32.0)
    is Err(UnsupportedInput),
  )
}
