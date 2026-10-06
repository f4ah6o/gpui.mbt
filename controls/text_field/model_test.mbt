///|
fn field_test_document(text : String) -> @text.TextDocument {
  match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => abort("test text should be valid")
  }
}

///|
fn field_test_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("test rectangle should be valid")
  }
}

///|
fn field_test_offsets(document : @text.TextDocument) -> Array[Int] {
  let offsets = [0]
  let mut current = 0
  for scalar in document.text().iter() {
    current += if scalar.to_int() > 0xFFFF { 2 } else { 1 }
    offsets.push(current)
  }
  offsets
}

///|
/// A small scripted layout fixture. These cursor flags are observations for
/// the named sample strings only, not a Unicode segmentation implementation.
fn field_test_cursor_stop(text : String, offset : Int) -> Bool {
  match text {
    "a\u{301}b" => offset != 1
    "a\u{301}" => offset == 0 || offset == 2
    "👩\u{200D}👩" => offset == 0 || offset == 5
    "✈\u{FE0F}" => offset == 0 || offset == 2
    "a👩\u{200D}👩" => offset == 0 || offset == 1 || offset == 6
    _ => true
  }
}

///|
fn field_test_measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, @text_field.TextFieldError] {
  let offsets = field_test_offsets(document)
  let carets = []
  for i = 0; i < offsets.length(); i = i + 1 {
    let x = i.to_double() * 8.0
    let offset = offsets[i]
    let caret = match
      @text_layout.CaretGeometry::new(
        offset,
        field_test_cursor_stop(document.text(), offset),
        field_test_rect(x, 0.0, 0.0, 16.0),
        field_test_rect(x, 0.0, 0.0, 16.0),
      ) {
      Ok(value) => value
      Err(_) => return Err(@text_field.UnsupportedLayout)
    }
    carets.push(caret)
  }
  match
    @text_layout.TextMeasurement::new(
      document,
      field_test_rect(0.0, 0.0, (offsets.length() - 1).to_double() * 8.0, 20.0),
      field_test_rect(0.0, 0.0, (offsets.length() - 1).to_double() * 8.0, 20.0),
      14.0,
      1,
      0,
      carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.UnsupportedLayout)
  }
}

///|
fn field_test_measure_with_ink(
  document : @text.TextDocument,
  ink : @primitives.Rect,
) -> @text_layout.TextMeasurement {
  let base = field_test_measure(document).unwrap()
  @text_layout.TextMeasurement::new(
    document,
    base.logical_rect(),
    ink,
    base.first_line_baseline(),
    base.line_count(),
    base.unknown_glyph_count(),
    base.carets(),
  ).unwrap()
}

///|
fn field_test_admit(
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @text_field.TextFieldError] {
  if measurement.document() == document {
    Ok(())
  } else {
    Err(@text_field.AdmissionFailed)
  }
}

///|
fn field_test_hit(
  document : @text.TextDocument,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, @text_field.TextFieldError] {
  let offsets = field_test_offsets(document)
  let mut nearest_index = 0
  let mut nearest_x = 0.0
  let mut nearest_distance = 1.0e300
  for i = 0; i < offsets.length(); i = i + 1 {
    let x = i.to_double() * 8.0
    let distance = if x >= point.x() { x - point.x() } else { point.x() - x }
    if distance < nearest_distance {
      nearest_index = i
      nearest_x = x
      nearest_distance = distance
    }
  }
  let _ = nearest_x
  let offset = offsets[nearest_index]
  match @text_layout.TextHit::new(document, offset, 0, offset, true, true) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.HitTestFailed)
  }
}

///|
fn field_test_non_cursor_hit(
  document : @text.TextDocument,
  _point : @primitives.Point,
) -> Result[@text_layout.TextHit, @text_field.TextFieldError] {
  match @text_layout.TextHit::new(document, 1, 0, 1, true, false) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.HitTestFailed)
  }
}

