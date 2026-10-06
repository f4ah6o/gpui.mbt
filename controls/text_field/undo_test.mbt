///|
fn field_test_undo(
  field : @text_field.TextField,
) -> @text_field.TextField raise {
  match field.undo(field_test_measure, field_test_admit) {
    Ok(value) => value
    Err(_) => fail("valid test undo should be handled")
  }
}

///|
fn field_test_redo(
  field : @text_field.TextField,
) -> @text_field.TextField raise {
  match field.redo(field_test_measure, field_test_admit) {
    Ok(value) => value
    Err(_) => fail("valid test redo should be handled")
  }
}

///|
test "text input creates one directional undo entry and redo keeps original selection" {
  let original = field_test_focused(
    field_test_selection(
      field_test_create("abcd", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      3,
      1,
    ),
  )
  let (edited, _) = field_test_text(original, "X")
  assert_eq(edited.document().text(), "aXd")
  assert_true(edited.can_undo())
  assert_false(edited.can_redo())

  let undone = field_test_undo(edited)
  assert_eq(undone.document().text(), "abcd")
  assert_true(undone.selection() == @text.TextSelection::new(3, 1).unwrap())
  assert_true(undone.is_focused())
  assert_eq(undone.revision(), edited.revision() + 1)
  assert_true(undone.measurement().document() == undone.document())
  assert_true(undone.can_redo())

  // Selection-only navigation must not rewrite the saved post-edit endpoint.
  let moved = field_test_key(
      undone,
      @primitives.ArrowRight,
      @primitives.Modifiers::none(),
    ).0
  assert_true(moved.selection() != edited.selection())
  let redone = field_test_redo(moved)
  assert_eq(redone.document().text(), "aXd")
  assert_true(redone.selection() == edited.selection())
  assert_true(redone.is_focused())
  assert_true(redone.measurement().document() == redone.document())
  assert_true(redone.can_undo())
  assert_false(redone.can_redo())
}

///|
test "successive input deletions and explicit replacements remain separate groups" {
  let start = field_test_focused(
    field_test_selection(
      field_test_create("a", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      1,
      1,
    ),
  )
  let (ab, _) = field_test_text(start, "b")
  let (abc, _) = field_test_text(ab, "c")
  assert_eq(abc.document().text(), "abc")
  let back_to_ab = field_test_undo(abc)
  assert_eq(back_to_ab.document().text(), "ab")
  let back_to_a = field_test_undo(back_to_ab)
  assert_eq(back_to_a.document().text(), "a")
  assert_false(back_to_a.can_undo())
  assert_true(back_to_a.can_redo())
  let redone_ab = field_test_redo(back_to_a)
  assert_eq(redone_ab.document().text(), "ab")
  let redone_abc = field_test_redo(redone_ab)
  assert_eq(redone_abc.document().text(), "abc")

  let at_end = field_test_selection(start, 1, 1)
  let (deleted, _) = field_test_key(
    at_end,
    @primitives.Backspace,
    @primitives.Modifiers::none(),
  )
  assert_eq(deleted.document().text(), "")
  let restored = field_test_undo(deleted)
  assert_eq(restored.document().text(), "a")
  assert_true(restored.selection() == @text.TextSelection::new(1, 1).unwrap())

  let replacement_start = field_test_focused(
    field_test_selection(
      field_test_create("abcd", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      3,
      1,
    ),
  )
  let replacement = replacement_start
    .replace_selection("Q", field_test_measure, field_test_admit)
    .unwrap()
  assert_eq(replacement.document().text(), "aQd")
  let restored_replacement = field_test_undo(replacement)
  assert_eq(restored_replacement.document().text(), "abcd")
  assert_true(
    restored_replacement.selection() == @text.TextSelection::new(3, 1).unwrap(),
  )
}

///|
test "new content after undo clears redo while identical replacement retains it" {
  let start = field_test_focused(
    field_test_selection(
      field_test_create("ab", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      2,
      2,
    ),
  )
  let (edited, _) = field_test_text(start, "X")
  let undone = field_test_undo(edited)
  assert_true(undone.can_redo())

  let selected_b = field_test_key(
      undone,
      @primitives.ArrowLeft,
      @primitives.Modifiers::new(
        shift=true,
        control=false,
        alt=false,
        meta=false,
      ),
    ).0
  assert_true(selected_b.selection() == @text.TextSelection::new(2, 1).unwrap())
  let same_text = field_test_text(selected_b, "b").0
  assert_eq(same_text.document().text(), "ab")
  assert_true(same_text.selection() == @text.TextSelection::new(2, 2).unwrap())
  assert_true(same_text.revision() > selected_b.revision())
  assert_false(same_text.can_undo())
  assert_true(same_text.can_redo())
  let restored_redo = field_test_redo(same_text)
  assert_eq(restored_redo.document().text(), "abX")
  assert_true(restored_redo.selection() == edited.selection())

  let after_undo = field_test_undo(edited)
  let (branch, _) = field_test_text(after_undo, "Y")
  assert_eq(branch.document().text(), "abY")
  assert_false(branch.can_redo())
  assert_eq(field_test_redo(edited).document().text(), "abX")
}

///|
test "undo and redo are no-ops for empty history or unfocused fields" {
  let empty = field_test_create("", field_test_rect(0.0, 0.0, 100.0, 28.0))
  assert_false(empty.can_undo())
  assert_false(empty.can_redo())
  let empty_undo = field_test_undo(empty)
  let empty_redo = field_test_redo(empty)
  assert_eq(empty_undo.document().text(), "")
  assert_eq(empty_undo.revision(), empty.revision())
  assert_eq(empty_redo.revision(), empty.revision())

  let focused = field_test_focused(
    field_test_selection(
      field_test_create("a", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      1,
      1,
    ),
  )
  let edited = field_test_text(focused, "b").0
  let unfocused = edited.with_focus(false).unwrap()
  assert_true(unfocused.can_undo())
  let unchanged = field_test_undo(unfocused)
  assert_eq(unchanged.document().text(), "ab")
  assert_eq(unchanged.revision(), unfocused.revision())
  assert_false(unchanged.is_focused())
  assert_true(unchanged.can_undo())

  let undone = field_test_undo(edited)
  let unfocused_redo = undone.with_focus(false).unwrap()
  let still_undone = field_test_redo(unfocused_redo)
  assert_eq(still_undone.document().text(), "a")
  assert_eq(still_undone.revision(), unfocused_redo.revision())
  assert_true(still_undone.can_redo())
}

///|
test "restore callbacks fail without consuming either history stack" {
  let start = field_test_focused(
    field_test_selection(
      field_test_create("old", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      3,
      3,
    ),
  )
  let edited = field_test_text(start, "new").0
  let edited_revision = edited.revision()
  assert_true(
    edited.undo(_ => Err(@text_field.MeasurementFailed), field_test_admit)
    is Err(@text_field.MeasurementFailed),
  )
  assert_true(
    edited.undo(field_test_measure, (_, _) => Err(@text_field.AdmissionFailed))
    is Err(@text_field.AdmissionFailed),
  )
  assert_eq(edited.document().text(), "oldnew")
  assert_eq(edited.revision(), edited_revision)
  assert_true(edited.can_undo())
  assert_false(edited.can_redo())

  let undone = field_test_undo(edited)
  assert_eq(undone.document().text(), "old")
  let undone_revision = undone.revision()
  assert_true(
    undone.redo(_ => Err(@text_field.MeasurementFailed), field_test_admit)
    is Err(@text_field.MeasurementFailed),
  )
  assert_true(
    undone.redo(field_test_measure, (_, _) => Err(@text_field.AdmissionFailed))
    is Err(@text_field.AdmissionFailed),
  )
  assert_eq(undone.document().text(), "old")
  assert_eq(undone.revision(), undone_revision)
  assert_false(undone.can_undo())
  assert_true(undone.can_redo())
  assert_true(
    undone.handle_input(
      @primitives.TextInput(text="discard"),
      _ => Err(@text_field.MeasurementFailed),
      field_test_admit,
      field_test_hit,
    )
    is Err(@text_field.MeasurementFailed),
  )
  assert_true(
    undone.handle_input(
      @primitives.TextInput(text="discard"),
      field_test_measure,
      (_, _) => Err(@text_field.AdmissionFailed),
      field_test_hit,
    )
    is Err(@text_field.AdmissionFailed),
  )
  assert_eq(undone.document().text(), "old")
  assert_eq(undone.revision(), undone_revision)
  assert_true(undone.can_redo())
  assert_eq(field_test_redo(undone).document().text(), "oldnew")
}

///|
test "undo restores against current bounds focus and advances current revision" {
  let start = field_test_focused(
    field_test_create("base", field_test_rect(0.0, 0.0, 80.0, 28.0)),
  )
  let edited = field_test_text(start, "x").0
  let resized = edited
    .with_bounds(field_test_rect(4.0, 2.0, 140.0, 32.0))
    .unwrap()
  let revision = resized.revision()
  let undone = field_test_undo(resized)
  assert_eq(undone.document().text(), "base")
  assert_true(undone.bounds() == resized.bounds())
  assert_true(undone.is_focused())
  assert_eq(undone.revision(), revision + 1)
  assert_true(undone.measurement().document() == undone.document())
}

///|
test "undo redo shortcuts are modifier specific and Character keys do not type" {
  let start = field_test_focused(
    field_test_selection(
      field_test_create("a", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      1,
      1,
    ),
  )
  let (edited, _) = field_test_text(start, "b")
  let control = @primitives.Modifiers::new(
    shift=false,
    control=true,
    alt=false,
    meta=false,
  )
  let shift_control = @primitives.Modifiers::new(
    shift=true,
    control=true,
    alt=false,
    meta=false,
  )
  let meta = @primitives.Modifiers::new(
    shift=false,
    control=false,
    alt=false,
    meta=true,
  )
  let shift_meta = @primitives.Modifiers::new(
    shift=true,
    control=false,
    alt=false,
    meta=true,
  )
  let alt_control = @primitives.Modifiers::new(
    shift=false,
    control=true,
    alt=true,
    meta=false,
  )

  let (undone, _) = field_test_key(edited, @primitives.Character("z"), control)
  assert_eq(undone.document().text(), "a")
  let (redone, _) = field_test_key(
    undone,
    @primitives.Character("Z"),
    shift_control,
  )
  assert_eq(redone.document().text(), "ab")
  let (undone_meta, _) = field_test_key(
    redone,
    @primitives.Character("z"),
    meta,
  )
  assert_eq(undone_meta.document().text(), "a")
  let (redone_meta, _) = field_test_key(
    undone_meta,
    @primitives.Character("Z"),
    shift_meta,
  )
  assert_eq(redone_meta.document().text(), "ab")
  let (redo_y, _) = field_test_key(
    field_test_undo(redone_meta),
    @primitives.Character("y"),
    control,
  )
  assert_eq(redo_y.document().text(), "ab")

  let (ignored_alt, _) = field_test_key(
    edited,
    @primitives.Character("z"),
    alt_control,
  )
  assert_eq(ignored_alt.document().text(), "ab")
  assert_true(ignored_alt.can_undo())
  let (ignored_shortcut, _) = field_test_key(
    edited,
    @primitives.Character("q"),
    control,
  )
  assert_eq(ignored_shortcut.document().text(), "ab")
  assert_true(ignored_shortcut.can_undo())
  let (plain_character, _) = field_test_key(
    edited,
    @primitives.Character("z"),
    @primitives.Modifiers::none(),
  )
  assert_eq(plain_character.document().text(), "ab")
  assert_true(plain_character.can_undo())
  let (non_character, _) = field_test_key(edited, @primitives.Enter, control)
  assert_eq(non_character.document().text(), "ab")
  assert_true(non_character.can_undo())
}
