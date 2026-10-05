///|
fn text_test_document(value : String) -> @text.TextDocument raise {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => fail("well-formed test text should construct")
  }
}

///|
fn text_test_range(start : Int, end : Int) -> @text.TextRange raise {
  match @text.TextRange::new(start, end) {
    Ok(range) => range
    Err(_) => fail("ordered non-negative test range should construct")
  }
}

///|
fn text_test_selection(anchor : Int, head : Int) -> @text.TextSelection raise {
  match @text.TextSelection::new(anchor, head) {
    Ok(selection) => selection
    Err(_) => fail("non-negative test selection should construct")
  }
}

///|
test "empty documents and edits preserve UTF-16 selection semantics" {
  let empty = text_test_document("")
  assert_eq(empty.text(), "")
  assert_eq(empty.utf16_length(), 0)
  assert_true(empty.selection() == text_test_selection(0, 0))
  assert_eq(empty.selected_text(), "")
  assert_true(empty.slice(text_test_range(0, 0)) is Ok(""))

  let inserted_at_start = match empty.replace(text_test_range(0, 0), "😀") {
    Ok(document) => document
    Err(_) => fail("insertion into an empty document should succeed")
  }
  assert_eq(inserted_at_start.text(), "😀")
  assert_eq(inserted_at_start.utf16_length(), 2)
  assert_true(inserted_at_start.selection() == text_test_selection(2, 2))
  assert_eq(empty.text(), "")
  assert_true(empty.selection() == text_test_selection(0, 0))

  let text = text_test_document("ab")
  let at_start = match text.replace(text_test_range(0, 0), "x") {
    Ok(document) => document
    Err(_) => fail("start insertion should succeed")
  }
  assert_eq(at_start.text(), "xab")
  assert_true(at_start.selection() == text_test_selection(1, 1))

  let in_middle = match text.replace(text_test_range(1, 1), "x") {
    Ok(document) => document
    Err(_) => fail("middle insertion should succeed")
  }
  assert_eq(in_middle.text(), "axb")
  assert_true(in_middle.text().has_prefix("a"))
  assert_true(in_middle.selection() == text_test_selection(2, 2))

  let at_end = match text.replace(text_test_range(2, 2), "!") {
    Ok(document) => document
    Err(_) => fail("end insertion should succeed")
  }
  assert_eq(at_end.text(), "ab!")
  assert_true(at_end.selection() == text_test_selection(3, 3))

  let whole = match text.replace(text_test_range(0, 2), "whole") {
    Ok(document) => document
    Err(_) => fail("whole-document replacement should succeed")
  }
  assert_eq(whole.text(), "whole")
  assert_true(whole.selection() == text_test_selection(5, 5))

  let deletion = match
    text_test_document("abcd").replace(text_test_range(1, 3), "") {
    Ok(document) => document
    Err(_) => fail("range deletion should succeed")
  }
  assert_eq(deletion.text(), "ad")
  assert_true(deletion.selection() == text_test_selection(1, 1))

  let same_text = text_test_document("same")
    .with_selection(text_test_selection(1, 3))
    .unwrap()
  let no_text_change = match same_text.replace(text_test_range(1, 3), "am") {
    Ok(document) => document
    Err(_) => fail("same-text replacement should succeed")
  }
  assert_eq(no_text_change.text(), "same")
  assert_true(no_text_change.selection() == text_test_selection(3, 3))
}

///|
test "selection preserves direction while operations use normalized ranges" {
  let document = text_test_document("a😀bc")
  let forward = match document.with_selection(text_test_selection(1, 3)) {
    Ok(value) => value
    Err(_) => fail("forward emoji selection should be valid")
  }
  assert_eq(forward.selection().anchor(), 1)
  assert_eq(forward.selection().head(), 3)
  assert_true(forward.selection().normalized_range() == text_test_range(1, 3))
  assert_false(forward.selection().is_collapsed())
  assert_eq(forward.selected_text(), "😀")

  let backward = match document.with_selection(text_test_selection(3, 1)) {
    Ok(value) => value
    Err(_) => fail("backward emoji selection should be valid")
  }
  assert_eq(backward.selection().anchor(), 3)
  assert_eq(backward.selection().head(), 1)
  assert_true(backward.selection().normalized_range() == text_test_range(1, 3))
  assert_eq(backward.selected_text(), "😀")

  let collapsed = match document.with_selection(text_test_selection(3, 3)) {
    Ok(value) => value
    Err(_) => fail("collapsed selection at a scalar boundary should be valid")
  }
  assert_true(collapsed.selection().is_collapsed())
  assert_eq(collapsed.selected_text(), "")

  let replaced_backward = match backward.replace_selection("x") {
    Ok(value) => value
    Err(_) => fail("replacing a backward selection should succeed")
  }
  assert_eq(replaced_backward.text(), "axbc")
  assert_true(replaced_backward.selection() == text_test_selection(2, 2))
  assert_eq(backward.text(), "a😀bc")
  assert_true(backward.selection() == text_test_selection(3, 1))
}