///|
fn field_test_create(
  text : String,
  bounds : @primitives.Rect,
) -> @text_field.TextField raise {
  let document = field_test_document(text)
  let test_bounds = if bounds.size().height() < 28.0 {
    field_test_rect(bounds.left(), bounds.top(), bounds.size().width(), 28.0)
  } else {
    bounds
  }
  match
    @text_field.TextField::new(
      17UL, test_bounds, 16.0, document, field_test_measure, field_test_admit,
    ) {
    Ok(value) => value
    Err(_) => fail("valid test field should construct")
  }
}

///|
fn field_test_event(
  field : @text_field.TextField,
  event : @primitives.InputEvent,
) -> (@text_field.TextField, @text_field.TextFieldAction?) raise {
  match
    field.handle_input(
      event, field_test_measure, field_test_admit, field_test_hit,
    ) {
    Ok(value) => value
    Err(_) => fail("valid test event should be handled")
  }
}

///|
fn field_test_key(
  field : @text_field.TextField,
  key : @primitives.Key,
  modifiers : @primitives.Modifiers,
) -> (@text_field.TextField, @text_field.TextFieldAction?) raise {
  field_test_event(
    field,
    @primitives.KeyPressed(key~, modifiers~, repeat=false),
  )
}

///|
fn field_test_text(
  field : @text_field.TextField,
  text : String,
) -> (@text_field.TextField, @text_field.TextFieldAction?) raise {
  field_test_event(field, @primitives.TextInput(text~))
}

///|
fn field_test_focused(
  field : @text_field.TextField,
) -> @text_field.TextField raise {
  match field.with_focus(true) {
    Ok(value) => value
    Err(_) => fail("field focus should change")
  }
}

///|
fn field_test_selection(
  field : @text_field.TextField,
  anchor : Int,
  head : Int,
) -> @text_field.TextField {
  let document = field
    .document()
    .with_selection(@text.TextSelection::new(anchor, head).unwrap())
    .unwrap()
  let measurement = field_test_measure(document).unwrap()
  let rebuilt = @text_field.TextField::new(
    field.id(),
    field.bounds(),
    field.font_size(),
    document,
    _ => Ok(measurement),
    field_test_admit,
  ).unwrap()
  if field.is_focused() {
    rebuilt.with_focus(true).unwrap()
  } else {
    rebuilt
  }
}

///|
test "only TextInput inserts and Unicode sequences pass without normalization" {
  let unfocused = field_test_create("", field_test_rect(0.0, 0.0, 120.0, 28.0))
  let (still_unfocused, _) = field_test_text(unfocused, "ignored")
  assert_eq(still_unfocused.document().text(), "")
  let empty = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 120.0, 28.0)),
  )
  let (after_key, _) = field_test_key(
    empty,
    @primitives.Character("q"),
    @primitives.Modifiers::none(),
  )
  assert_eq(after_key.document().text(), "")
  let alt = @primitives.Modifiers::new(
    shift=false,
    control=false,
    alt=true,
    meta=false,
  )
  let (after_alt_key, _) = field_test_key(
    after_key,
    @primitives.Character("x"),
    alt,
  )
  assert_eq(after_alt_key.document().text(), "")
  let raw = "😀a\u{301}\u{200D}\u{FE0F}✈\u{FE0F}"
  let (after_text, _) = field_test_text(after_key, raw)
  assert_eq(after_text.document().text(), raw)
  assert_eq(
    after_text.document().utf8_length().unwrap(),
    @utf8.encode(raw).length(),
  )
  assert_eq(after_text.revision(), empty.revision() + 1)
}

