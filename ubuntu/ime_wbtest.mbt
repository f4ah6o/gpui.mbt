///|
fn ime_test_record(tag : Int, source : String) -> FixedArray[Double] {
  let data = FixedArray::make(EDITOR_EVENT_FIELDS, 0.0)
  data[0] = tag.to_double()
  data[1] = 7.0
  data[2] = 19.0
  data[3] = 2.0
  data[10] = 3.0
  data[11] = 4294967295.0
  data[12] = 2.0
  data[13] = if tag == 22 || tag == 23 { 0.0 } else { 29.0 }
  data[14] = @utf8.encode(source).length().to_double()
  data
}

///|
fn ime_test_decode(
  data : FixedArray[Double],
  bytes : Bytes,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  decode_editor_event(data, bytes, "ime_test")
}

///|
fn ime_test_commit(
  data : FixedArray[Double],
  bytes : Bytes,
) -> (TextSessionTarget, String, TextSessionDeletion?, TextSessionPosition?) raise {
  match ime_test_decode(data, bytes) {
    Ok(Some(TextSession(target, Commit(text~, deletion~, position~)))) =>
      (target, text, deletion, position)
    _ => fail("expected a typed atomic commit")
  }
}

///|
test "IME preedit converts exact UTF-8 boundaries to UTF-16" {
  let source = "A😀éあ"
  let fallback = "未確定"
  let payload = @utf8.encode(source + fallback)
  let data = ime_test_record(20, source)
  data[15] = @utf8.encode(fallback).length().to_double()
  data[16] = 1.0
  data[17] = 7.0
  data[24] = 2.0
  data[25] = 1.0
  data[26] = 4.0
  data[27] = 4.0
  data[28] = 5.0
  data[29] = 5.0
  data[30] = 7.0
  match ime_test_decode(data, payload) {
    Ok(
      Some(
        TextSession(
          target,
          Preedit(text~, fallback=actual_fallback, cursor_utf16~, styles~)
        )
      )
    ) => {
      assert_eq(target.window.value(), 7L)
      assert_eq(target.sequence, 19L)
      assert_eq(target.epoch, 3)
      assert_eq(target.seat, 4294967295L)
      assert_eq(target.proxy_generation, 2)
      assert_eq(target.serial, 29)
      assert_eq(text, source)
      assert_eq(actual_fallback, fallback)
      assert_eq(cursor_utf16, Some(4))
      assert_eq(styles.length(), 2)
      assert_eq(styles[0].range.start(), 1)
      assert_eq(styles[0].range.end(), 3)
      assert_eq(styles[0].style, 4)
      assert_eq(styles[1].range.start(), 3)
      assert_eq(styles[1].range.end(), 5)
      assert_eq(styles[1].style, 7)
    }
    _ => fail("valid multilingual preedit did not decode")
  }
}

///|
test "IME preedit hidden and absent cursor preserve fallback without committing" {
  for hidden in [-2147483648.0, -1.0] {
    let data = ime_test_record(20, "")
    data[15] = 1.0
    data[16] = 1.0
    data[17] = hidden
    match ime_test_decode(data, @utf8.encode("x")) {
      Ok(
        Some(TextSession(_, Preedit(text~, fallback~, cursor_utf16~, styles~)))
      ) => {
        assert_eq(text, "")
        assert_eq(fallback, "x")
        assert_eq(cursor_utf16, None)
        assert_eq(styles.length(), 0)
      }
      _ => fail("hidden cursor/fallback was not a preedit")
    }
  }
  match ime_test_decode(ime_test_record(20, ""), @utf8.encode("")) {
    Ok(Some(TextSession(_, Preedit(cursor_utf16~, ..)))) =>
      assert_eq(cursor_utf16, None)
    _ => fail("absent preedit cursor was rejected")
  }
}

///|
test "IME commit keeps signed surrounding and postinsert coordinates exact" {
  let data = ime_test_record(21, "😀")
  data[18] = 1.0
  data[19] = -2147483648.0
  data[20] = 4096.0
  data[21] = 1.0
  data[22] = -7.0
  data[23] = 2147483647.0
  let (_, text, deletion, position) = ime_test_commit(
    data,
    @utf8.encode("😀"),
  )
  assert_eq(text, "😀")
  match deletion {
    Some(value) => {
      assert_eq(value.index_bytes, -2147483648)
      assert_eq(value.length_bytes, 4096)
    }
    None => fail("deletion metadata disappeared")
  }
  match position {
    Some(value) => {
      assert_eq(value.cursor_index_bytes, -7)
      assert_eq(value.anchor_index_bytes, 2147483647)
    }
    None => fail("postinsert position metadata disappeared")
  }
}

