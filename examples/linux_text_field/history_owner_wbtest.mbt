///|
fn owner_history_selected(
  field : @text_field.TextField,
) -> @text_field.TextField {
  let end = change(field, key_event(@primitives.End)).unwrap()
  change(end, key_event(@primitives.Home, shift=true)).unwrap()
}

///|
fn owner_history_command(
  key : String,
  repeat? : Bool = false,
) -> @primitives.InputEvent {
  @primitives.KeyPressed(
    key=@primitives.Character(key),
    modifiers=@primitives.Modifiers::new(
      shift=false,
      control=true,
      alt=false,
      meta=false,
    ),
    repeat~,
  )
}

///|
test "repeated cut remains a transactional owner action" {
  let selected = owner_history_selected(controller_field())
  let (unchanged, action) = selected
    .handle_input(owner_history_command("x", repeat=true), measure, admit, hit)
    .unwrap()
  assert_true(unchanged.document() == selected.document())
  assert_false(unchanged.can_undo())
  match action {
    Some(@text_field.Cut(text~, candidate~)) => {
      assert_eq(text, selected.document().text())
      let failed = cut_after_write(
        unchanged,
        candidate,
        Err(controller_error(@diagnostics.PermissionDenied)),
      )
      assert_true(failed.document() == selected.document())
      assert_false(failed.can_undo())
      let installed = cut_after_write(unchanged, candidate, Ok(()))
      assert_eq(installed.document().text(), "")
      let restored = installed.undo(measure, admit).unwrap()
      assert_true(restored.document() == selected.document())
      assert_false(restored.can_undo())
    }
    _ => abort("repeated cut must carry an admitted candidate")
  }
}

///|
test "Busy keeps repeated edits and rejection restores submitted history" {
  let original = change(controller_field(), key_event(@primitives.End)).unwrap()
  let submitted = change(original, @primitives.TextInput(text="A")).unwrap()
  let first = change(submitted, controller_repeat_event(@primitives.Backspace)).unwrap()
  let pending = change(first, controller_repeat_event(@primitives.Backspace)).unwrap()
  assert_true(
    classify_field_frame(Err(controller_error(@diagnostics.Busy)))
    is BusyPending,
  )
  assert_eq(pending.document().text(), "Hi 日")
  let undone_once = pending.undo(measure, admit).unwrap()
  assert_true(undone_once.document() == first.document())
  let undone_twice = undone_once.undo(measure, admit).unwrap()
  assert_true(undone_twice.document() == submitted.document())
  for
    code in [
      @diagnostics.InvalidInput,
      @diagnostics.UnsupportedCapability,
      @diagnostics.ResourceExhausted,
    ] {
    assert_true(
      classify_field_frame(Err(controller_error(code))) is RejectPending,
    )
    let restored = restore_submitted_field(submitted, pending).unwrap()
    assert_true(restored.document() == submitted.document())
    assert_true(restored.can_undo())
    assert_false(restored.can_redo())
    let undone = restored.undo(measure, admit).unwrap()
    assert_true(undone.document() == original.document())
    assert_false(undone.can_undo())
    assert_true(undone.can_redo())
  }
}

///|
test "cut history installs only after owner write success" {
  let selected = owner_history_selected(controller_field())
  let (unchanged, action) = selected
    .handle_input(owner_history_command("x"), measure, admit, hit)
    .unwrap()
  assert_false(selected.can_undo())
  assert_false(unchanged.can_undo())
  match action {
    Some(@text_field.Cut(text~, candidate~)) => {
      assert_true(text == selected.document().text())
      assert_true(candidate.can_undo())
      let failed = cut_after_write(
        unchanged,
        candidate,
        Err(controller_error(@diagnostics.PermissionDenied)),
      )
      assert_false(failed.can_undo())
      assert_false(failed.can_redo())
      assert_true(failed.document() == selected.document())
      let installed = cut_after_write(unchanged, candidate, Ok(()))
      assert_true(installed.document().text() == "")
      let undone = installed.undo(measure, admit).unwrap()
      assert_true(undone.document() == selected.document())
      assert_false(undone.can_undo())
      assert_true(undone.can_redo())
      let redone = undone.redo(measure, admit).unwrap()
      assert_true(redone.document().text() == "")
      assert_true(redone.can_undo())
      assert_false(redone.can_redo())
      // Installing or rejecting the candidate never changes the source value.
      assert_false(selected.can_undo())
      assert_false(unchanged.can_undo())
    }
    _ => abort("expected prepared cut candidate")
  }
}