///|
test "movement and deletion follow honest measurement cursor stops" {
  let combining = field_test_focused(
    field_test_selection(
      field_test_create("a\u{301}b", field_test_rect(0.0, 0.0, 80.0, 24.0)),
      3,
      3,
    ),
  )
  let (left, _) = field_test_key(
    combining,
    @primitives.ArrowLeft,
    @primitives.Modifiers::none(),
  )
  assert_eq(left.selection().head(), 2)
  let (left_again, _) = field_test_key(
    left,
    @primitives.ArrowLeft,
    @primitives.Modifiers::none(),
  )
  assert_eq(left_again.selection().head(), 0)

  let cluster = field_test_focused(
    field_test_selection(
      field_test_create("a\u{301}", field_test_rect(0.0, 0.0, 80.0, 24.0)),
      2,
      2,
    ),
  )
  let (deleted_cluster, _) = field_test_key(
    cluster,
    @primitives.Backspace,
    @primitives.Modifiers::none(),
  )
  assert_eq(deleted_cluster.document().text(), "")

  let zwj = field_test_focused(
    field_test_selection(
      field_test_create(
        "👩\u{200D}👩",
        field_test_rect(0.0, 0.0, 80.0, 24.0),
      ),
      5,
      5,
    ),
  )
  let (deleted_zwj_cluster, _) = field_test_key(
    zwj,
    @primitives.Backspace,
    @primitives.Modifiers::none(),
  )
  assert_eq(deleted_zwj_cluster.document().text(), "")

  let variation = field_test_focused(
    field_test_selection(
      field_test_create("✈\u{FE0F}", field_test_rect(0.0, 0.0, 80.0, 24.0)),
      2,
      2,
    ),
  )
  let (deleted_variation_cluster, _) = field_test_key(
    variation,
    @primitives.Backspace,
    @primitives.Modifiers::none(),
  )
  assert_eq(deleted_variation_cluster.document().text(), "")
}

///|
test "joined cluster replacement collapses at the next measured stop" {
  let original = field_test_focused(
    field_test_create("👩👩", field_test_rect(0.0, 0.0, 80.0, 24.0)),
  )
  let at_middle = field_test_selection(original, 2, 2)
  let (edited, _) = field_test_text(at_middle, "\u{200D}")
  assert_eq(edited.document().text(), "👩\u{200D}👩")
  assert_eq(edited.selection().head(), 5)
  assert_true(edited.measurement().document() == edited.document())
}

///|
test "selection direction, collapse, Shift extension, Home and End are stable" {
  let base = field_test_focused(
    field_test_create("abcd", field_test_rect(0.0, 0.0, 100.0, 24.0)),
  )
  let reverse = field_test_selection(base, 3, 1)
  let (left, _) = field_test_key(
    reverse,
    @primitives.ArrowLeft,
    @primitives.Modifiers::none(),
  )
  assert_true(left.selection() == @text.TextSelection::new(1, 1).unwrap())
  let (right, _) = field_test_key(
    reverse,
    @primitives.ArrowRight,
    @primitives.Modifiers::none(),
  )
  assert_true(right.selection() == @text.TextSelection::new(3, 3).unwrap())
  let shift = @primitives.Modifiers::new(
    shift=true,
    control=false,
    alt=false,
    meta=false,
  )
  let (extended, _) = field_test_key(reverse, @primitives.ArrowLeft, shift)
  assert_true(extended.selection() == @text.TextSelection::new(3, 0).unwrap())
  let (home, _) = field_test_key(
    reverse,
    @primitives.Home,
    @primitives.Modifiers::none(),
  )
  assert_true(home.selection() == @text.TextSelection::new(0, 0).unwrap())
  let (end, _) = field_test_key(home, @primitives.End, shift)
  assert_true(end.selection() == @text.TextSelection::new(0, 4).unwrap())
}

