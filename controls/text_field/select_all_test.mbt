///|
fn field_test_select_all_modifiers(meta : Bool) -> @primitives.Modifiers {
  @primitives.Modifiers::new(shift=false, control=!meta, alt=false, meta~)
}

///|
test "Ctrl and Meta A select all with a forward UTF-16 selection" {
  for meta in [false, true] {
    let original = field_test_focused(
      field_test_selection(
        field_test_create("a😀日本", field_test_rect(0.0, 0.0, 100.0, 28.0)),
        5,
        1,
      ),
    )
    let (selected, action) = field_test_key(
      original,
      @primitives.Character(if meta { "A" } else { "a" }),
      field_test_select_all_modifiers(meta),
    )
    assert_true(action is None)
    assert_eq(selected.document().text(), "a😀日本")
    assert_true(selected.selection() == @text.TextSelection::new(0, 5).unwrap())
    assert_eq(selected.selected_text(), "a😀日本")
    assert_true(selected.is_focused())
    assert_eq(selected.revision(), original.revision() + 1)
    assert_true(selected.measurement().document() == selected.document())
    assert_true(original.selection() == @text.TextSelection::new(5, 1).unwrap())
    assert_false(selected.can_undo())
    assert_false(selected.can_redo())
  }
}

///|
test "repeated select all and empty selection are revision no-ops" {
  let original = field_test_focused(
    field_test_create("abc", field_test_rect(0.0, 0.0, 100.0, 28.0)),
  )
  let selected = field_test_key(
      original,
      @primitives.Character("a"),
      field_test_select_all_modifiers(false),
    ).0
  let (repeated, action) = field_test_event(
    selected,
    @primitives.KeyPressed(
      key=@primitives.Character("a"),
      modifiers=field_test_select_all_modifiers(false),
      repeat=true,
    ),
  )
  assert_true(action is None)
  assert_true(repeated.document() == selected.document())
  assert_eq(repeated.revision(), selected.revision())
  assert_eq(repeated.scroll_offset(), selected.scroll_offset())
  let empty = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 100.0, 28.0)),
  )
  let (still_empty, empty_action) = field_test_key(
    empty,
    @primitives.Character("a"),
    field_test_select_all_modifiers(true),
  )
  assert_true(empty_action is None)
  assert_true(still_empty.document() == empty.document())
  assert_eq(still_empty.revision(), empty.revision())
}

