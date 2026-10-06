///|
fn composition_assert_same_snapshot(
  expected : TextField,
  actual : TextField,
) -> Unit raise {
  undo_assert_same_field_snapshot(expected, actual)
  match (expected.composition, actual.composition) {
    (None, None) => ()
    (Some(before), Some(after)) => {
      assert_true(after.original == before.original)
      assert_true(after.transaction.document() == before.transaction.document())
      assert_true(after.transaction.status() == before.transaction.status())
      assert_true(
        after.transaction.marked_range() == before.transaction.marked_range(),
      )
      assert_true(after.preview_visible == before.preview_visible)
      assert_eq(after.scroll_offset, before.scroll_offset)
      assert_true(after.measurement.document() == before.measurement.document())
      assert_true(
        after.measurement.logical_rect() == before.measurement.logical_rect(),
      )
      assert_true(after.measurement.ink_rect() == before.measurement.ink_rect())
      assert_eq(after.history.payload_bytes, before.history.payload_bytes)
      assert_eq(after.history.undo.length(), before.history.undo.length())
      assert_eq(after.history.redo.length(), before.history.redo.length())
      for index in 0..<before.history.undo.length() {
        assert_true(
          after.history.undo[index].before == before.history.undo[index].before,
        )
        assert_true(
          after.history.undo[index].after == before.history.undo[index].after,
        )
      }
      for index in 0..<before.history.redo.length() {
        assert_true(
          after.history.redo[index].before == before.history.redo[index].before,
        )
        assert_true(
          after.history.redo[index].after == before.history.redo[index].after,
        )
      }
    }
    _ => fail("composition ownership changed")
  }
}

///|
fn composition_private_field() -> TextField {
  TextField::new(
    19UL,
    @primitives.Rect::new(0.0, 0.0, 100.0, 36.0).unwrap(),
    10.0,
    @text.TextDocument::new("abcd")
    .unwrap()
    .with_selection(@text.TextSelection::new(3, 1).unwrap())
    .unwrap(),
    undo_revision_measure,
    (_, _) => Ok(()),
  )
  .unwrap()
  .with_focus(true)
  .unwrap()
}

///|
test "composition failures retain exact private transaction history and geometry" {
  let admit = fn(_, _) { Ok(()) }
  let initial = composition_private_field()
  let edited = initial
    .replace_selection("X", undo_revision_measure, admit)
    .unwrap()
  let original = edited.undo(undo_revision_measure, admit).unwrap()
  let preview = original
    .update_composition_utf8("PRE", 3, 3, undo_revision_measure, admit)
    .unwrap()
  let snapshot = undo_field_snapshot(preview)
  let failing_admit = fn(_, _) { Err(AdmissionFailed) }
  assert_true(
    preview.update_composition_utf8(
      "NEXT", 4, 4, undo_revision_measure, failing_admit,
    )
    is Err(AdmissionFailed),
  )
  assert_true(
    preview.update_composition_utf8(
      "", 0, 0, undo_revision_measure, failing_admit,
    )
    is Err(AdmissionFailed),
  )
  assert_true(
    preview.commit_composition("FINAL", undo_revision_measure, failing_admit)
    is Err(AdmissionFailed),
  )
  assert_true(
    preview.cancel_composition(undo_revision_measure, failing_admit)
    is Err(AdmissionFailed),
  )
  let missing_head = fn(document) {
    undo_measure_without_cursor_stop(document, 2)
  }
  assert_true(
    preview.update_composition_utf8("N", 1, 1, missing_head, admit)
    is Err(InvalidSelection),
  )
  assert_true(
    preview.commit_composition("N", missing_head, admit)
    is Err(InvalidSelection),
  )
  assert_true(
    preview.cancel_composition(_ => Err(MeasurementFailed), admit)
    is Err(MeasurementFailed),
  )
  composition_assert_same_snapshot(snapshot, preview)
  let cancelled = preview
    .cancel_composition(undo_revision_measure, admit)
    .unwrap()
  assert_true(cancelled.document() == original.document())
  assert_true(cancelled.can_redo())
  assert_true(
    cancelled.redo(undo_revision_measure, admit).unwrap().document() ==
    edited.document(),
  )
  composition_assert_same_snapshot(snapshot, preview)
}

