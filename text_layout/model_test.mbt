///|
fn test_document(value : String) -> @text.TextDocument {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => abort("valid test text rejected")
  }
}

///|
fn test_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(rect) => rect
    Err(_) => abort("valid test rectangle rejected")
  }
}

///|
fn test_caret(
  offset : Int,
  cursor : Bool,
  x : Double,
  y : Double,
) -> @text_layout.CaretGeometry {
  match
    @text_layout.CaretGeometry::new(
      offset,
      cursor,
      test_rect(x, y, 0.0, 12.0),
      test_rect(x + 1.0, y, 0.0, 12.0),
    ) {
    Ok(caret) => caret
    Err(_) => abort("valid test caret rejected")
  }
}

///|
fn test_measurement(
  document : @text.TextDocument,
  carets : Array[@text_layout.CaretGeometry],
) -> Result[@text_layout.TextMeasurement, @text_layout.TextLayoutError] {
  @text_layout.TextMeasurement::new(
    document,
    test_rect(0.0, 0.0, 20.0, 24.0),
    test_rect(-2.0, -1.0, 24.0, 26.0),
    18.0,
    1,
    0,
    carets,
  )
}

///|
test "measurement requires exactly the document scalar boundaries" {
  let document = test_document("a\u{301}😀")
  let valid = [
    test_caret(0, true, 10.0, 0.0),
    test_caret(1, false, -4.0, 0.0),
    test_caret(2, false, 2.0, 0.0),
    test_caret(4, true, -8.0, 0.0),
  ]
  assert_true(test_measurement(document, valid) is Ok(_))
  assert_eq(
    test_measurement(document, valid)
    .unwrap()
    .caret_at(1)
    .unwrap()
    .is_cursor_position(),
    false,
  )
  assert_true(
    test_measurement(document, valid).unwrap().caret_at(3)
    is Err(@text_layout.InvalidHitOffset),
  )
  assert_true(
    test_measurement(document, valid).unwrap().caret_at(5)
    is Err(@text_layout.InvalidHitOffset),
  )

  assert_true(
    test_measurement(document, [test_caret(0, true, 0.0, 0.0)])
    is Err(@text_layout.MissingCaret),
  )
  assert_true(
    test_measurement(document, [
      test_caret(0, true, 0.0, 0.0),
      test_caret(1, false, 0.0, 0.0),
      test_caret(2, false, 0.0, 0.0),
      test_caret(4, true, 0.0, 0.0),
      test_caret(5, true, 0.0, 0.0),
    ])
    is Err(@text_layout.ExtraCaret),
  )
  assert_true(
    test_measurement(document, [
      test_caret(0, true, 0.0, 0.0),
      test_caret(1, false, 0.0, 0.0),
      test_caret(1, false, 0.0, 0.0),
      test_caret(4, true, 0.0, 0.0),
    ])
    is Err(@text_layout.DuplicateCaret),
  )
  assert_true(
    test_measurement(document, [
      test_caret(0, true, 0.0, 0.0),
      test_caret(2, false, 0.0, 0.0),
      test_caret(1, false, 0.0, 0.0),
      test_caret(4, true, 0.0, 0.0),
    ])
    is Err(@text_layout.MissingCaret),
  )
  assert_true(
    test_measurement(document, [
      test_caret(0, true, 0.0, 0.0),
      test_caret(1, false, 0.0, 0.0),
      test_caret(3, false, 0.0, 0.0),
      test_caret(4, true, 0.0, 0.0),
    ])
    is Err(@text_layout.InvalidCaretOffset),
  )
}

///|
test "measurement validates finite metrics and preserves bidi and ink overhang" {
  let document = test_document("אבA")
  let carets = [
    test_caret(0, true, 18.0, 0.0),
    test_caret(1, true, 2.0, 0.0),
    test_caret(2, true, 30.0, 0.0),
    test_caret(3, true, 5.0, 0.0),
  ]
  let logical = test_rect(0.0, 0.0, 40.0, 24.0)
  let ink = test_rect(-3.0, -2.0, 44.0, 28.0)
  let result = @text_layout.TextMeasurement::new(
    document, logical, ink, 18.0, 1, 0, carets,
  )
  assert_true(result is Ok(_))
  let value = result.unwrap()
  assert_eq(value.ink_rect().left(), -3.0)
  assert_eq(value.caret_at(0).unwrap().strong().left(), 18.0)
  assert_eq(value.caret_at(1).unwrap().weak().left(), 3.0)
  assert_eq(value.caret_at(2).unwrap().strong().left(), 30.0)
  assert_eq(value.caret_at(1).unwrap().is_cursor_position(), true)

  assert_true(
    @text_layout.TextMeasurement::new(
      document, logical, ink, @double.not_a_number, 1, 0, carets,
    )
    is Err(@text_layout.InvalidMetrics),
  )
  assert_true(
    @text_layout.TextMeasurement::new(
      document, logical, ink, -1.0, 1, 0, carets,
    )
    is Err(@text_layout.InvalidBaseline),
  )
  assert_true(
    @text_layout.TextMeasurement::new(document, logical, ink, 1.0, 0, 0, carets)
    is Err(@text_layout.InvalidLineCount),
  )
  assert_true(
    @text_layout.TextMeasurement::new(
      document, logical, ink, 1.0, 1, -1, carets,
    )
    is Err(@text_layout.InvalidUnknownGlyphCount),
  )
}

///|
test "empty measurement has one end caret and arrays are defensively copied" {
  let document = test_document("")
  let input = [test_caret(0, true, 0.0, 0.0)]
  let measurement = test_measurement(document, input).unwrap()
  input[0] = test_caret(0, false, 99.0, 0.0)
  assert_eq(measurement.carets()[0].is_cursor_position(), true)
  let returned = measurement.carets()
  returned[0] = test_caret(0, false, 99.0, 0.0)
  assert_eq(measurement.carets()[0].strong().left(), 0.0)
  assert_eq(measurement.carets()[0].is_cursor_position(), true)
}

///|
test "text hit trailing counts scalars rather than UTF-8 bytes or UTF-16 units" {
  let document = test_document("A😀B")
  let emoji_hit = @text_layout.TextHit::new(document, 1, 1, 3, true, false).unwrap()
  assert_eq(emoji_hit.document().text(), document.text())
  assert_eq(emoji_hit.cluster_start_utf16(), 1)
  assert_eq(emoji_hit.trailing_scalars(), 1)
  assert_eq(emoji_hit.resolved_utf16_offset(), 3)
  assert_true(emoji_hit.inside())
  assert_false(emoji_hit.resolved_is_cursor_position())

  let outside = @text_layout.TextHit::new(document, 3, 1, 4, false, true).unwrap()
  assert_false(outside.inside())
  assert_eq(outside.resolved_utf16_offset(), 4)
  assert_true(
    @text_layout.TextHit::new(document, 1, 0, 3, true, true)
    is Err(@text_layout.HitOffsetMismatch),
  )
  assert_true(
    @text_layout.TextHit::new(document, 1, -1, 1, true, true)
    is Err(@text_layout.InvalidTrailingScalarCount),
  )
  assert_true(
    @text_layout.TextHit::new(document, 2, 0, 2, true, true)
    is Err(@text_layout.InvalidHitOffset),
  )
  assert_true(
    @text_layout.TextHit::new(document, 4, 1, 4, false, true)
    is Err(@text_layout.InvalidTrailingScalarCount),
  )
}