///|
test "select all rebinds copied layout and rejects a stale document hit" {
  let original = field_test_focused(
    field_test_create("a😀b", field_test_rect(0.0, 0.0, 20.0, 28.0)),
  )
  let stale_measurement = original.measurement()
  let selected = original
    .handle_input(
      @primitives.KeyPressed(
        key=@primitives.Character("a"),
        modifiers=field_test_select_all_modifiers(false),
        repeat=false,
      ),
      _ => Err(@text_field.MeasurementFailed),
      (_, _) => Err(@text_field.AdmissionFailed),
      (_, _) => Err(@text_field.HitTestFailed),
    )
    .unwrap().0
  assert_true(stale_measurement.document() == original.document())
  assert_true(stale_measurement.document() != selected.document())
  assert_true(selected.measurement().document() == selected.document())
  let selected_carets = selected.measurement().carets()
  let old_carets = stale_measurement.carets()
  assert_eq(selected_carets.length(), old_carets.length())
  for index in 0..<selected_carets.length() {
    assert_eq(
      selected_carets[index].utf16_offset(),
      old_carets[index].utf16_offset(),
    )
    assert_eq(
      selected_carets[index].is_cursor_position(),
      old_carets[index].is_cursor_position(),
    )
    assert_true(selected_carets[index].strong() == old_carets[index].strong())
    assert_true(selected_carets[index].weak() == old_carets[index].weak())
  }
  assert_true(selected.scroll_offset() > original.scroll_offset())
  let copies = selected.measurement().carets()
  copies.clear()
  assert_eq(selected.measurement().carets().length(), 4)

  let point = @primitives.Point::new(8.0, 8.0).unwrap()
  assert_true(
    selected.handle_input(
      @primitives.PointerButtonPressed(
        position=point,
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
      field_test_measure,
      field_test_admit,
      (_, hit_point) => field_test_hit(original.document(), hit_point),
    )
    is Err(@text_field.InvalidHitResult),
  )
  let fresh = selected
    .handle_input(
      @primitives.PointerButtonPressed(
        position=point,
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
      field_test_measure,
      field_test_admit,
      field_test_hit,
    )
    .unwrap().0
  assert_true(fresh.measurement().document() == fresh.document())
  assert_true(fresh.selection().is_collapsed())
  assert_eq(fresh.revision(), selected.revision() + 1)
}

///|
test "select all preserves both undo redo stacks and their original endpoints" {
  let original = field_test_focused(
    field_test_selection(
      field_test_create("a", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      1,
      1,
    ),
  )
  let ab = field_test_text(original, "b").0
  let abc = field_test_text(ab, "c").0
  let undone = field_test_undo(abc)
  assert_true(undone.can_undo())
  assert_true(undone.can_redo())
  let selected = field_test_key(
      undone,
      @primitives.Character("a"),
      field_test_select_all_modifiers(false),
    ).0
  assert_true(selected.can_undo())
  assert_true(selected.can_redo())
  let redone = field_test_redo(selected)
  assert_true(redone.document() == abc.document())
  let back_to_a = field_test_undo(selected)
  assert_true(back_to_a.document() == original.document())
  assert_false(back_to_a.can_undo())
  assert_true(field_test_redo(back_to_a).document() == ab.document())
  assert_true(undone.document() == ab.document())
}

///|
test "select all replacement keeps each successful input as one history group" {
  let original = field_test_focused(
    field_test_selection(
      field_test_create("Hello 日本", field_test_rect(0.0, 0.0, 120.0, 28.0)),
      8,
      8,
    ),
  )
  let selected = field_test_key(
      original,
      @primitives.Character("a"),
      field_test_select_all_modifiers(false),
    ).0
  let a = field_test_text(selected, "a").0
  let ab = field_test_text(a, "b").0
  let abc = field_test_text(ab, "c").0
  assert_eq(abc.document().text(), "abc")
  assert_true(abc.selection() == @text.TextSelection::new(3, 3).unwrap())
  assert_true(field_test_undo(abc).document() == ab.document())
  assert_true(field_test_undo(ab).document() == a.document())
  let restored = field_test_undo(a)
  assert_true(restored.document() == selected.document())
  assert_false(restored.can_undo())
  assert_true(field_test_redo(restored).document() == a.document())
}

///|
test "unfocused plain and Alt modified A leave state and history unchanged" {
  let focused = field_test_focused(
    field_test_create("abc", field_test_rect(0.0, 0.0, 100.0, 28.0)),
  )
  let edited = field_test_text(focused, "X").0
  let unfocused = edited.with_focus(false).unwrap()
  for meta in [false, true] {
    let (unchanged, action) = field_test_key(
      unfocused,
      @primitives.Character("a"),
      field_test_select_all_modifiers(meta),
    )
    assert_true(action is None)
    assert_true(unchanged.document() == unfocused.document())
    assert_eq(unchanged.revision(), unfocused.revision())
    assert_false(unchanged.is_focused())
    assert_true(unchanged.can_undo())
  }
  for
    modifiers in [
      @primitives.Modifiers::none(),
      @primitives.Modifiers::new(
        shift=false,
        control=true,
        alt=true,
        meta=false,
      ),
    ] {
    let (unchanged, action) = field_test_key(
      edited,
      @primitives.Character("a"),
      modifiers,
    )
    assert_true(action is None)
    assert_true(unchanged.document() == edited.document())
    assert_eq(unchanged.revision(), edited.revision())
    assert_true(unchanged.can_undo())
  }
}
