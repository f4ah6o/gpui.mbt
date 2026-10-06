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