///|
test "whole input is rejected for controls malformed UTF-16 and byte caps" {
  let original = field_test_focused(
    field_test_create("ok", field_test_rect(0.0, 0.0, 100.0, 24.0)),
  )
  for
    forbidden in [
      "\n", "\r", "\t", "\u{0000}", "\u{0085}", "\u{2028}", "\u{2029}",
    ] {
    assert_true(
      original.handle_input(
        @primitives.TextInput(text="safe" + forbidden + "suffix"),
        field_test_measure,
        field_test_admit,
        field_test_hit,
      )
      is Err(@text_field.ForbiddenInput),
    )
  }
  let broken = "😀".unsafe_substring(start=0, end=1)
  assert_true(
    original.handle_input(
      @primitives.TextInput(text=broken),
      field_test_measure,
      field_test_admit,
      field_test_hit,
    )
    is Err(@text_field.MalformedText),
  )
  assert_true(
    original.handle_input(
      @primitives.TextInput(text="x".repeat(4097)),
      field_test_measure,
      field_test_admit,
      field_test_hit,
    )
    is Err(@text_field.TextTooLarge),
  )
  assert_eq(original.document().text(), "ok")
  assert_eq(original.revision(), 1)
}

///|
test "single-line LTR and strong-weak geometry admission fails closed" {
  let document = field_test_document("ab")
  let normal = field_test_measure(document).unwrap()
  let field = @text_field.TextField::new(
    1UL,
    field_test_rect(0.0, 0.0, 80.0, 28.0),
    16.0,
    document,
    _ => Ok(normal),
    (_, _) => Ok(()),
  ).unwrap()
  let bad_order = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 16.0, 20.0),
    field_test_rect(0.0, 0.0, 16.0, 20.0),
    14.0,
    1,
    0,
    [
      @text_layout.CaretGeometry::new(
        0,
        true,
        field_test_rect(16.0, 0.0, 0.0, 16.0),
        field_test_rect(16.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        1,
        true,
        field_test_rect(8.0, 0.0, 0.0, 16.0),
        field_test_rect(8.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        2,
        true,
        field_test_rect(0.0, 0.0, 0.0, 16.0),
        field_test_rect(0.0, 0.0, 0.0, 16.0),
      ).unwrap(),
    ],
  ).unwrap()
  let bad_weak = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 16.0, 20.0),
    field_test_rect(0.0, 0.0, 16.0, 20.0),
    14.0,
    1,
    0,
    [
      @text_layout.CaretGeometry::new(
        0,
        true,
        field_test_rect(0.0, 0.0, 0.0, 16.0),
        field_test_rect(1.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        1,
        true,
        field_test_rect(8.0, 0.0, 0.0, 16.0),
        field_test_rect(8.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        2,
        true,
        field_test_rect(16.0, 0.0, 0.0, 16.0),
        field_test_rect(16.0, 0.0, 0.0, 16.0),
      ).unwrap(),
    ],
  ).unwrap()
  assert_true(
    @text_field.TextField::new(
      2UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(bad_order),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )
  assert_true(
    @text_field.TextField::new(
      3UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(bad_weak),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )
  let multiline = @text_layout.TextMeasurement::new(
    document,
    normal.logical_rect(),
    normal.ink_rect(),
    normal.first_line_baseline(),
    2,
    0,
    normal.carets(),
  ).unwrap()
  assert_true(
    @text_field.TextField::new(
      4UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(multiline),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )
  let far_caret = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 16.0, 20.0),
    field_test_rect(0.0, 0.0, 16.0, 20.0),
    14.0,
    1,
    0,
    [
      @text_layout.CaretGeometry::new(
        0,
        true,
        field_test_rect(0.0, 0.0, 0.0, 16.0),
        field_test_rect(0.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        1,
        true,
        field_test_rect(8.0, 0.0, 0.0, 16.0),
        field_test_rect(8.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        2,
        true,
        field_test_rect(3000.0, 0.0, 0.0, 16.0),
        field_test_rect(3000.0, 0.0, 0.0, 16.0),
      ).unwrap(),
    ],
  ).unwrap()
  assert_true(
    @text_field.TextField::new(
      5UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(far_caret),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )
  let out_of_line_x = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 16.0, 20.0),
    field_test_rect(-2.0, -2.0, 64.0, 24.0),
    14.0,
    1,
    0,
    [
      @text_layout.CaretGeometry::new(
        0,
        true,
        field_test_rect(0.0, 0.0, 0.0, 16.0),
        field_test_rect(0.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        1,
        true,
        field_test_rect(8.0, 0.0, 0.0, 16.0),
        field_test_rect(8.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        2,
        true,
        field_test_rect(20.0, 0.0, 0.0, 16.0),
        field_test_rect(20.0, 0.0, 0.0, 16.0),
      ).unwrap(),
    ],
  ).unwrap()
  assert_true(
    @text_field.TextField::new(
      13UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(out_of_line_x),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )
  // Negative ink may enlarge coverage, but an out-of-line caret cannot be
  // admitted merely because that enlarged rectangle contains it.
  assert_true(
    @text_field.scene_text_run_geometry(out_of_line_x)
    is Err(@text_field.GeometryFailure),
  )
  let mixed_vertical_carets = [
    @text_layout.CaretGeometry::new(
      0,
      true,
      field_test_rect(0.0, 6.624, 0.0, 18.0),
      field_test_rect(0.0, 6.624, 0.0, 18.0),
    ).unwrap(),
    @text_layout.CaretGeometry::new(
      1,
      true,
      field_test_rect(8.0, 0.0, 0.0, 26.063),
      field_test_rect(8.0, 0.0, 0.0, 26.063),
    ).unwrap(),
    @text_layout.CaretGeometry::new(
      2,
      true,
      field_test_rect(16.0, 0.0, 0.0, 26.063),
      field_test_rect(16.0, 0.0, 0.0, 26.063),
    ).unwrap(),
  ]
  let mixed_vertical_measurement = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 16.0, 26.063),
    field_test_rect(0.0, 0.0, 16.0, 26.063),
    18.0,
    1,
    0,
    mixed_vertical_carets,
  ).unwrap()
  let mixed_vertical_field = @text_field.TextField::new(
    9UL,
    field_test_rect(0.0, 0.0, 80.0, 35.0),
    16.0,
    document,
    _ => Ok(mixed_vertical_measurement),
    (_, _) => Ok(()),
  )
  assert_true(mixed_vertical_field is Ok(_))

  let out_of_line_measurement = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 16.0, 26.0),
    field_test_rect(0.0, 0.0, 16.0, 26.0),
    18.0,
    1,
    0,
    [
      @text_layout.CaretGeometry::new(
        0,
        true,
        field_test_rect(0.0, 0.0, 0.0, 16.0),
        field_test_rect(0.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        1,
        true,
        field_test_rect(8.0, 0.0, 0.0, 16.0),
        field_test_rect(8.0, 0.0, 0.0, 16.0),
      ).unwrap(),
      @text_layout.CaretGeometry::new(
        2,
        true,
        field_test_rect(16.0, 15.0, 0.0, 12.0),
        field_test_rect(16.0, 15.0, 0.0, 12.0),
      ).unwrap(),
    ],
  ).unwrap()
  assert_true(
    @text_field.TextField::new(
      10UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(out_of_line_measurement),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )

  // Negative bearings are accepted when the full union fits the field.
  let negative_left_ink = @text_layout.TextMeasurement::new(
    document,
    normal.logical_rect(),
    field_test_rect(-1.0, -1.0, 18.0, 22.0),
    normal.first_line_baseline(),
    1,
    0,
    normal.carets(),
  ).unwrap()
  let negative_top_ink = @text_layout.TextMeasurement::new(
    document,
    normal.logical_rect(),
    field_test_rect(0.0, -1.0, 16.0, 21.0),
    normal.first_line_baseline(),
    1,
    0,
    normal.carets(),
  ).unwrap()
  let negative_left_field = @text_field.TextField::new(
    11UL,
    field_test_rect(0.0, 0.0, 80.0, 40.0),
    16.0,
    document,
    _ => Ok(negative_left_ink),
    (_, _) => Ok(()),
  ).unwrap()
  assert_true(
    negative_left_field.with_bounds(field_test_rect(0.0, 0.0, 80.0, 29.0))
    is Err(@text_field.InvalidBounds),
  )
  assert_true(
    negative_left_field.with_bounds(field_test_rect(0.0, 0.0, 80.0, 30.0))
    is Ok(_),
  )
  assert_true(
    @text_field.TextField::new(
      12UL,
      field_test_rect(0.0, 0.0, 80.0, 40.0),
      16.0,
      document,
      _ => Ok(negative_top_ink),
      (_, _) => Ok(()),
    )
    is Ok(_),
  )
  assert_true(
    @text_field.scene_text_run_geometry(negative_left_ink) ==
    Ok(
      (
        @primitives.Point::new(1.0, 1.0).unwrap(),
        field_test_rect(0.0, 0.0, 18.0, 22.0),
      ),
    ),
  )
  assert_true(
    @text_field.scene_text_run_geometry(negative_top_ink) ==
    Ok(
      (
        @primitives.Point::new(0.0, 1.0).unwrap(),
        field_test_rect(0.0, 0.0, 16.0, 21.0),
      ),
    ),
  )
  assert_true(
    @text_field.scene_text_bounds(negative_left_ink) ==
    Ok(field_test_rect(0.0, 0.0, 17.0, 21.0)),
  )
  let fractional_bearings = @text_layout.TextMeasurement::new(
    document,
    normal.logical_rect(),
    field_test_rect(-1.7285, -0.25, 17.8, 20.5),
    normal.first_line_baseline(),
    1,
    0,
    normal.carets(),
  ).unwrap()
  assert_true(
    @text_field.scene_text_run_geometry(fractional_bearings) ==
    Ok(
      (
        @primitives.Point::new(2.0, 1.0).unwrap(),
        field_test_rect(0.0, 0.0, 19.0, 22.0),
      ),
    ),
  )
  assert_true(
    @text_field.TextField::new(
      13UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(negative_left_ink),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )
  // Bounds which individually fit the caps may still make an oversized union.
  let too_wide_union = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 2048.0, 20.0),
    field_test_rect(-1.0, 0.0, 2048.0, 20.0),
    normal.first_line_baseline(),
    1,
    0,
    normal.carets(),
  ).unwrap()
  assert_true(
    @text_field.scene_text_run_geometry(too_wide_union)
    is Err(@text_field.GeometryFailure),
  )
  let too_tall_union = @text_layout.TextMeasurement::new(
    document,
    field_test_rect(0.0, 0.0, 16.0, 128.0),
    field_test_rect(0.0, -1.0, 16.0, 128.0),
    normal.first_line_baseline(),
    1,
    0,
    normal.carets(),
  ).unwrap()
  assert_true(
    @text_field.scene_text_run_geometry(too_tall_union)
    is Err(@text_field.GeometryFailure),
  )
  assert_true(
    @text_field.TextField::new(
      6UL,
      field_test_rect(0.0, 0.0, 8.0, 8.0),
      16.0,
      document,
      field_test_measure,
      field_test_admit,
    )
    is Err(@text_field.InvalidBounds),
  )
  assert_true(
    @text_field.TextField::new(
      8UL,
      field_test_rect(0.0, 0.0, 80.0, 16.0),
      16.0,
      document,
      field_test_measure,
      field_test_admit,
    )
    is Err(@text_field.InvalidBounds),
  )
  let other_document = field_test_document("other")
  let mismatched_measurement = field_test_measure(other_document).unwrap()
  assert_true(
    @text_field.TextField::new(
      7UL,
      field.bounds(),
      16.0,
      document,
      _ => Ok(mismatched_measurement),
      (_, _) => Ok(()),
    )
    is Err(@text_field.UnsupportedLayout),
  )
}

///|
test "selection changes scroll, clicks include scroll, and wheel remains bounded" {
  let focused = field_test_focused(
    field_test_create("abcdef", field_test_rect(0.0, 0.0, 24.0, 24.0)),
  )
  let (end, _) = field_test_key(
    focused,
    @primitives.End,
    @primitives.Modifiers::none(),
  )
  assert_eq(end.selection().head(), 6)
  assert_true(end.scroll_offset() > 0.0)
  let end_x = end.measurement().caret_at(6).unwrap().strong().left()
  assert_eq(
    end_x - end.scroll_offset(),
    end.content_bounds().size().width() - 1.0,
  )
  let clicked = field_test_event(
      end,
      @primitives.PointerButtonPressed(
        position=@primitives.Point::new(12.0, 12.0).unwrap(),
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).0
  assert_eq(clicked.selection().head(), 5)
  let wheel = field_test_event(
      clicked,
      @primitives.Scroll(
        position=@primitives.Point::new(12.0, 12.0).unwrap(),
        delta=@primitives.Point::new(-8.0, 0.0).unwrap(),
        modifiers=@primitives.Modifiers::none(),
      ),
    ).0
  assert_eq(wheel.scroll_offset(), clicked.scroll_offset() - 8.0)
  assert_true(wheel.scroll_offset() >= 0.0)
  assert_true(wheel.scroll_offset() <= 33.0)
  let active_x = wheel
    .measurement()
    .caret_at(wheel.selection().head())
    .unwrap()
    .strong()
    .left()
  assert_true(
    active_x - wheel.scroll_offset() <=
    wheel.content_bounds().size().width() - 1.0,
  )
  let wheel_far = field_test_event(
      wheel,
      @primitives.Scroll(
        position=@primitives.Point::new(12.0, 12.0).unwrap(),
        delta=@primitives.Point::new(-100.0, 0.0).unwrap(),
        modifiers=@primitives.Modifiers::none(),
      ),
    ).0
  assert_eq(wheel_far.scroll_offset(), wheel.scroll_offset())

  let unfocused = field_test_create(
    "abcdef",
    field_test_rect(0.0, 0.0, 80.0, 24.0),
  )
  let clicked_to_focus = field_test_event(
      unfocused,
      @primitives.PointerButtonPressed(
        position=@primitives.Point::new(28.0, 12.0).unwrap(),
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).0
  assert_true(clicked_to_focus.is_focused())
  assert_eq(clicked_to_focus.selection().head(), 3)

  let combining = field_test_create(
    "a\u{301}b",
    field_test_rect(0.0, 0.0, 80.0, 24.0),
  )
  let non_cursor_click = combining
    .handle_input(
      @primitives.PointerButtonPressed(
        position=@primitives.Point::new(12.0, 12.0).unwrap(),
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
      field_test_measure,
      field_test_admit,
      field_test_non_cursor_hit,
    )
    .unwrap().0
  assert_eq(non_cursor_click.selection().head(), 0)
}

///|
test "inset run origin is inverted for start hits selection and horizontal scroll" {
  let bounds = field_test_rect(0.0, 0.0, 24.0, 32.0)
  let document = field_test_document("abcdef")
  let measurement = field_test_measure_with_ink(
    document,
    field_test_rect(-2.0, -2.0, 54.0, 24.0),
  )
  let initial = @text_field.TextField::new(
    23UL,
    bounds,
    16.0,
    document,
    _ => Ok(measurement),
    field_test_admit,
  ).unwrap()
  assert_eq(initial.scroll_offset(), 0.0)
  let start = field_test_event(
      initial,
      @primitives.PointerButtonPressed(
        position=@primitives.Point::new(4.0, 16.0).unwrap(),
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).0
  assert_true(start.is_focused())
  assert_eq(start.selection().head(), 0)

  let shift = @primitives.Modifiers::new(
    shift=true,
    control=false,
    alt=false,
    meta=false,
  )
  let selected = field_test_event(
      start,
      @primitives.PointerButtonPressed(
        position=@primitives.Point::new(24.0, 16.0).unwrap(),
        button=@primitives.Primary,
        modifiers=shift,
      ),
    ).0
  assert_true(selected.selection() == @text.TextSelection::new(0, 2).unwrap())
  let (end, _) = field_test_key(
    selected,
    @primitives.End,
    @primitives.Modifiers::none(),
  )
  assert_eq(end.selection().head(), 6)
  // The union width is 54 px; reserve a one-pixel caret at the right edge.
  assert_eq(end.scroll_offset(), 35.0)
  let end_caret = end.measurement().caret_at(6).unwrap().strong()
  assert_eq(end_caret.left() + 2.0 - end.scroll_offset(), 15.0)
}

///|
test "clipboard intents preserve snapshot and cut carries admitted candidate" {
  let focused = field_test_focused(
    field_test_selection(
      field_test_create("abcd", field_test_rect(0.0, 0.0, 100.0, 24.0)),
      3,
      1,
    ),
  )
  let original_revision = focused.revision()
  let ctrl = @primitives.Modifiers::new(
    shift=false,
    control=true,
    alt=false,
    meta=false,
  )
  let (copied, copy_action) = field_test_key(
    focused,
    @primitives.Character("c"),
    ctrl,
  )
  assert_true(copied.document() == focused.document())
  assert_eq(copied.revision(), original_revision)
  assert_true(copy_action is Some(@text_field.Copy("bc")))

  let (cut_old, cut_action) = field_test_key(
    focused,
    @primitives.Character("x"),
    ctrl,
  )
  assert_true(cut_old.document() == focused.document())
  assert_eq(cut_old.revision(), original_revision)
  match cut_action {
    Some(@text_field.Cut(text="bc", candidate~)) => {
      assert_eq(candidate.document().text(), "ad")
      assert_eq(candidate.selection().head(), 1)
      assert_true(candidate.measurement().document() == candidate.document())
    }
    _ => fail("cut should carry its fully admitted candidate")
  }
  let (pasted, paste_action) = field_test_key(
    focused,
    @primitives.Character("v"),
    ctrl,
  )
  assert_true(pasted.document() == focused.document())
  assert_true(paste_action is Some(@text_field.Paste))
}

///|
test "callback failures and revision exhaustion leave the prior value intact" {
  let original = field_test_focused(
    field_test_create("old", field_test_rect(0.0, 0.0, 80.0, 24.0)),
  )
  let revision = original.revision()
  assert_true(
    original.handle_input(
      @primitives.TextInput(text="new"),
      _ => Err(@text_field.MeasurementFailed),
      field_test_admit,
      field_test_hit,
    )
    is Err(@text_field.MeasurementFailed),
  )
  assert_true(
    original.handle_input(
      @primitives.TextInput(text="new"),
      field_test_measure,
      (_, _) => Err(@text_field.AdmissionFailed),
      field_test_hit,
    )
    is Err(@text_field.AdmissionFailed),
  )
  let selected = field_test_selection(original, 3, 1)
  let selected_revision = selected.revision()
  let selected_selection = selected.selection()
  let ctrl = @primitives.Modifiers::new(
    shift=false,
    control=true,
    alt=false,
    meta=false,
  )
  assert_true(
    selected.handle_input(
      @primitives.KeyPressed(
        key=@primitives.Character("x"),
        modifiers=ctrl,
        repeat=false,
      ),
      field_test_measure,
      (_, _) => Err(@text_field.AdmissionFailed),
      field_test_hit,
    )
    is Err(@text_field.AdmissionFailed),
  )
  assert_true(
    selected.handle_input(
      @primitives.PointerButtonPressed(
        position=@primitives.Point::new(12.0, 12.0).unwrap(),
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
      field_test_measure,
      field_test_admit,
      (_, _) => Err(@text_field.HitTestFailed),
    )
    is Err(@text_field.HitTestFailed),
  )
  assert_eq(selected.document().text(), "old")
  assert_true(selected.selection() == selected_selection)
  assert_eq(selected.revision(), selected_revision)
  assert_eq(original.document().text(), "old")
  assert_eq(original.revision(), revision)
}
