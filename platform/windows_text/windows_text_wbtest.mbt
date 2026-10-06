///|
#borrow(output)
extern "C" fn native_text_test_raster(
  output : FixedArray[Double],
  capacity : Int,
) -> Int = "gpui_windows_text_test_raster_v1"

///|
extern "C" fn native_text_test_supported() -> Int = "gpui_windows_text_test_supported_v1"

///|
extern "C" fn native_text_test_color_policy() -> Int = "gpui_windows_text_test_color_policy_v1"

///|
#borrow(output)
extern "C" fn native_text_test_density(
  output : FixedArray[Double],
  capacity : Int,
) -> Int = "gpui_windows_text_test_density_v2"

///|
fn windows_text_test_document(value : String) -> @text.TextDocument {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => abort("Windows text test document rejected")
  }
}

///|
fn windows_text_test_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(rect) => rect
    Err(_) => abort("Windows text test rectangle rejected")
  }
}

///|
fn windows_text_test_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(point) => point
    Err(_) => abort("Windows text test point rejected")
  }
}

///|
test "DirectWrite returns copied cluster-safe geometry on Windows" {
  let document = windows_text_test_document("A😀e\u{301}")
  if native_text_test_supported() == 0 {
    assert_true(measure(document, "Segoe UI", 18.0) is Err(UnsupportedPlatform))
    return
  }
  let measurement = match measure(document, "Segoe UI", 18.0) {
    Ok(value) => value
    Err(_) => fail("DirectWrite measurement")
  }
  assert_eq(measurement.line_count(), 1)
  assert_eq(measurement.unknown_glyph_count(), 0)
  assert_eq(measurement.carets().length(), 5)
  assert_true(measurement.logical_rect().size().width() > 0.0)
  assert_true(measurement.logical_rect().size().height() > 0.0)
  assert_true(measurement.ink_rect().size().height() > 0.0)
  assert_true(measurement.first_line_baseline() > 0.0)
  assert_true(measurement.caret_at(2) is Err(@text_layout.InvalidHitOffset))
  match measurement.caret_at(4) {
    Ok(caret) => assert_false(caret.is_cursor_position())
    Err(_) => fail("combining-mark caret boundary")
  }
  match
    hit_test(document, "Segoe UI", 18.0, windows_text_test_point(12.0, 12.0)) {
    Ok(hit) => {
      assert_true(hit.cluster_start_utf16() <= document.utf16_length())
      assert_true(hit.resolved_utf16_offset() <= document.utf16_length())
    }
    Err(_) => fail("DirectWrite hit test")
  }

  let empty = windows_text_test_document("")
  match measure(empty, "Segoe UI", 18.0) {
    Ok(value) => {
      assert_eq(value.carets().length(), 1)
      assert_eq(value.logical_rect().size().width(), 0.0)
      assert_eq(value.line_count(), 1)
    }
    Err(_) => fail("empty single-line measurement")
  }
  assert_true(measure(document, "   ", 18.0) is Err(InvalidFontFamily))
  assert_true(
    measure(windows_text_test_document("line\nfeed"), "Segoe UI", 18.0)
    is Err(UnsupportedInput),
  )
  let japanese = windows_text_test_document("日本語")
  match measure(japanese, "Segoe UI", 18.0) {
    Ok(value) => {
      assert_eq(value.line_count(), 1)
      assert_true(value.logical_rect().size().width() > 0.0)
    }
    Err(_) => fail("Japanese fallback geometry")
  }
}

