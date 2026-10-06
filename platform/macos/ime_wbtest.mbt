///|
fn macos_session_payload_json(
  owner_revision : Int64,
  acknowledged_sequence : Int64?,
) -> Json {
  let document = @text.TextDocument::new("payload").unwrap()
  let caret = @primitives.Rect::new(12.0, 24.0, 1.0, 18.0).unwrap()
  let bytes = text_session_payload(
    document, caret, owner_revision, false, acknowledged_sequence, "test_payload",
  ).unwrap()
  let source = @utf8.decode(bytes) catch {
    _ => abort("session payload was not valid UTF-8")
  }
  @json.parse(source) catch {
    _ => abort("session payload was not valid JSON")
  }
}

///|
fn macos_session_payload_number(
  object : Map[String, Json],
  key : String,
) -> Double {
  match object.get(key) {
    Some(Number(value, ..)) => value
    _ => abort("session payload field was not a JSON number: " + key)
  }
}

///|
test "macOS text session serializes exact Int64 identity values as JSON numbers" {
  let max_exact = 9007199254740991L
  let parsed = macos_session_payload_json(max_exact, Some(max_exact))
  match parsed {
    Object(object) => {
      assert_eq(
        macos_session_payload_number(object, "owner_revision"),
        9007199254740991.0,
      )
      assert_eq(
        macos_session_payload_number(object, "acknowledged_sequence"),
        9007199254740991.0,
      )
    }
    _ => fail("session payload root was not a JSON object")
  }
}

///|
test "macOS text session rejects identities above the exact JSON integer bound" {
  let document = @text.TextDocument::new("payload").unwrap()
  let caret = @primitives.Rect::new(12.0, 24.0, 1.0, 18.0).unwrap()
  let max_exact = 9007199254740991L
  let above_exact = max_exact + 1L
  assert_true(
    text_session_payload(
      document,
      caret,
      above_exact,
      false,
      None,
      "test_payload",
    )
    is Err(_),
  )
  assert_true(
    text_session_payload(
      document,
      caret,
      max_exact,
      false,
      Some(above_exact),
      "test_payload",
    )
    is Err(_),
  )
}
