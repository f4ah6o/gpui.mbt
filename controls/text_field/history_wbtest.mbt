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
test "field history charges UTF-8 bytes from both directional endpoints" {
  // UTF-8 byte counts are independent of the UTF-16 selection offsets:
  // "é🙂" is 2 + 4 bytes and "猫é" is 3 + 2 bytes.
  let before = history_test_document("é🙂", 3, 1)
  let after = history_test_document("猫é", 2, 0)
  let recorded = history_test_record(FieldHistory::empty(), before, after)
  assert_eq(recorded.payload_bytes, 11)
  assert_true(recorded.undo_entry().unwrap().before == before)
  assert_true(recorded.undo_entry().unwrap().after == after)

  let undone = recorded.move_undo()
  assert_eq(undone.payload_bytes, 11)
  let redone = undone.move_redo()
  assert_eq(redone.payload_bytes, 11)
  assert_true(redone.undo_entry().unwrap().before == before)
  assert_true(redone.undo_entry().unwrap().after == after)
}

///|
test "field history drops redo charge before retaining and evicting whole entries" {
  let mut full = FieldHistory::empty()
  for index in 0..<64 {
    // Each retained edit costs 1,024 bytes: 512 ASCII bytes at each endpoint.
    full = history_test_record(
      full,
      history_test_document(history_test_symbol(index).repeat(512), 0, 0),
      history_test_document(history_test_symbol(90).repeat(512), 0, 0),
    )
  }
  assert_eq(history_test_undo_depth(full), 64)
  assert_eq(full.payload_bytes, 65536)

  // The just-undone 1,024-byte entry remains charged while in redo. A new
  // small edit can reuse that space without evicting an undo entry.
  let after_undo = full.move_undo()
  assert_eq(history_test_undo_depth(after_undo), 63)
  assert_true(after_undo.can_redo())
  assert_eq(after_undo.payload_bytes, 65536)
  let small_before = history_test_document(
    history_test_symbol(70).repeat(512),
    0,
    0,
  )
  let small_after = history_test_document(
    history_test_symbol(71).repeat(512),
    0,
    0,
  )
  let reused_redo_charge = history_test_record(
    after_undo, small_before, small_after,
  )
  let small_entries = history_test_undo_before_texts(reused_redo_charge)
  assert_eq(history_test_undo_depth(reused_redo_charge), 64)
  assert_eq(reused_redo_charge.payload_bytes, 65536)
  assert_false(reused_redo_charge.can_redo())
  assert_eq(small_entries.length(), 64)
  assert_eq(small_entries[0], small_before.text())
  assert_eq(small_entries[1], history_test_symbol(62).repeat(512))
  assert_eq(small_entries[63], history_test_symbol(0).repeat(512))

  // One maximum-sized edit (4,096 bytes at each endpoint) needs 8,192 bytes.
  // The remaining 63 small undo entries provide only 1,024 bytes each, so
  // seven entire oldest entries must be discarded to fit this one edit.
  let large_before = history_test_document("L".repeat(4096), 0, 0)
  let large_after = history_test_document("R".repeat(4096), 0, 0)
  let large_branch = history_test_record(after_undo, large_before, large_after)
  let large_entries = history_test_undo_before_texts(large_branch)
  assert_eq(history_test_undo_depth(large_branch), 57)
  assert_eq(large_branch.payload_bytes, 65536)
  assert_false(large_branch.can_redo())
  assert_eq(large_entries.length(), 57)
  assert_eq(large_entries[0], large_before.text())
  assert_eq(large_entries[1], history_test_symbol(62).repeat(512))
  assert_eq(large_entries[56], history_test_symbol(7).repeat(512))

  // The shared snapshots remain immutable after both branches are recorded.
  assert_eq(history_test_undo_depth(full), 64)
  assert_false(full.can_redo())
  assert_eq(full.payload_bytes, 65536)
  assert_eq(history_test_undo_depth(after_undo), 63)
  assert_true(after_undo.can_redo())
  assert_eq(after_undo.payload_bytes, 65536)
  assert_true(
    after_undo.redo_entry().unwrap().before == full.undo_entry().unwrap().before,
  )
  assert_eq(
    history_test_undo_before_texts(after_undo)[62],
    history_test_symbol(0).repeat(512),
  )
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
