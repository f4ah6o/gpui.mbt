///|
// ASCII-only geometry for exercising private revision exhaustion, not a font
// or Unicode segmentation implementation.
fn undo_revision_measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, TextFieldError] {
  let carets = []
  let length = document.utf16_length()
  for offset in 0..<=length {
    let bounds = @primitives.Rect::new(offset.to_double() * 8.0, 0.0, 0.0, 16.0).unwrap()
    carets.push(
      @text_layout.CaretGeometry::new(offset, true, bounds, bounds).unwrap(),
    )
  }
  let bounds = @primitives.Rect::new(0.0, 0.0, length.to_double() * 8.0, 16.0).unwrap()
  match
    @text_layout.TextMeasurement::new(
      document, bounds, bounds, 12.0, 1, 0, carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(MeasurementFailed)
  }
}

///|
// Keep every scalar-boundary caret in the table, but mark one interior
// boundary as a non-cursor position so a saved selection can become invalid.
fn undo_measure_without_cursor_stop(
  document : @text.TextDocument,
  omitted_offset : Int,
) -> Result[@text_layout.TextMeasurement, TextFieldError] {
  let carets = []
  let length = document.utf16_length()
  for offset in 0..<=length {
    let bounds = @primitives.Rect::new(offset.to_double() * 8.0, 0.0, 0.0, 16.0).unwrap()
    match
      @text_layout.CaretGeometry::new(
        offset,
        offset != omitted_offset,
        bounds,
        bounds,
      ) {
      Ok(value) => carets.push(value)
      Err(_) => return Err(MeasurementFailed)
    }
  }
  let bounds = @primitives.Rect::new(0.0, 0.0, length.to_double() * 8.0, 16.0).unwrap()
  match
    @text_layout.TextMeasurement::new(
      document, bounds, bounds, 12.0, 1, 0, carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(MeasurementFailed)
  }
}

///|
// Keep a detached copy of the private history arrays so later transitions
// cannot make the expected snapshot alias the state being checked.
fn undo_field_snapshot(field : TextField) -> TextField {
  {
    ..field,
    history: {
      undo: field.history.undo.copy(),
      redo: field.history.redo.copy(),
      payload_bytes: field.history.payload_bytes,
    },
  }
}

///|
fn undo_assert_same_field_snapshot(
  expected : TextField,
  actual : TextField,
) -> Unit raise {
  assert_eq(actual.id(), expected.id())
  assert_true(actual.bounds() == expected.bounds())
  assert_eq(actual.font_size(), expected.font_size())
  assert_true(actual.document() == expected.document())
  assert_true(actual.is_focused() == expected.is_focused())
  assert_eq(actual.scroll_offset(), expected.scroll_offset())
  assert_eq(actual.revision(), expected.revision())

  let expected_measurement = expected.measurement()
  let actual_measurement = actual.measurement()
  assert_true(actual_measurement.document() == expected_measurement.document())
  assert_true(
    actual_measurement.logical_rect() == expected_measurement.logical_rect(),
  )
  assert_true(actual_measurement.ink_rect() == expected_measurement.ink_rect())
  assert_eq(
    actual_measurement.first_line_baseline(),
    expected_measurement.first_line_baseline(),
  )
  assert_eq(actual_measurement.line_count(), expected_measurement.line_count())
  assert_eq(
    actual_measurement.unknown_glyph_count(),
    expected_measurement.unknown_glyph_count(),
  )
  let expected_carets = expected_measurement.carets()
  let actual_carets = actual_measurement.carets()
  assert_eq(actual_carets.length(), expected_carets.length())
  for index in 0..<expected_carets.length() {
    let expected_caret = expected_carets[index]
    let actual_caret = actual_carets[index]
    assert_eq(actual_caret.utf16_offset(), expected_caret.utf16_offset())
    assert_true(
      actual_caret.is_cursor_position() == expected_caret.is_cursor_position(),
    )
    assert_true(actual_caret.strong() == expected_caret.strong())
    assert_true(actual_caret.weak() == expected_caret.weak())
  }

  assert_eq(actual.history.payload_bytes, expected.history.payload_bytes)
  assert_eq(actual.history.undo.length(), expected.history.undo.length())
  assert_eq(actual.history.redo.length(), expected.history.redo.length())
  for index in 0..<expected.history.undo.length() {
    assert_true(
      actual.history.undo[index].before == expected.history.undo[index].before,
    )
    assert_true(
      actual.history.undo[index].after == expected.history.undo[index].after,
    )
  }
  for index in 0..<expected.history.redo.length() {
    assert_true(
      actual.history.redo[index].before == expected.history.redo[index].before,
    )
    assert_true(
      actual.history.redo[index].after == expected.history.redo[index].after,
    )
  }
}