///|
test "DirectWrite grayscale qualification has copied top-down partial coverage" {
  if native_text_test_supported() == 0 {
    assert_true(
      admit_scene_text_run_at(
        windows_text_test_document("j"),
        18.0,
        windows_text_test_point(4.0, 4.0),
        windows_text_test_rect(0.0, 0.0, 64.0, 32.0),
      )
      is Err(UnsupportedPlatform),
    )
    return
  }
  let summary = FixedArray::make(9, -1.0)
  summary[8] = 123456789.125
  assert_eq(native_text_test_raster(summary, 8), 0)
  assert_eq(summary[8], 123456789.125)
  let width = summary[0].to_int()
  let height = summary[1].to_int()
  assert_true(width > 0 && height > 0)
  assert_true(summary[2] > 0.0)
  assert_true(summary[3] > 0.0)
  assert_true(summary[4] >= 0.0 && summary[4] < summary[5])
  assert_true(summary[5] < height.to_double())
  assert_true(summary[6] > 0.0 && summary[7] > 0.0)
  assert_true(summary[6] != summary[7])
  assert_true(
    admit_scene_text_run_at(
      windows_text_test_document("j"),
      18.0,
      windows_text_test_point(4.0, 4.0),
      windows_text_test_rect(0.0, 0.0, 64.0, 32.0),
    )
    is Ok(_),
  )
  match
    admit_scene_text_run_at(
      windows_text_test_document("emoji 😀"),
      18.0,
      windows_text_test_point(4.0, 4.0),
      windows_text_test_rect(0.0, 0.0, 128.0, 32.0),
    ) {
    Err(UnsupportedColor | UnsupportedGlyph | UnsupportedRaster) => ()
    Ok(_) => () // This font set may expose the tested scalar as monochrome.
    Err(_) => fail("unexpected color-glyph admission error")
  }
  assert_eq(native_text_test_color_policy(), 1)
  match
    admit_scene_text_run_at(
      windows_text_test_document("日本語"),
      18.0,
      windows_text_test_point(4.0, 4.0),
      windows_text_test_rect(0.0, 0.0, 128.0, 32.0),
    ) {
    Ok(_) => ()
    Err(UnsupportedGlyph | UnsupportedRaster) => ()
    Err(_) => fail("unexpected Japanese fallback raster error")
  }
  assert_true(
    admit_scene_text_run_at(
      windows_text_test_document("j"),
      33.0,
      windows_text_test_point(4.0, 4.0),
      windows_text_test_rect(0.0, 0.0, 64.0, 32.0),
    )
    is Err(InvalidFontSize),
  )
}

///|
test "DirectWrite raster density follows physical pixels per DIP" {
  if native_text_test_supported() == 0 {
    let output = FixedArray::make(33, -1.0)
    assert_eq(native_text_test_density(output, 32), 14)
    return
  }
  let output = FixedArray::make(33, -1.0)
  output[32] = 123456789.125
  assert_eq(native_text_test_density(output, 32), 0)
  assert_eq(output[32], 123456789.125)
  assert_true(output[0] > 0.0 && output[1] > 0.0)
  assert_true(output[2] > output[0])
  assert_true(output[3] >= output[1] * 1.4)
  assert_true(output[4] >= output[0] * 1.4)
  assert_true(output[5] >= output[1] * 1.8)
  assert_true(output[4] - output[0] * 2.0 >= -4.0)
  assert_true(output[4] - output[0] * 2.0 <= 4.0)
  assert_true(output[5] - output[1] * 2.0 >= -4.0)
  assert_true(output[5] - output[1] * 2.0 <= 4.0)
  assert_true(output[4] * output[5] > output[0] * output[1] * 2.0)
  for index in 0..<4 {
    assert_eq(output[6 + index], output[10 + index])
  }
  assert_true(output[14] > 0.0)
  assert_true(output[15] > 0.0)
  assert_true(output[16] > output[14] * 2.0)
  assert_true(output[17] > 0.0)
  assert_true(output[18] > 0.0)
  for index in 19..<23 {
    assert_eq(output[index].to_int(), 15)
  }
  assert_true(output[25] > output[23])
  assert_eq(output[24].to_int(), 7)
  assert_eq(output[26].to_int(), 0)
  // Ink bounds scale with generous hinting tolerance; unlike the padded tile
  // dimensions, these bounds also reveal glyphs clipped by a doubled matrix.
  assert_true(output[29] >= output[27] * 1.4)
  assert_true(output[29] <= output[27] * 3.0)
  assert_true(output[30] >= output[28] * 1.4)
  assert_true(output[30] <= output[28] * 3.0)
  assert_true(output[31] <= 8.0)
}

///|
test "DirectWrite density-aware admission rejects invalid scale" {
  let document = windows_text_test_document("j")
  let origin = windows_text_test_point(0.0, 0.0)
  let clip = windows_text_test_rect(0.0, 0.0, 64.0, 32.0)
  if native_text_test_supported() == 0 {
    assert_true(
      admit_scene_text_run_at_scale(document, 18.0, origin, clip, 2.0)
      is Err(UnsupportedPlatform),
    )
    return
  }
  assert_true(
    admit_scene_text_run_at_scale(document, 18.0, origin, clip, 2.0) is Ok(_),
  )
  assert_true(
    admit_scene_text_run_at_scale(document, 18.0, origin, clip, 0.0)
    is Err(InvalidScale),
  )
  assert_true(
    admit_scene_text_run_at_scale(document, 18.0, origin, clip, 8.1)
    is Err(InvalidScale),
  )
}