///|
test "paste history obeys epoch revision and focus guards" {
  let field = controller_field()
  let fresh = paste_if_current(field, field.revision(), Ok(7), Ok(7), "P").unwrap()
  assert_true(fresh.can_undo())
  let undone = fresh.undo(measure, admit).unwrap()
  assert_true(undone.document() == field.document())
  assert_true(undone.can_redo())
  let stale_epoch = paste_if_current(
    undone,
    undone.revision(),
    Ok(7),
    Ok(8),
    "S",
  ).unwrap()
  assert_true(stale_epoch.document() == undone.document())
  assert_true(stale_epoch.revision() == undone.revision())
  assert_false(stale_epoch.can_undo())
  assert_true(stale_epoch.can_redo())
  let stale_revision = paste_if_current(
    undone,
    undone.revision() - 1,
    Ok(7),
    Ok(7),
    "S",
  ).unwrap()
  assert_true(stale_revision.document() == undone.document())
  assert_true(stale_revision.can_redo())
  let blurred = undone.with_focus(false).unwrap()
  let stale_focus = paste_if_current(
    blurred,
    blurred.revision(),
    Ok(7),
    Ok(7),
    "S",
  ).unwrap()
  assert_true(stale_focus.document() == blurred.document())
  assert_true(stale_focus.can_redo())
  let redone = stale_epoch.redo(measure, admit).unwrap()
  assert_true(redone.document() == fresh.document())
  assert_false(redone.can_redo())
  assert_false(field.can_undo())
}

///|
test "Busy recovery and preflight rollback preserve the matching history" {
  let original = controller_field()
  let submitted = original.replace_selection("A", measure, admit).unwrap()
  let pending = submitted.replace_selection("B", measure, admit).unwrap()
  assert_true(
    classify_field_frame(Err(controller_error(@diagnostics.Busy)))
    is BusyPending,
  )
  assert_true(
    classify_field_frame(Err(controller_error(@diagnostics.SurfaceLost)))
    is RecoverPending,
  )
  assert_true(
    pending.undo(measure, admit).unwrap().document() == submitted.document(),
  )
  let twice = pending
    .undo(measure, admit)
    .unwrap()
    .undo(measure, admit)
    .unwrap()
  assert_true(twice.document() == original.document())
  assert_false(twice.can_undo())
  for
    code in [
      @diagnostics.InvalidInput,
      @diagnostics.UnsupportedCapability,
      @diagnostics.ResourceExhausted,
    ] {
    assert_true(
      classify_field_frame(Err(controller_error(code))) is RejectPending,
    )
    let current = pending
      .with_bounds(@primitives.Rect::new(24.0, 28.0, 300.0, 44.0).unwrap())
      .unwrap()
      .with_focus(false)
      .unwrap()
    let restored = restore_submitted_field(submitted, current).unwrap()
    assert_true(restored.document() == submitted.document())
    assert_true(restored.bounds() == current.bounds())
    assert_false(restored.is_focused())
    assert_true(restored.can_undo())
    assert_false(restored.can_redo())
    let focused = restored.with_focus(true).unwrap()
    let undone = focused.undo(measure, admit).unwrap()
    assert_true(undone.document() == original.document())
    assert_false(undone.can_undo())
    assert_true(undone.can_redo())
  }
  // A rejected undo frame restores the submitted stack, not the pending redo.
  let pending_undo = submitted.undo(measure, admit).unwrap()
  assert_true(pending_undo.can_redo())
  let rejected_undo = restore_submitted_field(submitted, pending_undo).unwrap()
  assert_true(rejected_undo.document() == submitted.document())
  assert_true(rejected_undo.can_undo())
  assert_false(rejected_undo.can_redo())
  assert_true(pending.can_undo())
  assert_false(original.can_undo())
}

///|
test "real sans undo restores bearings fallback selection and original redo caret" {
  let original = make_field(
      "jÁA\u{301} 日本",
      @primitives.Rect::new(32.0, 28.0, 180.0, 44.0).unwrap(),
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let selected = owner_history_selected(original)
  let edited = selected.replace_selection("Jé", measure, admit).unwrap()
  let navigated = change(edited, key_event(@primitives.Home)).unwrap()
  assert_true(navigated.selection().head() == 0)
  let undone = navigated.undo(measure, admit).unwrap()
  assert_true(undone.document() == selected.document())
  controller_assert_painted_selection(undone)
  controller_assert_painted_caret(undone, selected.selection().head())
  let redone = undone.redo(measure, admit).unwrap()
  assert_true(redone.document() == edited.document())
  assert_true(redone.selection().head() == 2)
  controller_assert_painted_caret(redone, 2)
  assert_true(undone.bounds() == navigated.bounds())
  assert_true(undone.is_focused())
  assert_true(undone.revision() == navigated.revision() + 1)
  assert_true(redone.revision() == undone.revision() + 1)
}