///|
test "composition revision exhaustion does not admit or publish partial state" {
  let admit = fn(_, _) { Ok(()) }
  let original = composition_private_field()
  let exhausted_original = { ..original, revision: @int.MAX_VALUE, }
  let calls = [0]
  let counted_admit = fn(_, _) {
    calls[0] += 1
    Ok(())
  }
  assert_true(
    exhausted_original.update_composition_utf8(
      "P", 1, 1, undo_revision_measure, counted_admit,
    )
    is Err(RevisionExhausted),
  )
  assert_false(exhausted_original.is_composing())
  let preview = original
    .update_composition_utf8("P", 1, 1, undo_revision_measure, admit)
    .unwrap()
  let exhausted = { ..preview, revision: @int.MAX_VALUE, }
  let snapshot = undo_field_snapshot(exhausted)
  assert_true(
    exhausted.update_composition_utf8(
      "Q", 1, 1, undo_revision_measure, counted_admit,
    )
    is Err(RevisionExhausted),
  )
  assert_true(
    exhausted.update_composition_utf8(
      "", 0, 0, undo_revision_measure, counted_admit,
    )
    is Err(RevisionExhausted),
  )
  assert_true(
    exhausted.commit_composition("Q", undo_revision_measure, counted_admit)
    is Err(RevisionExhausted),
  )
  assert_true(
    exhausted.cancel_composition(undo_revision_measure, counted_admit)
    is Err(RevisionExhausted),
  )
  assert_true(exhausted.with_focus(false) is Err(RevisionExhausted))
  assert_eq(calls[0], 0)
  composition_assert_same_snapshot(snapshot, exhausted)
}

///|
test "resize validates the originally admitted geometry before focus loss" {
  let admit = fn(_, _) { Ok(()) }
  let tall_measure = fn(document) {
    let base = undo_revision_measure(document).unwrap()
    let height = if document.text() == "abcd" { 24.0 } else { 16.0 }
    let bounds = @primitives.Rect::new(
      0.0,
      0.0,
      base.logical_rect().size().width(),
      height,
    ).unwrap()
    match
      @text_layout.TextMeasurement::new(
        document,
        bounds,
        bounds,
        12.0,
        1,
        0,
        base.carets(),
      ) {
      Ok(value) => Ok(value)
      Err(_) => Err(MeasurementFailed)
    }
  }
  let original = TextField::new(
      19UL,
      @primitives.Rect::new(0.0, 0.0, 100.0, 36.0).unwrap(),
      10.0,
      @text.TextDocument::new("abcd").unwrap(),
      tall_measure,
      admit,
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let preview = original
    .update_composition_utf8("X", 1, 1, tall_measure, admit)
    .unwrap()
  assert_eq(preview.measurement().logical_rect().size().height(), 16.0)
  let snapshot = undo_field_snapshot(preview)
  // The preview fits a 20px content viewport; the saved 24px original does not.
  assert_true(
    preview.with_bounds(@primitives.Rect::new(12.0, 16.0, 100.0, 28.0).unwrap())
    is Err(UnsupportedLayout),
  )
  composition_assert_same_snapshot(snapshot, preview)
  let resized = preview
    .with_bounds(@primitives.Rect::new(12.0, 16.0, 160.0, 40.0).unwrap())
    .unwrap()
  let blurred = resized.with_focus(false).unwrap()
  assert_true(blurred.bounds() == resized.bounds())
  assert_true(blurred.document() == original.document())
  assert_eq(blurred.measurement().logical_rect().size().height(), 24.0)
  assert_false(blurred.is_composing())
  assert_false(blurred.is_focused())
  assert_false(blurred.can_undo())
  assert_eq(blurred.revision(), resized.revision() + 1)
}
