///|
fn text_composition_test_document(value : String) -> @text.TextDocument raise {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => fail("well-formed composition test text should construct")
  }
}

///|
fn text_composition_test_range(start : Int, end : Int) -> @text.TextRange raise {
  match @text.TextRange::new(start, end) {
    Ok(range) => range
    Err(_) =>
      fail("ordered non-negative composition test range should construct")
  }
}

///|
fn text_composition_test_selection(
  anchor : Int,
  head : Int,
) -> @text.TextSelection raise {
  match @text.TextSelection::new(anchor, head) {
    Ok(selection) => selection
    Err(_) => fail("non-negative composition test selection should construct")
  }
}

///|
fn text_composition_test_begin(
  document : @text.TextDocument,
  range : @text.TextRange,
) -> @text.TextComposition raise {
  match @text.TextComposition::begin(document, range) {
    Ok(value) => value
    Err(_) => fail("valid composition range should begin")
  }
}

///|
fn text_composition_test_update(
  composition : @text.TextComposition,
  preedit : String,
  selection : @text.TextSelection,
) -> @text.TextComposition raise {
  match composition.update(preedit, selection) {
    Ok(value) => value
    Err(_) => fail("valid composition update should succeed")
  }
}

///|
test "begin keeps the original directional selection and marks the target" {
  let original = text_composition_test_document("a😀z")
    .with_selection(text_composition_test_selection(3, 1))
    .unwrap()
  let target = text_composition_test_range(1, 3)
  let started = text_composition_test_begin(original, target)
  assert_true(started.status() is @text.Active)
  assert_true(started.document() == original)
  assert_true(
    started.document().selection() == text_composition_test_selection(3, 1),
  )
  assert_true(started.marked_range() == Some(target))
  assert_eq(original.text(), "a😀z")
  assert_true(original.selection() == text_composition_test_selection(3, 1))

  let empty_target = text_composition_test_range(1, 1)
  let empty_started = text_composition_test_begin(
    text_composition_test_document("ab"),
    empty_target,
  )
  assert_true(empty_started.document().text() == "ab")
  assert_true(empty_started.marked_range() == Some(empty_target))
  let empty_preview = text_composition_test_update(
    empty_started,
    "",
    text_composition_test_selection(0, 0),
  )
  assert_eq(empty_preview.document().text(), "ab")
  assert_true(
    empty_preview.document().selection() ==
    text_composition_test_selection(1, 1),
  )
  assert_true(empty_preview.marked_range() == Some(empty_target))
}

///|
test "begin wraps out-of-bounds and split-surrogate range failures" {
  let emoji = text_composition_test_document("😀")
  assert_true(
    @text.TextComposition::begin(emoji, text_composition_test_range(0, 3))
    is Err(@text.InvalidText(@text.OutOfBounds)),
  )
  assert_true(
    @text.TextComposition::begin(emoji, text_composition_test_range(1, 1))
    is Err(@text.InvalidText(@text.SplitSurrogate)),
  )
}

///|
test "updates replace the original target and rebase directional UTF-16 selection" {
  let original = text_composition_test_document("a😀z")
    .with_selection(text_composition_test_selection(3, 1))
    .unwrap()
  let started = text_composition_test_begin(
    original,
    text_composition_test_range(1, 3),
  )
  let first = text_composition_test_update(
    started,
    "に",
    text_composition_test_selection(1, 1),
  )
  assert_eq(first.document().text(), "aにz")
  assert_true(
    first.document().selection() == text_composition_test_selection(2, 2),
  )
  assert_true(first.marked_range() == Some(text_composition_test_range(1, 2)))

  let second = text_composition_test_update(
    first,
    "日本",
    text_composition_test_selection(2, 0),
  )
  assert_eq(second.document().text(), "a日本z")
  assert_true(
    second.document().selection() == text_composition_test_selection(3, 1),
  )
  assert_true(second.marked_range() == Some(text_composition_test_range(1, 3)))
  assert_false(second.document().text() == "aに日本z")

  // Old values remain stable after later successful transitions.
  assert_eq(started.document().text(), "a😀z")
  assert_true(
    started.document().selection() == text_composition_test_selection(3, 1),
  )
  assert_eq(first.document().text(), "aにz")
  assert_true(
    first.document().selection() == text_composition_test_selection(2, 2),
  )
  assert_eq(original.text(), "a😀z")
}

