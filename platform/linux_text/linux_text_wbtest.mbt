///|
#borrow(text, family, output)
extern "C" fn native_test_shape(
  abi : Int,
  text : Bytes,
  text_length : Int,
  family : Bytes,
  family_length : Int,
  font_size_px : Double,
  output : FixedArray[Double],
  output_capacity : Int,
) -> Int = "gpui_linux_text_test_shape_v1"

///|
#borrow(output)
extern "C" fn native_test_lifecycle(
  cycles : Int,
  output : FixedArray[Int],
  output_capacity : Int,
) -> Int = "gpui_linux_text_test_lifecycle_v1"

///|
fn linux_text_document(value : String) -> @text.TextDocument {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => abort("valid fixture document rejected")
  }
}

///|
fn linux_text_measure(
  value : String,
  family : String,
) -> @text_layout.TextMeasurement {
  match measure(linux_text_document(value), family, 16.0) {
    Ok(measurement) => measurement
    Err(_) => abort("fixture measurement failed")
  }
}

///|
fn shape_observation(value : String, family : String) -> FixedArray[Double] {
  let text = @utf8.encode(value)
  let family_bytes = @utf8.encode(family)
  let output = FixedArray::make(7, 0.0)
  output[6] = CANARY
  let status = native_test_shape(
    ABI_VERSION,
    text,
    text.length(),
    family_bytes,
    family_bytes.length(),
    16.0,
    output,
    6,
  )
  if status != 0 {
    abort("native shape observation failed")
  }
  if output[6] != CANARY {
    abort("native shape observation exceeded its capacity")
  }
  output
}

///|
test "headless runtime and PangoFT2 metrics are available" {
  assert_eq(@env.get_env_var("DISPLAY"), None)
  assert_eq(@env.get_env_var("WAYLAND_DISPLAY"), None)
  let measurement = linux_text_measure("A", "DejaVu Sans")
  assert_eq(measurement.line_count(), 1)
  assert_true(measurement.logical_rect().size().width() > 0.0)
  assert_true(measurement.first_line_baseline() > 0.0)
  assert_eq(measurement.unknown_glyph_count(), 0)
}

///|
test "Pango measures a Latin ligature in DejaVu Sans" {
  let measurement = linux_text_measure("office affine", "DejaVu Sans")
  assert_eq(measurement.unknown_glyph_count(), 0)
  let shape = shape_observation("office affine", "DejaVu Sans")
  assert_eq(shape[0].to_int(), 13)
  assert_true(shape[1] < shape[0])
  assert_true(shape[2] < shape[0])
  assert_eq(shape[4].to_int(), 0)
}

///|
test "Japanese font coverage and mixed-script fallback use declared faces" {
  let japanese = linux_text_measure("日本語かな", "Noto Sans CJK JP")
  assert_eq(japanese.unknown_glyph_count(), 0)
  let japanese_shape = shape_observation("日本語かな", "Noto Sans CJK JP")
  assert_eq(japanese_shape[3].to_int() > 0, true)
  assert_eq(japanese_shape[4].to_int(), 0)

  let mixed = linux_text_measure("A日本B", "DejaVu Sans")
  assert_eq(mixed.unknown_glyph_count(), 0)
  let fallback_shape = shape_observation("A日本B", "DejaVu Sans")
  assert_true(fallback_shape[3] >= 2.0)
  assert_true(fallback_shape[4] >= 1.0)
}

///|
test "combining and ZWJ scalar boundaries preserve Pango cursor-stop flags" {
  let combining = linux_text_measure("a\u{301}", "DejaVu Sans")
  assert_eq(combining.carets().length(), 3)
  assert_eq(combining.carets()[1].utf16_offset(), 1)
  let combining_caret = match combining.caret_at(1) {
    Ok(caret) => caret
    Err(_) => abort("combining scalar boundary is missing from the caret table")
  }
  assert_false(combining_caret.is_cursor_position())
  let combining_shape = shape_observation("a\u{301}", "DejaVu Sans")
  assert_eq(combining_shape[0].to_int(), 2)
  assert_eq(combining_shape[1].to_int(), 1)
  assert_eq(combining_shape[2].to_int(), 1)

  let family_emoji = "👨‍👩‍👧‍👦"
  let emoji = linux_text_measure(family_emoji, "Noto Color Emoji")
  assert_eq(emoji.unknown_glyph_count(), 0)
  let emoji_shape = shape_observation(family_emoji, "Noto Color Emoji")
  assert_eq(emoji_shape[0].to_int(), 7)
  assert_eq(emoji_shape[1].to_int(), 1)
  assert_eq(emoji_shape[2].to_int(), 1)
  for offset in [2, 3, 5, 6, 8, 9] {
    assert_false(emoji.caret_at(offset).unwrap().is_cursor_position())
  }
  assert_true(emoji.caret_at(0).unwrap().is_cursor_position())
  assert_true(emoji.caret_at(11).unwrap().is_cursor_position())
}

///|
test "bidi carets retain distinct strong and weak positions" {
  let measurement = linux_text_measure("abc אבג 123", "DejaVu Sans")
  let caret = measurement.caret_at(4).unwrap()
  assert_true(caret.is_cursor_position())
  assert_true(caret.strong().left() != caret.weak().left())
}