///|
test "IME empty commit remains an event and repeated serials remain distinct" {
  let data = ime_test_record(21, "")
  for iteration = 0; iteration < 2; iteration = iteration + 1 {
    let (target, text, deletion, position) = ime_test_commit(
      data,
      @utf8.encode(""),
    )
    assert_eq(target.serial, 29)
    assert_eq(text, "")
    assert_true(deletion is None)
    assert_true(position is None)
  }
}

///|
test "IME exact copied payload ignores padding and cannot alias native scratch" {
  let data = ime_test_record(20, "x")
  data[15] = 1.0
  let scratch = FixedArray::from_array([b'x', b'y', b'\xFF'])
  let decoded = ime_test_decode(data, scratch.unsafe_reinterpret_as_bytes())
  scratch[0] = b'z'
  scratch[1] = b'z'
  data[10] = 99.0
  match decoded {
    Ok(Some(TextSession(target, Preedit(text~, fallback~, ..)))) => {
      assert_eq(target.epoch, 3)
      assert_eq(text, "x")
      assert_eq(fallback, "y")
    }
    _ => fail("exact UTF-8 copy was rejected or not a preedit")
  }
}

///|
test "IME decoder rejects malformed lengths and truncated records" {
  let bytes = @utf8.encode("x")
  assert_true(ime_test_decode(FixedArray::make(216, 0.0), bytes) is Err(_))
  for slot in [14, 15] {
    for value in [-1.0, 0.5, 4097.0, 2147483648.0, 0.0 / 0.0, 1.0 / 0.0] {
      let data = ime_test_record(20, "x")
      data[slot] = value
      assert_true(ime_test_decode(data, bytes) is Err(_))
    }
  }
  let data = ime_test_record(20, "x")
  data[15] = 1.0
  assert_true(ime_test_decode(data, bytes) is Err(_))
  let empty = @utf8.encode("")
  assert_true(ime_test_decode(ime_test_record(21, "x"), empty) is Err(_))
}

///|
test "IME malformed text and fallback fail strict UTF-8 decode" {
  for
    invalid in [
      Bytes::from_array([b'\xC3', b'(']),
      Bytes::from_array([b'\xC0', b'\xAF']),
      Bytes::from_array([b'\xED', b'\xA0', b'\x80']),
      Bytes::from_array([b'\xF4', b'\x90', b'\x80', b'\x80']),
    ] {
    let commit = ime_test_record(21, "")
    commit[14] = invalid.length().to_double()
    match ime_test_decode(commit, invalid) {
      Err(error) => assert_eq(error.code().label(), "conversion_failed")
      _ => fail("malformed commit UTF-8 was accepted")
    }
    let preedit = ime_test_record(20, "")
    preedit[15] = invalid.length().to_double()
    assert_true(ime_test_decode(preedit, invalid) is Err(_))
  }
}