///|
test "preview preserves Unicode sequences and empty targets" {
  let original = text_composition_test_document("A|Z")
  let started = text_composition_test_begin(
    original,
    text_composition_test_range(2, 2),
  )
  let preedit = "e\u0301👩‍💻\n\u0000"
  let preview = text_composition_test_update(
    started,
    preedit,
    text_composition_test_selection(2, 7),
  )
  assert_eq(preview.document().text(), "A|" + preedit + "Z")
  assert_true(
    preview.document().selection() == text_composition_test_selection(4, 9),
  )
  assert_true(
    preview.marked_range() == Some(text_composition_test_range(2, 11)),
  )
  assert_eq(started.document().text(), "A|Z")
}

///|
test "commit replaces the original range with final text and deletes on empty text" {
  let original = text_composition_test_document("a😀z")
  let started = text_composition_test_begin(
    original,
    text_composition_test_range(1, 3),
  )
  let preview = text_composition_test_update(
    started,
    "に",
    text_composition_test_selection(1, 1),
  )
  let committed = preview.commit("語").unwrap()
  assert_true(committed.status() is @text.Committed)
  assert_eq(committed.document().text(), "a語z")
  assert_true(
    committed.document().selection() == text_composition_test_selection(2, 2),
  )
  assert_true(committed.marked_range() is None)
  assert_eq(preview.document().text(), "aにz")
  assert_eq(started.document().text(), "a😀z")

  let deleted = started.commit("").unwrap()
  assert_true(deleted.status() is @text.Committed)
  assert_eq(deleted.document().text(), "az")
  assert_true(
    deleted.document().selection() == text_composition_test_selection(1, 1),
  )
  assert_true(deleted.marked_range() is None)
}

///|
test "cancel restores exact original text and backward selection" {
  let original = text_composition_test_document("left😀right")
    .with_selection(text_composition_test_selection(10, 1))
    .unwrap()
  let started = text_composition_test_begin(
    original,
    text_composition_test_range(4, 6),
  )
  let preview = text_composition_test_update(
    started,
    "日本",
    text_composition_test_selection(0, 1),
  )
  let cancelled = preview.cancel().unwrap()
  assert_true(cancelled.status() is @text.Cancelled)
  assert_eq(cancelled.document().text(), "left😀right")
  assert_true(
    cancelled.document().selection() == text_composition_test_selection(10, 1),
  )
  assert_true(cancelled.marked_range() is None)
  assert_eq(preview.document().text(), "left日本right")
  assert_true(
    preview.document().selection() == text_composition_test_selection(4, 5),
  )
  assert_eq(started.document().text(), "left😀right")
}

///|
test "validation order and terminal rejection preserve all snapshots" {
  let source = text_composition_test_document("a😀z")
  let active = text_composition_test_begin(
    source,
    text_composition_test_range(1, 3),
  )
  let high_surrogate = "😀".unsafe_substring(start=0, end=1)
  assert_true(
    active.update(high_surrogate, text_composition_test_selection(0, 40))
    is Err(@text.InvalidText(@text.MalformedUtf16)),
  )
  assert_true(
    active.update("😀", text_composition_test_selection(1, 3))
    is Err(@text.InvalidText(@text.OutOfBounds)),
  )
  assert_true(
    active.update("😀", text_composition_test_selection(1, 1))
    is Err(@text.InvalidText(@text.SplitSurrogate)),
  )
  assert_true(
    active.commit(high_surrogate)
    is Err(@text.InvalidText(@text.MalformedUtf16)),
  )
  assert_eq(active.document().text(), "a😀z")
  assert_true(active.status() is @text.Active)
  assert_true(active.marked_range() == Some(text_composition_test_range(1, 3)))

  let committed = active.commit("語").unwrap()
  let cancelled = active.cancel().unwrap()
  assert_true(
    committed.update(high_surrogate, text_composition_test_selection(0, 0))
    is Err(@text.NotActive),
  )
  assert_true(committed.commit(high_surrogate) is Err(@text.NotActive))
  assert_true(committed.cancel() is Err(@text.NotActive))
  assert_true(
    cancelled.update(high_surrogate, text_composition_test_selection(0, 0))
    is Err(@text.NotActive),
  )
  assert_true(cancelled.commit(high_surrogate) is Err(@text.NotActive))
  assert_true(cancelled.cancel() is Err(@text.NotActive))

  assert_eq(committed.document().text(), "a語z")
  assert_eq(cancelled.document().text(), "a😀z")
  assert_eq(active.document().text(), "a😀z")
  assert_true(active.status() is @text.Active)
}
