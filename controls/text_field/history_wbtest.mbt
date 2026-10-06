///|
fn history_test_document(
  text : String,
  anchor : Int,
  head : Int,
) -> @text.TextDocument {
  @text.TextDocument::new(text)
  .unwrap()
  .with_selection(@text.TextSelection::new(anchor, head).unwrap())
  .unwrap()
}

///|
fn history_test_record(
  history : FieldHistory,
  before : @text.TextDocument,
  after : @text.TextDocument,
) -> FieldHistory raise {
  match history.record(before, after) {
    Ok(value) => value
    Err(_) => fail("valid history endpoints should record")
  }
}

///|
fn history_test_symbol(index : Int) -> String {
  String::from_array([(0x21 + index).unsafe_to_char()])
}

///|
fn history_test_undo_depth(history : FieldHistory) -> Int {
  let mut current = history
  let mut depth = 0
  while current.can_undo() {
    current = current.move_undo()
    depth += 1
  }
  depth
}

///|
fn history_test_undo_before_texts(history : FieldHistory) -> Array[String] {
  let mut current = history
  let texts = []
  while current.can_undo() {
    match current.undo_entry() {
      Some(entry) => texts.push(entry.before.text())
      None => ()
    }
    current = current.move_undo()
  }
  texts
}

///|
test "field history stores directional endpoints and moves without charge changes" {
  let before = history_test_document("ab", 2, 0)
  let after = history_test_document("abc", 3, 1)
  let recorded = history_test_record(FieldHistory::empty(), before, after)
  assert_true(recorded.can_undo())
  assert_false(recorded.can_redo())
  assert_eq(recorded.payload_bytes, 5)
  let entry = recorded.undo_entry().unwrap()
  assert_true(entry.before == before)
  assert_true(entry.after == after)
  assert_eq(entry.before.selection().anchor(), 2)
  assert_eq(entry.before.selection().head(), 0)
  assert_eq(entry.after.selection().anchor(), 3)
  assert_eq(entry.after.selection().head(), 1)

  let undone = recorded.move_undo()
  assert_false(undone.can_undo())
  assert_true(undone.can_redo())
  assert_eq(undone.payload_bytes, 5)
  let redo = undone.redo_entry().unwrap()
  assert_true(redo.before == before)
  assert_true(redo.after == after)
  let redone = undone.move_redo()
  assert_true(redone.can_undo())
  assert_false(redone.can_redo())
  assert_eq(redone.payload_bytes, 5)
  assert_true(redone.undo_entry().unwrap().after == after)
}

///|
test "equal content selection-only record preserves redo endpoints" {
  let before = history_test_document("ab", 2, 0)
  let after = history_test_document("abc", 3, 1)
  let recorded = history_test_record(FieldHistory::empty(), before, after)
  let undone = recorded.move_undo()
  let selection_only_before = history_test_document("ab", 0, 2)
  let selection_only_after = history_test_document("ab", 1, 1)
  let unchanged = history_test_record(
    undone, selection_only_before, selection_only_after,
  )
  assert_true(unchanged.can_redo())
  assert_eq(unchanged.payload_bytes, 5)
  let redo = unchanged.redo_entry().unwrap()
  assert_true(redo.before == before)
  assert_true(redo.after == after)
  assert_eq(redo.after.selection().anchor(), 3)
  assert_eq(redo.after.selection().head(), 1)
}

///|
test "field history branches do not mutate retained undo redo or edit snapshots" {
  let before = history_test_document("ab", 2, 0)
  let after = history_test_document("abc", 3, 1)
  let recorded = history_test_record(FieldHistory::empty(), before, after)

  // Moving on one branch leaves the original undo snapshot intact.
  let moved = recorded.move_undo()
  assert_true(recorded.can_undo())
  assert_false(recorded.can_redo())
  assert_true(moved.can_redo())
  assert_true(recorded.undo_entry().unwrap().after == after)

  // Editing a branch clears only that branch's redo stack.
  let branched_edit = history_test_record(
    moved,
    history_test_document("ab", 0, 2),
    history_test_document("acb", 3, 1),
  )
  assert_true(branched_edit.can_undo())
  assert_false(branched_edit.can_redo())
  assert_true(moved.can_redo())
  assert_true(moved.redo_entry().unwrap().after == after)
  assert_true(recorded.can_undo())

  // A redo transition on a second branch also leaves the first branch intact.
  let redone = moved.move_redo()
  assert_true(redone.can_undo())
  assert_true(moved.can_redo())
  assert_true(redone.undo_entry().unwrap().after == after)
}

///|
test "field history independently caps entries and evicts oldest whole group" {
  let mut history = FieldHistory::empty()
  for index in 0..<65 {
    let before_text = "a".repeat(index + 1)
    let after_text = "b".repeat(index + 1)
    history = history_test_record(
      history,
      history_test_document(before_text, 0, 0),
      history_test_document(after_text, 0, 0),
    )
  }
  assert_eq(history_test_undo_depth(history), 64)
  assert_eq(history.payload_bytes, 4288)
  let entries = history_test_undo_before_texts(history)
  assert_eq(entries.length(), 64)
  assert_eq(entries[0], "a".repeat(65))
  assert_eq(entries[63], "a".repeat(2))
  assert_false(entries[63] == "a")
}

///|
test "field history independently caps logical bytes and evicts whole oldest group" {
  let mut history = FieldHistory::empty()
  for index in 0..<8 {
    let before_text = history_test_symbol(index).repeat(4096)
    let after_text = history_test_symbol(index + 8).repeat(4096)
    history = history_test_record(
      history,
      history_test_document(before_text, 0, 0),
      history_test_document(after_text, 0, 0),
    )
  }
  assert_eq(history_test_undo_depth(history), 8)
  assert_eq(history.payload_bytes, 65536)

  let after_two_undos = history.move_undo().move_undo()
  assert_eq(after_two_undos.payload_bytes, 65536)
  let after_one_redo = after_two_undos.move_redo()
  assert_eq(after_one_redo.payload_bytes, 65536)

  let branched = history_test_record(
    history,
    history_test_document("s", 0, 0),
    history_test_document("t", 0, 0),
  )
  assert_eq(history_test_undo_depth(branched), 8)
  assert_eq(branched.payload_bytes, 7 * 8192 + 2)
  assert_eq(history_test_undo_depth(history), 8)
  let entries = history_test_undo_before_texts(branched)
  assert_eq(entries.length(), 8)
  assert_eq(entries[0], "s")
  assert_eq(entries[1], history_test_symbol(7).repeat(4096))
  assert_eq(entries[7], history_test_symbol(1).repeat(4096))
}

///|
test "field history validates endpoint text with field errors before recording" {
  let too_large = history_test_document("x".repeat(4097), 0, 0)
  let valid = history_test_document("ok", 0, 0)
  assert_true(
    FieldHistory::empty().record(too_large, valid) is Err(TextTooLarge),
  )
  let forbidden = history_test_document("bad\ntext", 0, 0)
  assert_true(
    FieldHistory::empty().record(forbidden, valid) is Err(ForbiddenInput),
  )
}