///|
test "history restore revision exhaustion keeps both stacks and skips admission" {
  let admit = fn(_document, _measurement) { Ok(()) }
  let initial = TextField::new(
      2,
      @primitives.Rect::new(0.0, 0.0, 100.0, 28.0).unwrap(),
      10.0,
      @text.TextDocument::new("a").unwrap(),
      undo_revision_measure,
      admit,
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let edited = initial
    .replace_selection("b", undo_revision_measure, admit)
    .unwrap()
  let exhausted = { ..edited, revision: @int.MAX_VALUE, }
  let admission_calls = [0]
  let counted_admit = fn(_document, _measurement) {
    admission_calls[0] += 1
    Ok(())
  }
  assert_true(
    exhausted.undo(undo_revision_measure, counted_admit)
    is Err(RevisionExhausted),
  )
  assert_eq(admission_calls[0], 0)
  assert_true(exhausted.document == edited.document)
  assert_true(
    exhausted.history.undo_entry().unwrap().before == initial.document,
  )
  assert_true(exhausted.history.undo_entry().unwrap().after == edited.document)
  assert_true(exhausted.can_undo())
  assert_false(exhausted.can_redo())
  assert_eq(exhausted.history.payload_bytes, edited.history.payload_bytes)

  let undone = edited.undo(undo_revision_measure, admit).unwrap()
  let exhausted_redo = { ..undone, revision: @int.MAX_VALUE, }
  assert_true(
    exhausted_redo.redo(undo_revision_measure, counted_admit)
    is Err(RevisionExhausted),
  )
  assert_eq(admission_calls[0], 0)
  assert_true(exhausted_redo.document == undone.document)
  assert_true(
    exhausted_redo.history.redo_entry().unwrap().before == initial.document,
  )
  assert_true(
    exhausted_redo.history.redo_entry().unwrap().after == edited.document,
  )
  assert_false(exhausted_redo.can_undo())
  assert_true(exhausted_redo.can_redo())
  assert_eq(exhausted_redo.history.payload_bytes, undone.history.payload_bytes)
}

///|
test "undo and redo reject wrong measurements and lost saved cursor stops atomically" {
  let admit = fn(_document, _measurement) { Ok(()) }
  let start_document = @text.TextDocument::new("abcd")
    .unwrap()
    .with_selection(@text.TextSelection::new(2, 1).unwrap())
    .unwrap()
  let start = TextField::new(
      3UL,
      @primitives.Rect::new(0.0, 0.0, 100.0, 28.0).unwrap(),
      10.0,
      start_document,
      undo_revision_measure,
      admit,
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let edited = start
    .replace_selection("X", undo_revision_measure, admit)
    .unwrap()
  assert_eq(edited.document().text(), "aXcd")
  assert_true(edited.selection() == @text.TextSelection::new(2, 2).unwrap())
  let edited_snapshot = undo_field_snapshot(edited)

  let wrong_document = @text.TextDocument::new("other").unwrap()
  let wrong_measure = fn(_document) { undo_revision_measure(wrong_document) }
  assert_true(edited.undo(wrong_measure, admit) is Err(UnsupportedLayout))
  undo_assert_same_field_snapshot(edited_snapshot, edited)

  let undo_without_saved_stop = fn(document) {
    undo_measure_without_cursor_stop(document, 1)
  }
  assert_true(
    edited.undo(undo_without_saved_stop, admit) is Err(InvalidSelection),
  )
  undo_assert_same_field_snapshot(edited_snapshot, edited)

  let undone = edited.undo(undo_revision_measure, admit).unwrap()
  assert_eq(undone.document().text(), "abcd")
  assert_true(undone.selection() == @text.TextSelection::new(2, 1).unwrap())
  let undone_snapshot = undo_field_snapshot(undone)
  assert_true(undone.redo(wrong_measure, admit) is Err(UnsupportedLayout))
  undo_assert_same_field_snapshot(undone_snapshot, undone)

  let redo_without_saved_stop = fn(document) {
    undo_measure_without_cursor_stop(document, 2)
  }
  assert_true(
    undone.redo(redo_without_saved_stop, admit) is Err(InvalidSelection),
  )
  undo_assert_same_field_snapshot(undone_snapshot, undone)

  let redone = undone.redo(undo_revision_measure, admit).unwrap()
  assert_eq(redone.document().text(), "aXcd")
  assert_true(redone.selection() == @text.TextSelection::new(2, 2).unwrap())
  let redone_snapshot = undo_field_snapshot(redone)

  // A new edit from the undone branch clears only that branch's redo stack.
  let branched = undone
    .replace_selection("Y", undo_revision_measure, admit)
    .unwrap()
  assert_eq(branched.document().text(), "aYcd")
  assert_true(branched.can_undo())
  assert_false(branched.can_redo())
  assert_true(edited.can_undo())
  assert_false(edited.can_redo())
  assert_false(undone.can_undo())
  assert_true(undone.can_redo())
  assert_true(redone.can_undo())
  assert_false(redone.can_redo())

  // Older snapshots retain their full document, measurement and history state.
  undo_assert_same_field_snapshot(edited_snapshot, edited)
  undo_assert_same_field_snapshot(undone_snapshot, undone)
  undo_assert_same_field_snapshot(redone_snapshot, redone)
}