///|
test "Pango XY hit testing preserves scalar trailing for supplementary text" {
  let document = linux_text_document("A😀B")
  let measurement = match measure(document, "DejaVu Sans", 16.0) {
    Ok(value) => value
    Err(_) => abort("supplementary fixture measurement failed")
  }
  let start_x = measurement.caret_at(1).unwrap().strong().left()
  let end_x = measurement.caret_at(3).unwrap().strong().left()
  let x = start_x + (end_x - start_x) * 0.75
  let y = measurement.first_line_baseline() / 2.0
  let point = match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("finite Pango point rejected")
  }
  let hit = match hit_test(document, "DejaVu Sans", 16.0, point) {
    Ok(value) => value
    Err(_) => abort("supplementary XY hit failed")
  }
  assert_true(hit.inside())
  assert_eq(hit.cluster_start_utf16(), 1)
  assert_eq(hit.trailing_scalars(), 1)
  assert_eq(hit.resolved_utf16_offset(), 3)
  assert_true(hit.resolved_is_cursor_position())

  let outside_point = match @primitives.Point::new(10000.0, 10000.0) {
    Ok(value) => value
    Err(_) => abort("finite outside point rejected")
  }
  let outside = hit_test(document, "DejaVu Sans", 16.0, outside_point).unwrap()
  assert_false(outside.inside())
}

///|
test "empty, multiline, missing glyph, and font input behavior stay observable" {
  let empty = linux_text_measure("", "DejaVu Sans")
  assert_eq(empty.line_count(), 1)
  assert_eq(empty.logical_rect().size().width(), 0.0)
  assert_eq(empty.carets().length(), 1)
  assert_eq(linux_text_measure("A\nB", "DejaVu Sans").line_count(), 2)

  let missing = linux_text_measure("\u{378}", "DejaVu Sans")
  assert_true(missing.unknown_glyph_count() > 0)
  assert_true(
    measure(linux_text_document("A\u{0}B"), "DejaVu Sans", 16.0)
    is Err(UnsupportedInput),
  )
  assert_true(
    measure(linux_text_document("A"), "", 16.0) is Err(InvalidFontFamily),
  )
  assert_true(
    measure(linux_text_document("A"), "DejaVu Sans", 0.0)
    is Err(InvalidFontSize),
  )
  assert_true(
    measure(linux_text_document("A"), "DejaVu Sans", 513.0)
    is Err(InvalidFontSize),
  )
  let huge_point = match @primitives.Point::new(1.0e308, 0.0) {
    Ok(value) => value
    Err(_) => abort("finite large point rejected by primitives")
  }
  assert_true(
    hit_test(linux_text_document("A"), "DejaVu Sans", 16.0, huge_point)
    is Err(InvalidCoordinates),
  )
}

///|
test "native boundary validates malformed input sizes and capacities without partial writes" {
  let family = @utf8.encode("DejaVu Sans")
  let text = @utf8.encode("A")
  let too_small = FixedArray::make(33, CANARY)
  assert_eq(
    native_measure(
      ABI_VERSION,
      text,
      text.length(),
      family,
      family.length(),
      16.0,
      too_small,
      31,
    ),
    4,
  )
  for value in too_small {
    assert_eq(value, CANARY)
  }

  let nul_text = Bytes::makei(3, i => {
    match i {
      0 => b'A'
      1 => b'\x00'
      _ => b'B'
    }
  })
  let output = FixedArray::make(64, CANARY)
  assert_eq(
    native_measure(
      ABI_VERSION,
      nul_text,
      3,
      family,
      family.length(),
      16.0,
      output,
      64,
    ),
    2,
  )
  assert_eq(output[0], CANARY)

  let invalid_utf8 = Bytes::makei(4, i => {
    match i {
      0 => b'\xF0'
      1 => b'('
      2 => b'\x8C'
      _ => b'('
    }
  })
  assert_eq(
    native_measure(
      ABI_VERSION,
      invalid_utf8,
      4,
      family,
      family.length(),
      16.0,
      output,
      64,
    ),
    2,
  )
  assert_eq(output[0], CANARY)
  assert_eq(
    native_measure(
      ABI_VERSION,
      text,
      16385,
      family,
      family.length(),
      16.0,
      output,
      64,
    ),
    3,
  )
  assert_eq(
    native_measure(
      ABI_VERSION,
      text,
      1,
      family,
      family.length(),
      513.0,
      output,
      64,
    ),
    1,
  )

  let tiny_hit = FixedArray::make(6, CANARY)
  assert_eq(
    native_hit_test(
      ABI_VERSION,
      text,
      1,
      family,
      family.length(),
      16.0,
      0.0,
      0.0,
      tiny_hit,
      4,
    ),
    4,
  )
  for value in tiny_hit {
    assert_eq(value, CANARY)
  }
}

///|
test "repeated synchronous layouts finalize all native objects" {
  let counts = FixedArray::make(3, 0)
  assert_eq(native_test_lifecycle(64, counts, 3), 0)
  assert_eq(counts[0], 64)
  assert_eq(counts[1], 64)
  assert_eq(counts[2], 64)
}