///|
test "slices preserve mixed Unicode scalar sequences and newline data" {
  let source = "ASCII日本語😀e\u0301👩‍💻\n\r\u0000z"
  let document = text_test_document(source)
  assert_eq(document.utf16_length(), 21)
  assert_true(document.slice(text_test_range(0, 5)) is Ok("ASCII"))
  assert_true(document.slice(text_test_range(5, 8)) is Ok("日本語"))
  assert_true(document.slice(text_test_range(8, 10)) is Ok("😀"))
  assert_true(document.slice(text_test_range(10, 12)) is Ok("e\u0301"))
  assert_true(document.slice(text_test_range(12, 17)) is Ok("👩‍💻"))
  assert_true(document.slice(text_test_range(17, 21)) is Ok("\n\r\u0000z"))
  assert_eq(document.text(), source)
}

///|
test "range and selection constructors report structural errors first" {
  let range = text_test_range(2, 5)
  assert_eq(range.start(), 2)
  assert_eq(range.end(), 5)
  assert_eq(range.length(), 3)

  assert_true(@text.TextRange::new(-1, -2) is Err(NegativeOffset))
  assert_true(@text.TextRange::new(-1, 2) is Err(NegativeOffset))
  assert_true(@text.TextRange::new(2, 1) is Err(ReversedRange))
  assert_true(@text.TextSelection::new(-1, 2) is Err(NegativeOffset))
  assert_true(@text.TextSelection::new(2, -1) is Err(NegativeOffset))

  let document = text_test_document("😀")
  assert_true(document.slice(text_test_range(1, 1)) is Err(SplitSurrogate))
  assert_true(document.slice(text_test_range(1, 3)) is Err(OutOfBounds))
  assert_true(document.slice(text_test_range(0, 3)) is Err(OutOfBounds))
  assert_true(
    document.with_selection(text_test_selection(1, 3)) is Err(OutOfBounds),
  )
  assert_true(
    document.with_selection(text_test_selection(1, 2)) is Err(SplitSurrogate),
  )
  assert_true(
    document.replace(text_test_range(1, 3), "replacement") is Err(OutOfBounds),
  )

  assert_eq(document.text(), "😀")
  assert_true(document.selection() == text_test_selection(0, 0))
}

///|
test "public constructors and replacements reject malformed UTF-16" {
  // These fixed in-bounds core slices create one half of the supplementary
  // scalar; production code never calls an unsafe String API.
  let high_surrogate = "😀".unsafe_substring(start=0, end=1)
  let low_surrogate = "😀".unsafe_substring(start=1, end=2)
  assert_true(@text.TextDocument::new(high_surrogate) is Err(MalformedUtf16))
  assert_true(@text.TextDocument::new(low_surrogate) is Err(MalformedUtf16))

  let document = text_test_document("😀")
  assert_true(
    document.replace(text_test_range(0, 0), low_surrogate)
    is Err(MalformedUtf16),
  )
  assert_true(
    document.replace(text_test_range(1, 2), high_surrogate)
    is Err(SplitSurrogate),
  )
  assert_true(
    document.replace(text_test_range(1, 3), high_surrogate) is Err(OutOfBounds),
  )
  assert_eq(document.text(), "😀")
  assert_true(document.selection() == text_test_selection(0, 0))
}

///|
test "failed edits do not mutate an existing document or selection" {
  let original = text_test_document("first😀last")
    .with_selection(text_test_selection(7, 5))
    .unwrap()
  assert_true(
    original.replace(text_test_range(8, 40), "broken") is Err(OutOfBounds),
  )
  assert_true(
    original.with_selection(text_test_selection(20, 0)) is Err(OutOfBounds),
  )
  assert_eq(original.text(), "first😀last")
  assert_true(original.selection() == text_test_selection(7, 5))
  assert_eq(original.selected_text(), "😀")
}