///|
test "IME decoder rejects malformed tags and fenced identities" {
  let bytes = @utf8.encode("x")
  for tag in [0.0, 14.0, 19.0, 26.0, 20.5, 0.0 / 0.0, 1.0 / 0.0] {
    let data = ime_test_record(21, "x")
    data[0] = tag
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
  for slot in [1, 2, 10, 12, 13] {
    for value in [0.0, -1.0, 1.5, 2147483648.0, 0.0 / 0.0] {
      let data = ime_test_record(21, "x")
      data[slot] = value
      assert_true(ime_test_decode(data, bytes) is Err(_))
    }
  }
  for value in [0.0, -1.0, 1.5, 4294967296.0, 0.0 / 0.0] {
    let data = ime_test_record(21, "x")
    data[11] = value
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
  for scale in [0.0, -1.0, 0.0 / 0.0, 1.0 / 0.0] {
    let data = ime_test_record(21, "x")
    data[3] = scale
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
}

///|
test "IME decoder rejects invalid flags absent fields and cross-kind metadata" {
  let bytes = @utf8.encode("x")
  for slot in [16, 18, 21] {
    for value in [-1.0, 0.5, 2.0, 0.0 / 0.0] {
      let data = ime_test_record(21, "x")
      data[slot] = value
      assert_true(ime_test_decode(data, bytes) is Err(_))
    }
  }
  for slot in [4, 5, 6, 7, 8, 9, 17, 19, 20, 22, 23, 25, 216] {
    let data = ime_test_record(21, "x")
    data[slot] = 1.0
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
  for slot in [15, 16, 24] {
    let data = ime_test_record(21, "x")
    data[slot] = 1.0
    assert_true(ime_test_decode(data, @utf8.encode("xy")) is Err(_))
  }
  for slot in [18, 21] {
    let data = ime_test_record(20, "x")
    data[slot] = 1.0
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
  for value in [-1.0, 0.5, 4097.0] {
    let data = ime_test_record(21, "x")
    data[18] = 1.0
    data[20] = value
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
}

///|
test "IME preedit rejects cursor and style interiors of UTF-8 scalars" {
  let source = "a😀é"
  let bytes = @utf8.encode(source)
  for cursor in [2.0, 3.0, 4.0, 6.0, 8.0, 0.5] {
    let data = ime_test_record(20, source)
    data[16] = 1.0
    data[17] = cursor
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
  for
    fields in [
      (2.0, 0.0, 1.0),
      (1.0, 1.0, 1.0),
      (5.0, 1.0, 1.0),
      (-1.0, 1.0, 1.0),
      (0.5, 1.0, 1.0),
      (0.0, -1.0, 1.0),
      (0.0, 0.5, 1.0),
      (0.0, 8.0, 1.0),
      (0.0, 1.0, -1.0),
      (0.0, 1.0, 8.0),
      (0.0, 1.0, 0.5),
    ] {
    let data = ime_test_record(20, source)
    data[24] = 1.0
    let (index, length, style) = fields
    data[25] = index
    data[26] = length
    data[27] = style
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
}

///|
test "IME preedit style capacity and every protocol style are admitted exactly" {
  let bytes = @utf8.encode("x")
  let data = ime_test_record(20, "x")
  data[24] = 64.0
  for index = 0; index < 64; index = index + 1 {
    data[25 + index * 3] = 0.0
    data[26 + index * 3] = 1.0
    data[27 + index * 3] = (index % 8).to_double()
  }
  match ime_test_decode(data, bytes) {
    Ok(Some(TextSession(_, Preedit(styles~, ..)))) => {
      assert_eq(styles.length(), 64)
      assert_eq(styles[63].style, 7)
    }
    _ => fail("maximum valid style count was rejected")
  }
  for count in [-1.0, 0.5, 65.0, 0.0 / 0.0] {
    data[24] = count
    assert_true(ime_test_decode(data, bytes) is Err(_))
  }
}

///|
test "IME lifecycle carries a fenced target and zero serial only" {
  let empty = @utf8.encode("")
  for tag in [22, 23] {
    let data = ime_test_record(tag, "")
    match ime_test_decode(data, empty) {
      Ok(Some(TextSession(target, event))) => {
        assert_eq(target.serial, 0)
        assert_true(if tag == 22 { event is Entered } else { event is Left })
      }
      _ => fail("valid lifecycle event was rejected")
    }
    for slot in [6, 13, 14, 16, 18, 21, 24] {
      let invalid = ime_test_record(tag, "")
      invalid[slot] = 1.0
      assert_true(ime_test_decode(invalid, @utf8.encode("x")) is Err(_))
    }
  }
}

///|
test "IME forwarded keys preserve commands and unknown raw symbols without text" {
  let empty = @utf8.encode("")
  for tag in [24, 25] {
    let data = ime_test_record(tag, "")
    data[8] = 0xff51
    data[9] = 3.0
    match ime_test_decode(data, empty) {
      Ok(Some(TextSession(_, ForwardedPressed(keysym~, key~, modifiers~))))
      | Ok(Some(TextSession(_, ForwardedReleased(keysym~, key~, modifiers~)))) => {
        assert_eq(keysym, 0xff51)
        assert_true(key is Some(@primitives.ArrowLeft))
        assert_true(modifiers.shift())
        assert_true(modifiers.control())
      }
      _ => fail("forwarded arrow key was not typed")
    }
    data[8] = 0x61
    match ime_test_decode(data, empty) {
      Ok(Some(TextSession(_, ForwardedPressed(key~, ..))))
      | Ok(Some(TextSession(_, ForwardedReleased(key~, ..)))) =>
        assert_true(key is None)
      _ => fail("unknown forwarded symbol disappeared")
    }
    for
      fields in [
        (6, 97.0),
        (7, 1.0),
        (8, 0.5),
        (8, 536870912.0),
        (9, 16.0),
        (14, 1.0),
      ] {
      let (slot, value) = fields
      let invalid = ime_test_record(tag, "")
      invalid[slot] = value
      assert_true(ime_test_decode(invalid, @utf8.encode("x")) is Err(_))
    }
  }
}

///|
test "IME ingress retains ordinary event representation and rejects stale editor slots" {
  let data = FixedArray::make(EDITOR_EVENT_FIELDS, 0.0)
  data[0] = 11.0
  data[1] = 4.0
  data[2] = 9.0
  data[3] = 2.0
  data[8] = 0xff0d
  match ime_test_decode(data, @utf8.encode("")) {
    Ok(Some(Platform(event))) => {
      assert_eq(event.window().value(), 4L)
      assert_eq(event.sequence(), 9L)
      assert_eq(event.scale(), 2.0)
      assert_true(
        event.kind()
        is @platform.Input(@primitives.KeyPressed(key=@primitives.Enter, ..)),
      )
    }
    _ => fail("ordinary keyboard record did not remain portable")
  }
  data[10] = 1.0
  assert_true(ime_test_decode(data, @utf8.encode("")) is Err(_))
  data[10] = 0.0
  data[8] = 0xffe1
  assert_true(ime_test_decode(data, @utf8.encode("")) is Ok(None))
}

///|
test "IME surrounding uses committed directional UTF-8 offsets" {
  let document = @text.TextDocument::new("A😀éあ")
    .unwrap()
    .with_selection(@text.TextSelection::new(4, 1).unwrap())
    .unwrap()
  let (bytes, cursor, anchor) = text_session_surrounding(document, "ime_test").unwrap()
  assert_eq(bytes, @utf8.encode("A😀éあ"))
  assert_eq(cursor, 1)
  assert_eq(anchor, 7)
  let empty = @text.TextDocument::new("").unwrap()
  let (bytes, cursor, anchor) = text_session_surrounding(empty, "ime_test").unwrap()
  assert_eq(bytes.length(), 0)
  assert_eq(cursor, 0)
  assert_eq(anchor, 0)
  let nul = @text.TextDocument::new("a\u0000b").unwrap()
  assert_true(text_session_surrounding(nul, "ime_test") is Err(_))
  let bounded = @text.TextDocument::new(String::make(4096, 'a')).unwrap()
  assert_true(text_session_surrounding(bounded, "ime_test") is Ok(_))
  let oversized = @text.TextDocument::new(String::make(4097, 'a')).unwrap()
  match text_session_surrounding(oversized, "ime_test") {
    Err(error) => assert_eq(error.code().label(), "resource_exhausted")
    _ => fail("oversized surrounding document was accepted")
  }
}

///|
test "IME logical candidate rectangles keep signed coordinates without scaling" {
  let rect = @primitives.Rect::new(-8.0, 12.0, 3.0, 17.0).unwrap()
  assert_eq(text_session_rect(rect, "ime_test").unwrap(), (-8, 12, 3, 17))
  let limit = @primitives.Rect::new(-2147483648.0, 2147483647.0, 1.0, 1.0).unwrap()
  assert_true(text_session_rect(limit, "ime_test") is Ok(_))
  for
    fields in [
      (0.5, 0.0, 1.0, 1.0),
      (0.0, 0.5, 1.0, 1.0),
      (0.0, 0.0, 0.5, 1.0),
      (0.0, 0.0, 1.0, 0.5),
      (0.0, 0.0, 0.0, 1.0),
      (0.0, 0.0, 1.0, 0.0),
      (2147483648.0, 0.0, 1.0, 1.0),
      (-2147483649.0, 0.0, 1.0, 1.0),
      (0.0, 0.0, 2147483648.0, 1.0),
    ] {
    let (x, y, width, height) = fields
    let invalid = @primitives.Rect::new(x, y, width, height).unwrap()
    assert_true(text_session_rect(invalid, "ime_test") is Err(_))
  }
}

///|
test "IME session outcome rejects zero and preserves native failure codes" {
  assert_eq(text_session_epoch_outcome(2, "ime_test").unwrap(), 2)
  match text_session_epoch_outcome(0, "ime_test") {
    Err(error) => assert_eq(error.code().label(), "invalid_input")
    _ => fail("zero epoch was admitted")
  }
  match text_session_epoch_outcome(-4, "ime_test") {
    Err(error) => assert_eq(error.code().label(), "stale_handle")
    _ => fail("negative native status was admitted")
  }
}

///|
test "IME reader honors native status and one dispatch budget" {
  let mut reads = 0
  let mut dispatches = 0
  let mut observed_event_capacity = 0
  let mut observed_payload_capacity = 0
  let mut observed_timeout = 0
  let none = next_editor_event_from_native(
    (buffer, payload) => {
      observed_event_capacity = buffer.length()
      observed_payload_capacity = payload.length()
      reads += 1
      0
    },
    timeout => {
      observed_timeout = timeout
      dispatches += 1
      0
    },
    17,
  )
  assert_true(none is Ok(None))
  assert_eq(reads, 2)
  assert_eq(dispatches, 1)
  assert_eq(observed_event_capacity, 217)
  assert_eq(observed_payload_capacity, 8192)
  assert_eq(observed_timeout, 17)
  for status in [-4, 2] {
    assert_true(
      next_editor_event_from_native(
        (_, _) => status,
        _ => {
          dispatches += 1
          0
        },
        0,
      )
      is Err(_),
    )
  }
  assert_eq(dispatches, 1)
  assert_true(next_editor_event_from_native((_, _) => 0, _ => 3, 0) is Err(_))
}

///|
test "IME reader skips only valid unmapped ordinary keys then delivers empty commit" {
  let mut reads = 0
  let mut dispatches = 0
  let result = next_editor_event_from_native(
    (buffer, _) => {
      reads += 1
      let data = if reads == 1 {
        let key = FixedArray::make(EDITOR_EVENT_FIELDS, 0.0)
        key[0] = 11.0
        key[1] = 7.0
        key[2] = 18.0
        key[3] = 1.0
        key[8] = 0xffe1
        key
      } else {
        ime_test_record(21, "")
      }
      for index = 0; index < buffer.length(); index = index + 1 {
        buffer[index] = data[index]
      }
      1
    },
    _ => {
      dispatches += 1
      0
    },
    0,
  )
  assert_eq(reads, 2)
  assert_eq(dispatches, 0)
  assert_true(result is Ok(Some(TextSession(_, Commit(text="", ..)))))
}

///|
test "IME payload admits both maximum strings and rejects interior NUL" {
  let source = String::make(4096, 'x')
  let data = ime_test_record(20, source)
  data[15] = 4096.0
  match ime_test_decode(data, @utf8.encode(source + source)) {
    Ok(Some(TextSession(_, Preedit(text~, fallback~, ..)))) => {
      assert_eq(text.length(), 4096)
      assert_eq(fallback.length(), 4096)
    }
    _ => fail("maximum editor payload was rejected")
  }
  for tag in [20, 21] {
    assert_true(
      ime_test_decode(
        ime_test_record(tag, "a\u0000b"),
        @utf8.encode("a\u0000b"),
      )
      is Err(_),
    )
  }
  let preedit = ime_test_record(20, "x")
  preedit[15] = 1.0
  assert_true(ime_test_decode(preedit, @utf8.encode("x\u0000")) is Err(_))
}

///|
test "IME panel wrapper rejects invalid identities before native admission" {
  let host : Host = { token: -1, stopped: false, }
  for visible in [true, false] {
    for value in [-1L, 0L, 2147483648L, 4294967297L, 9223372036854775807L] {
      match
        host.set_text_session_panel(@platform.WindowId::new(value), 1, visible) {
        Err(error) => {
          assert_eq(error.code().label(), "invalid_input")
          assert_eq(error.operation(), "set_text_session_panel")
        }
        Ok(_) => fail("unrepresentable panel target reached native admission")
      }
    }
    for epoch in [-2147483648, -1, 0] {
      match
        host.set_text_session_panel(@platform.WindowId::new(1L), epoch, visible) {
        Err(error) => assert_eq(error.code().label(), "invalid_input")
        Ok(_) => fail("invalid panel epoch reached native admission")
      }
    }
  }
}
