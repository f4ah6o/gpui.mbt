///|
fn text_offset_assert_tables(
  document : @text.TextDocument,
  utf16_boundaries : Array[Int],
  utf8_boundaries : Array[Int],
) -> Bool {
  if utf16_boundaries.length() != utf8_boundaries.length() {
    return false
  }
  for index in 0..<utf16_boundaries.length() {
    let observed_utf8 = match document.utf8_offset(utf16_boundaries[index]) {
      Err(_) => return false
      Ok(value) => value
    }
    let observed_utf16 = match document.utf16_offset(utf8_boundaries[index]) {
      Err(_) => return false
      Ok(value) => value
    }
    if observed_utf8 != utf8_boundaries[index] ||
      observed_utf16 != utf16_boundaries[index] {
      return false
    }
  }
  let segment_count = utf16_boundaries.length() - 1
  for index in 0..<segment_count {
    let utf16_start = utf16_boundaries[index]
    let utf16_width = utf16_boundaries[index + 1] - utf16_start
    for delta in 1..<utf16_width {
      if !(document.utf8_offset(utf16_start + delta) is Err(SplitSurrogate)) {
        return false
      }
    }
    let utf8_start = utf8_boundaries[index]
    let utf8_width = utf8_boundaries[index + 1] - utf8_start
    for delta in 1..<utf8_width {
      if !(document.utf16_offset(utf8_start + delta) is Err(SplitUtf8)) {
        return false
      }
    }
  }
  true
}

///|
test "UTF-16 and UTF-8 offset bridge preserves exact scalar boundaries" {
  let empty = text_test_document("")
  assert_true(empty.utf8_length() is Ok(0))
  assert_true(text_offset_assert_tables(empty, [0], [0]))

  let ascii_controls = text_test_document("A\n\u0000Z")
  assert_true(ascii_controls.utf8_length() is Ok(4))
  assert_true(
    text_offset_assert_tables(ascii_controls, [0, 1, 2, 3, 4], [0, 1, 2, 3, 4]),
  )

  let example = text_test_document("a😀日")
  assert_true(example.utf8_length() is Ok(8))
  assert_true(text_offset_assert_tables(example, [0, 1, 3, 4], [0, 1, 5, 8]))

  let widths = text_test_document(
    "\u{7F}\u{80}\u{7FF}\u{800}\u{D7FF}\u{E000}\u{FFFF}\u{10000}\u{10FFFF}",
  )
  assert_true(widths.utf8_length() is Ok(25))
  assert_true(
    text_offset_assert_tables(widths, [0, 1, 2, 3, 4, 5, 6, 7, 9, 11], [
      0, 1, 3, 5, 8, 11, 14, 17, 21, 25,
    ]),
  )

  let combining_and_zwj = text_test_document("e\u{0301}👩‍💻")
  assert_true(combining_and_zwj.utf8_length() is Ok(14))
  assert_true(
    text_offset_assert_tables(combining_and_zwj, [0, 1, 2, 4, 5, 7], [
      0, 1, 3, 7, 10, 14,
    ]),
  )
}

///|
test "offset bridge rejects negative and out-of-bounds offsets without mutation" {
  let selection = text_test_selection(4, 1)
  let document = text_test_document("a😀日")
    .with_selection(selection)
    .unwrap()
  let original_text = document.text()

  assert_true(document.utf8_offset(-1) is Err(NegativeOffset))
  assert_true(document.utf8_offset(5) is Err(OutOfBounds))
  assert_true(document.utf16_offset(-1) is Err(NegativeOffset))
  assert_true(document.utf16_offset(9) is Err(OutOfBounds))
  assert_true(document.utf8_offset(0) is Ok(0))
  assert_true(document.utf8_offset(4) is Ok(8))
  assert_true(document.utf16_offset(0) is Ok(0))
  assert_true(document.utf16_offset(8) is Ok(4))

  assert_eq(document.text(), original_text)
  assert_true(document.selection() == selection)
}
