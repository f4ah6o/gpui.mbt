///|
fn field_test_repeat_key(
  field : @text_field.TextField,
  key : @primitives.Key,
  modifiers : @primitives.Modifiers,
) -> (@text_field.TextField, @text_field.TextFieldAction?) raise {
  field_test_event(field, @primitives.KeyPressed(key~, modifiers~, repeat=true))
}

///|
fn field_test_repeat_control(shift? : Bool = false) -> @primitives.Modifiers {
  @primitives.Modifiers::new(shift~, control=true, alt=false, meta=false)
}

///|
test "repeated printable key inserts nothing and following text inserts once" {
  let original = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 100.0, 28.0)),
  )
  let (key_only, action) = field_test_repeat_key(
    original,
    @primitives.Character("a"),
    @primitives.Modifiers::none(),
  )
  assert_true(key_only.document() == original.document())
  assert_eq(key_only.revision(), original.revision())
  assert_true(action is None)
  assert_false(key_only.can_undo())
  let inserted = field_test_text(key_only, "a").0
  assert_eq(inserted.document().text(), "a")
  assert_eq(inserted.revision(), original.revision() + 1)
  let undone = field_test_undo(inserted)
  assert_eq(undone.document().text(), "")
  assert_false(undone.can_undo())
}

///|
test "repeated text and backspace retain separate content history groups" {
  let original = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 100.0, 28.0)),
  )
  let physical = field_test_text(original, "a").0
  let mut repeated = physical
  for _ in 0..<2 {
    let key_only = field_test_repeat_key(
        repeated,
        @primitives.Character("a"),
        @primitives.Modifiers::none(),
      ).0
    assert_true(key_only.document() == repeated.document())
    repeated = field_test_text(key_only, "a").0
  }
  assert_eq(repeated.document().text(), "aaa")
  let first_undo = field_test_undo(repeated)
  assert_eq(first_undo.document().text(), "aa")
  let second_undo = field_test_undo(first_undo)
  assert_eq(second_undo.document().text(), "a")
  let third_undo = field_test_undo(second_undo)
  assert_eq(third_undo.document().text(), "")
  assert_false(third_undo.can_undo())
  let deleted_once = field_test_repeat_key(
      repeated,
      @primitives.Backspace,
      @primitives.Modifiers::none(),
    ).0
  let deleted_twice = field_test_repeat_key(
      deleted_once,
      @primitives.Backspace,
      @primitives.Modifiers::none(),
    ).0
  assert_eq(deleted_twice.document().text(), "a")
  let restored_once = field_test_undo(deleted_twice)
  assert_eq(restored_once.document().text(), "aa")
  assert_eq(field_test_undo(restored_once).document().text(), "aaa")
  assert_eq(repeated.document().text(), "aaa")
}

///|
test "repeated navigation adds no history and preserves existing redo" {
  let original = field_test_focused(
    field_test_selection(
      field_test_create("abc", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      3,
      3,
    ),
  )
  let left_once = field_test_repeat_key(
      original,
      @primitives.ArrowLeft,
      @primitives.Modifiers::none(),
    ).0
  let left_twice = field_test_repeat_key(
      left_once,
      @primitives.ArrowLeft,
      @primitives.Modifiers::none(),
    ).0
  assert_eq(left_twice.selection().head(), 1)
  assert_eq(left_twice.document().text(), "abc")
  assert_false(left_twice.can_undo())
  let edited = field_test_text(original, "d").0
  let undone = field_test_undo(edited)
  let moved = field_test_repeat_key(
      undone,
      @primitives.Home,
      @primitives.Modifiers::none(),
    ).0
  assert_eq(moved.selection().head(), 0)
  assert_false(moved.can_undo())
  assert_true(moved.can_redo())
  let redone = field_test_redo(moved)
  assert_eq(redone.document().text(), "abcd")
  assert_true(redone.selection() == edited.selection())
}

///|
test "repeated undo and redo shortcuts use the existing per-press semantics" {
  let original = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 100.0, 28.0)),
  )
  let first = field_test_text(original, "a").0
  let second = field_test_text(first, "b").0
  let undone_once = field_test_repeat_key(
      second,
      @primitives.Character("z"),
      field_test_repeat_control(),
    ).0
  assert_eq(undone_once.document().text(), "a")
  let undone_twice = field_test_repeat_key(
      undone_once,
      @primitives.Character("z"),
      field_test_repeat_control(),
    ).0
  assert_eq(undone_twice.document().text(), "")
  assert_false(undone_twice.can_undo())
  let redone_once = field_test_repeat_key(
      undone_twice,
      @primitives.Character("y"),
      field_test_repeat_control(),
    ).0
  assert_eq(redone_once.document().text(), "a")
  let redone_twice = field_test_repeat_key(
      redone_once,
      @primitives.Character("Z"),
      field_test_repeat_control(shift=true),
    ).0
  assert_eq(redone_twice.document().text(), "ab")
  assert_false(redone_twice.can_redo())
  let no_more_redo = field_test_repeat_key(
      redone_twice,
      @primitives.Character("y"),
      field_test_repeat_control(),
    ).0
  assert_eq(no_more_redo.revision(), redone_twice.revision())
  assert_eq(field_test_undo(redone_twice).document().text(), "a")
}

///|
test "repeated clipboard submit and blur keys still emit their owner actions" {
  let original = field_test_focused(
    field_test_selection(
      field_test_create("abcd", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      3,
      1,
    ),
  )
  for _ in 0..<2 {
    let (copied, copy) = field_test_repeat_key(
      original,
      @primitives.Character("c"),
      field_test_repeat_control(),
    )
    assert_true(copy is Some(@text_field.Copy("bc")))
    assert_true(copied.document() == original.document())
    assert_eq(copied.revision(), original.revision())
    assert_false(copied.can_undo())
    let (unchanged, cut) = field_test_repeat_key(
      original,
      @primitives.Character("x"),
      field_test_repeat_control(),
    )
    assert_true(unchanged.document() == original.document())
    assert_false(unchanged.can_undo())
    match cut {
      Some(@text_field.Cut(text="bc", candidate~)) => {
        assert_eq(candidate.document().text(), "ad")
        let restored = field_test_undo(candidate)
        assert_true(restored.document() == original.document())
        assert_false(restored.can_undo())
      }
      _ => fail("repeated cut must prepare the same owner transaction")
    }
    let (pasted, paste) = field_test_repeat_key(
      original,
      @primitives.Character("v"),
      field_test_repeat_control(),
    )
    assert_true(paste is Some(@text_field.Paste))
    assert_true(pasted.document() == original.document())
    assert_false(pasted.can_undo())
    let (submitted, submit) = field_test_repeat_key(
      original,
      @primitives.Enter,
      @primitives.Modifiers::none(),
    )
    assert_true(submit is Some(@text_field.Submit))
    assert_true(submitted.document() == original.document())
    assert_eq(submitted.revision(), original.revision())
    let (same, blur) = field_test_repeat_key(
      original,
      @primitives.Escape,
      @primitives.Modifiers::none(),
    )
    assert_true(blur is Some(@text_field.Blur))
    assert_true(same.is_focused())
  }
}
