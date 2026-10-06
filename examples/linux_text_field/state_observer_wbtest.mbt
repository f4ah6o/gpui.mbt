///|
test "state observer is enabled only by the exact opt-in value" {
  assert_true(field_state_enabled(Some("1")))
  for value in [None, Some(""), Some("0"), Some("true"), Some(" 1"), Some("1 ")] {
    assert_false(field_state_enabled(value))
  }
}

///|
test "state observer v1 schema uses integers boolean and directional selection" {
  let value = field_state_json(17, "a😀日本", 5, 1, true, 23)
  assert_eq(
    value, "{\"version\":1,\"presentation\":17,\"text\":\"a😀日本\",\"selection\":{\"anchor\":5,\"head\":1},\"focused\":true,\"revision\":23}",
  )
  let parsed = @json.parse(value)
  let expected : Json = {
    "version": 1,
    "presentation": 17,
    "text": "a😀日本",
    "selection": { "anchor": 5, "head": 1 },
    "focused": true,
    "revision": 23,
  }
  assert_true(parsed == expected)
}

///|
test "state observer escapes JSON punctuation controls and preserves Unicode" {
  let text = "\"\\\n\r\t\u{0}\u{8}\u{c}\u{1f}日本😀e\u{301}\u{2028}\u{2029}"
  let value = field_state_json(1, text, 0, text.length(), false, 0)
  assert_false(value.contains("\n"))
  assert_false(value.contains("\r"))
  let parsed = @json.parse(value)
  match parsed {
    Object(object) => {
      assert_eq(object.length(), 6)
      assert_true(object.get("text") == Some(text.to_json()))
      assert_true(object.get("focused") == Some(false.to_json()))
      let selection : Json = { "anchor": 0, "head": text.length().to_json() }
      assert_true(object.get("selection") == Some(selection))
    }
    _ => fail("observer emitted a non-object JSON record")
  }
}

///|
test "state observer reads the field without changing document or revision" {
  let field = controller_field()
  let end = change(field, key_event(@primitives.End)).unwrap()
  let selected = change(end, key_event(@primitives.Home, shift=true)).unwrap()
  let revision = selected.revision()
  let document = selected.document()
  let line = field_state_line(3, selected)
  assert_eq(
    line,
    "GPUI_FIELD_STATE {\"version\":1,\"presentation\":3,\"text\":\"Hi 日本\",\"selection\":{\"anchor\":5,\"head\":0},\"focused\":true,\"revision\":\{revision}}",
  )
  assert_true(selected.document() == document)
  assert_eq(selected.revision(), revision)
  assert_true(selected.is_focused())
  let blurred = selected.with_focus(false).unwrap()
  assert_true(field_state_line(4, blurred).contains("\"focused\":false"))
}
