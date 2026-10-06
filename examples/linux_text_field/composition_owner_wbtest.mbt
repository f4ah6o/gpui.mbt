///|
fn owner_composition_preedit(
  field : @text_field.TextField,
  text : String,
) -> @text_field.TextField {
  let document = @text.TextDocument::new(text).unwrap()
  let bytes = document.utf8_length().unwrap()
  field.update_composition_utf8(text, bytes, bytes, measure, admit).unwrap()
}

///|
test "presentation rollback retains submitted composition and rejects pending commit history" {
  let original = owner_history_selected(controller_field())
  let edited = original.replace_selection("X", measure, admit).unwrap()
  let original_with_redo = edited.undo(measure, admit).unwrap()
  let submitted = owner_composition_preedit(original_with_redo, "に")
  let pending = owner_composition_preedit(submitted, "にほん")
  let committed = pending.commit_composition("日本", measure, admit).unwrap()
  assert_true(submitted.is_composing())
  assert_true(submitted.can_redo())
  assert_false(submitted.can_undo())
  assert_false(committed.is_composing())
  assert_true(committed.can_undo())
  assert_false(committed.can_redo())
  assert_true(
    classify_field_frame(Err(controller_error(@diagnostics.Busy)))
    is BusyPending,
  )
  assert_true(pending.is_composing())
  for
    code in [
      @diagnostics.InvalidInput,
      @diagnostics.UnsupportedCapability,
      @diagnostics.ResourceExhausted,
    ] {
    assert_true(
      classify_field_frame(Err(controller_error(code))) is RejectPending,
    )
    let current = committed
      .with_bounds(@primitives.Rect::new(24.0, 28.0, 300.0, 44.0).unwrap())
      .unwrap()
    let restored = restore_submitted_field(submitted, current).unwrap()
    assert_true(restored.document() == submitted.document())
    assert_true(restored.selection() == submitted.selection())
    assert_true(restored.marked_range() == submitted.marked_range())
    assert_true(restored.measurement().document() == restored.document())
    assert_true(restored.is_composing())
    assert_true(restored.is_focused())
    assert_true(restored.bounds() == current.bounds())
    assert_false(restored.can_undo())
    assert_true(restored.can_redo())
    // The restored owner still replaces the original selection, not its
    // submitted preedit selection; pending final text/history never leaked.
    let retried = owner_composition_preedit(restored, "日本")
    assert_eq(retried.document().text(), "日本")
    let cancelled = retried.cancel_composition(measure, admit).unwrap()
    assert_true(cancelled.document() == original_with_redo.document())
    assert_true(cancelled.can_redo())
    assert_true(
      cancelled.redo(measure, admit).unwrap().document() == edited.document(),
    )
    controller_assert_painted_selection(cancelled)
    controller_assert_painted_caret(
      cancelled,
      original_with_redo.selection().head(),
    )
  }
}

///|
test "rejected first preview restores no composition and focus loss cancels submitted preview" {
  let original = owner_history_selected(controller_field())
  let preview = owner_composition_preedit(original, "日本")
  let restored = restore_submitted_field(original, preview).unwrap()
  assert_true(restored.document() == original.document())
  assert_false(restored.is_composing())
  assert_true(restored.marked_range() is None)
  assert_false(restored.can_undo())
  let disarm_error = apply_owner_blur(
    preview,
    Err(controller_error(@diagnostics.PermissionDenied)),
  )
  assert_true(disarm_error is Err(Native(_)))
  assert_true(preview.is_composing())
  let blurred = apply_owner_blur(preview, Ok(())).unwrap()
  assert_true(blurred.document() == original.document())
  assert_false(blurred.is_composing())
  assert_false(blurred.is_focused())
  let restored_blurred = restore_submitted_field(preview, blurred).unwrap()
  assert_true(restored_blurred.document() == original.document())
  assert_false(restored_blurred.is_composing())
  assert_false(restored_blurred.is_focused())
}

///|
test "real font preedit admission checks exact UTF8 cursor and final undo selection" {
  let original = owner_history_selected(controller_field())
  let preview = owner_composition_preedit(original, "a\u{301}日本")
  let rejected = preview.update_composition_utf8(
    "a\u{301}", 1, 1, measure, admit,
  )
  assert_true(rejected is Err(@text_field.InvalidSelection))
  assert_true(preview.is_composing())
  assert_eq(preview.document().text(), "a\u{301}日本")
  let admitted_calls = [0]
  let rejecting_admit = fn(_, _) {
    admitted_calls[0] += 1
    Err(@text_field.AdmissionFailed)
  }
  assert_true(
    preview.commit_composition("日本", measure, rejecting_admit)
    is Err(@text_field.AdmissionFailed),
  )
  assert_eq(admitted_calls[0], 1)
  assert_false(preview.can_undo())
  let committed = preview.commit_composition("日本", measure, admit).unwrap()
  let undone = committed.undo(measure, admit).unwrap()
  assert_true(undone.document() == original.document())
  assert_false(undone.can_undo())
  assert_true(
    undone.redo(measure, admit).unwrap().document() == committed.document(),
  )
  controller_assert_painted_caret(preview, preview.selection().head())
}
