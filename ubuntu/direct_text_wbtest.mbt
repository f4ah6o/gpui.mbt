///|
fn direct_text_record(length : Double) -> FixedArray[Double] {
  let data = FixedArray::make(10, 0.0)
  data[0] = 13.0
  data[1] = 7.0
  data[2] = 19.0
  data[3] = 1.0
  data[8] = length
  data[9] = 1.0
  data
}

///|
fn direct_text_decode_error(
  data : FixedArray[Double],
  bytes : Bytes,
) -> @diagnostics.FrameworkError? {
  match decode_direct_text_event(data, bytes, "direct_text_test") {
    Ok(_) => None
    Err(error) => Some(error)
  }
}

///|
test "direct text decoder preserves exact UTF-8 bytes" {
  for source in ["A", "こんにちは", "naïve", "👋🏽"] {
    let bytes = @utf8.encode(source)
    let data = direct_text_record(bytes.length().to_double())
    match decode_v2_event(data, bytes, "direct_text_test") {
      Ok(Some(@platform.Input(@primitives.TextInput(text~)))) =>
        assert_eq(text, source)
      _ => fail("valid direct text was not decoded exactly")
    }
  }
  let padded = Bytes::from_array([b'x', b'\xFF'])
  match decode_v2_event(direct_text_record(1.0), padded, "direct_text_test") {
    Ok(Some(@platform.Input(@primitives.TextInput(text~)))) =>
      assert_eq(text, "x")
    _ => fail("bytes past the native reported length were decoded")
  }
}

///|
test "direct text decoder rejects malformed lengths and UTF-8" {
  let bytes = @utf8.encode("x")
  for length in [0.0, -1.0, 1.5, 129.0, 2147483648.0] {
    let error = match
      direct_text_decode_error(direct_text_record(length), bytes) {
      Some(value) => value
      None => fail("invalid direct text length was accepted")
    }
    assert_eq(error.code().label(), "invalid_input")
  }
  let nan_data = direct_text_record(0.0 / 0.0)
  assert_true(direct_text_decode_error(nan_data, bytes) is Some(_))

  let invalid_utf8 = Bytes::from_array([b'\xC3', b'('])
  let invalid_data = direct_text_record(2.0)
  let conversion_error = match
    direct_text_decode_error(invalid_data, invalid_utf8) {
    Some(value) => value
    None => fail("malformed UTF-8 was accepted")
  }
  assert_eq(conversion_error.code().label(), "conversion_failed")
}

///|
test "direct text decoder rejects malformed integer event fields" {
  let bytes = @utf8.encode("text")
  let invalid_window = direct_text_record(4.0)
  invalid_window[1] = 7.25
  assert_true(direct_text_decode_error(invalid_window, bytes) is Some(_))

  let invalid_sequence = direct_text_record(4.0)
  invalid_sequence[2] = 0.0 / 0.0
  assert_true(direct_text_decode_error(invalid_sequence, bytes) is Some(_))

  let invalid_modifiers = direct_text_record(4.0)
  invalid_modifiers[9] = 1.5
  assert_true(direct_text_decode_error(invalid_modifiers, bytes) is Some(_))

  let fractional_tag = direct_text_record(4.0)
  fractional_tag[0] = 13.5
  assert_true(
    decode_v2_event(fractional_tag, bytes, "direct_text_test") is Err(_),
  )

  let nan_tag = direct_text_record(4.0)
  nan_tag[0] = 0.0 / 0.0
  assert_true(decode_v2_event(nan_tag, bytes, "direct_text_test") is Err(_))
}

///|
test "v2 keeps the existing non-text decoder behavior" {
  let data = FixedArray::make(10, 0.0)
  data[0] = 8.0
  data[1] = 2.0
  data[2] = 3.0
  data[3] = 1.0
  data[6] = 12.5
  data[7] = 8.25
  data[8] = 0.0
  data[9] = 3.0
  let expected = decode_event(data)
  match
    decode_v2_event(data, Bytes::make(0, (0).to_byte()), "direct_text_test") {
    Err(_) => fail("non-text record gained a v2 decode error")
    Ok(actual) =>
      match (expected, actual) {
        (
          Some(
            @platform.Input(
              @primitives.PointerButtonPressed(position~, button~, modifiers~)
            )
          ),
          Some(
            @platform.Input(
              @primitives.PointerButtonPressed(
                position=actual_position,
                button=actual_button,
                modifiers=actual_modifiers
              )
            )
          ),
        ) => {
          assert_eq(actual_position.x(), position.x())
          assert_eq(actual_position.y(), position.y())
          assert_true(actual_button == button)
          assert_eq(actual_modifiers.shift(), modifiers.shift())
          assert_eq(actual_modifiers.control(), modifiers.control())
          assert_eq(actual_modifiers.alt(), modifiers.alt())
        }
        _ => fail("non-text v2 decoding diverged from the legacy helper")
      }
  }
}

///|
fn native_key_record(
  tag : Double,
  symbol : Double,
  scalar : Double,
  modifier_bits : Double,
) -> FixedArray[Double] {
  let data = FixedArray::make(10, 0.0)
  data[0] = tag
  data[1] = 7.0
  data[2] = 19.0
  data[3] = 1.0
  data[4] = 640.0
  data[5] = 480.0
  data[6] = scalar
  data[8] = symbol
  data[9] = modifier_bits
  data
}

///|
test "valid unmapped native key records are intentional skips" {
  let empty = Bytes::make(0, (0).to_byte())
  // Shift, Control, Alt, Super, Caps Lock, ISO Level3 Shift, F1 and NoSymbol.
  for
    symbol in [
      0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe9, 0xffeb, 0xffe5, 0xfe03, 0xffbe, 0,
    ] {
    for tag in [11.0, 12.0] {
      match
        decode_v2_event(
          native_key_record(tag, symbol.to_double(), 0.0, 0.0),
          empty,
          "native_key_test",
        ) {
        Ok(None) => ()
        _ => fail("valid unmapped native key became an error or portable key")
      }
    }
  }
}

///|
test "native keys retain shifted characters and shortcut modifiers" {
  let empty = Bytes::make(0, (0).to_byte())
  match
    decode_v2_event(
      native_key_record(11.0, 65.0, 65.0, 1.0),
      empty,
      "native_key_test",
    ) {
    Ok(
      Some(
        @platform.Input(
          @primitives.KeyPressed(
            key=@primitives.Character("A"),
            modifiers~,
            repeat=false
          )
        )
      )
    ) => assert_true(modifiers.shift() && !modifiers.control())
    _ => fail("shifted character was not preserved")
  }
  match
    decode_v2_event(
      native_key_record(11.0, 122.0, 122.0, 3.0),
      empty,
      "native_key_test",
    ) {
    Ok(
      Some(
        @platform.Input(
          @primitives.KeyPressed(
            key=@primitives.Character("z"),
            modifiers~,
            repeat=false
          )
        )
      )
    ) => assert_true(modifiers.shift() && modifiers.control())
    _ => fail("shortcut character and modifiers were not preserved")
  }
}

///|
test "unmapped key skipping rejects malformed native records" {
  let empty = Bytes::make(0, (0).to_byte())
  for
    (index, invalid) in [
      (0, 11.5),
      (0, 0.0 / 0.0),
      (1, 0.0),
      (1, 7.25),
      (2, 0.0),
      (2, 19.5),
      (3, 0.0),
      (3, 0.0 / 0.0),
      (6, -1.0),
      (6, (0xd800).to_double()),
      (6, (0x110000).to_double()),
      (6, 1.25),
      (7, 2.0),
      (8, -1.0),
      (8, (0x20000000).to_double()),
      (8, 65505.25),
      (9, -1.0),
      (9, 16.0),
      (9, 1.5),
    ] {
    let data = native_key_record(11.0, (0xffe1).to_double(), 0.0, 0.0)
    data[index] = invalid
    match decode_v2_event(data, empty, "native_key_test") {
      Err(error) => assert_eq(error.code().label(), "invalid_input")
      _ => fail("malformed unmapped key was silently skipped")
    }
  }
  for tag in [0.0, -1.0, 14.0, 999.0] {
    let data = native_key_record(tag, (0xffe1).to_double(), 0.0, 0.0)
    assert_true(decode_v2_event(data, empty, "native_key_test") is Err(_))
  }
  let invalid_pointer = native_key_record(7.0, 0.0, 0.0 / 0.0, 0.0)
  assert_true(
    decode_v2_event(invalid_pointer, empty, "native_key_test") is Err(_),
  )
}

///|
fn native_record_reader(
  records : Array[(FixedArray[Double], Bytes)],
  counts : FixedArray[Int],
) -> (FixedArray[Double], FixedArray[Byte]) -> Int {
  (out, text) => {
    counts[1] = counts[1] + 1
    if counts[0] >= records.length() {
      0
    } else {
      let (record, bytes) = records[counts[0]]
      counts[0] = counts[0] + 1
      for index = 0; index < 10; index = index + 1 {
        out[index] = record[index]
      }
      for index = 0; index < bytes.length(); index = index + 1 {
        text[index] = bytes[index]
      }
      1
    }
  }
}

///|
test "incremental ingress drains modifiers and preserves key text order" {
  let empty = Bytes::make(0, (0).to_byte())
  let committed = direct_text_record(1.0)
  let records = [
    (native_key_record(11.0, 65505.0, 0.0, 0.0), empty),
    (native_key_record(11.0, 65.0, 65.0, 1.0), empty),
    (committed, @utf8.encode("A")),
    (native_key_record(12.0, 65.0, 65.0, 1.0), empty),
    (native_key_record(12.0, 65505.0, 0.0, 1.0), empty),
    (native_key_record(11.0, 65507.0, 0.0, 0.0), empty),
    (native_key_record(11.0, 122.0, 122.0, 2.0), empty),
    (native_key_record(12.0, 65507.0, 0.0, 2.0), empty),
    (native_key_record(11.0, 65361.0, 0.0, 0.0), empty),
  ]
  for index = 0; index < records.length(); index = index + 1 {
    records[index].0[2] = (index + 1).to_double()
  }
  let counts = FixedArray::make(4, 0)
  let read = native_record_reader(records, counts)
  let dispatch = timeout => {
    counts[2] = counts[2] + 1
    counts[3] = counts[3] + timeout
    0
  }
  for sequence in [2L, 3L, 4L, 7L, 9L] {
    let event = match next_event_from_native(read, dispatch, 37) {
      Ok(Some(event)) => event
      _ => fail("modifier interrupted following representable input")
    }
    assert_eq(event.sequence(), sequence)
    match (sequence, event.kind()) {
      (
        2L,
        @platform.Input(
          @primitives.KeyPressed(key=@primitives.Character("A"), modifiers~, ..)
        ),
      ) => assert_true(modifiers.shift())
      (3L, @platform.Input(@primitives.TextInput(text="A"))) => ()
      (
        4L,
        @platform.Input(
          @primitives.KeyReleased(key=@primitives.Character("A"), ..)
        ),
      ) => ()
      (
        7L,
        @platform.Input(
          @primitives.KeyPressed(key=@primitives.Character("z"), modifiers~, ..)
        ),
      ) => assert_true(modifiers.control())
      (
        9L,
        @platform.Input(@primitives.KeyPressed(key=@primitives.ArrowLeft, ..)),
      ) => ()
      _ => fail("representable input order or modifiers changed")
    }
    assert_eq(counts[2], 0)
  }
  assert_true(next_event_from_native(read, dispatch, 37) is Ok(None))
  assert_eq(counts[0], 9)
  assert_eq(counts[2], 1)
  assert_eq(counts[3], 37)
}

///|
test "only unmapped keys consume one incremental dispatch budget" {
  let empty = Bytes::make(0, (0).to_byte())
  let records = [
    (native_key_record(11.0, 65505.0, 0.0, 0.0), empty),
    (native_key_record(12.0, 65505.0, 0.0, 1.0), empty),
  ]
  let counts = FixedArray::make(4, 0)
  let read = native_record_reader(records, counts)
  let dispatch = timeout => {
    counts[2] = counts[2] + 1
    counts[3] = counts[3] + timeout
    records.push((native_key_record(11.0, 65507.0, 0.0, 0.0), empty))
    records.push((native_key_record(12.0, 65507.0, 0.0, 2.0), empty))
    0
  }
  assert_true(next_event_from_native(read, dispatch, 37) is Ok(None))
  assert_eq(counts[0], 4)
  assert_eq(counts[1], 6)
  assert_eq(counts[2], 1)
  assert_eq(counts[3], 37)
}

///|
test "incremental ingress preserves malformed and negative status errors" {
  let empty = Bytes::make(0, (0).to_byte())
  let malformed = native_key_record(11.0, 65505.5, 0.0, 0.0)
  let unknown = native_key_record(999.0, 0.0, 0.0, 0.0)
  let invalid_text = direct_text_record(2.0)
  for
    (data, bytes, expected) in [
      (malformed, empty, "invalid_input"),
      (unknown, empty, "invalid_input"),
      (invalid_text, Bytes::from_array([b'\xC3', b'(']), "conversion_failed"),
    ] {
    let counts = FixedArray::make(4, 0)
    let read = native_record_reader([(data, bytes)], counts)
    let dispatch = _ => {
      counts[2] = counts[2] + 1
      0
    }
    match next_event_from_native(read, dispatch, 37) {
      Err(error) => assert_eq(error.code().label(), expected)
      _ => fail("malformed incremental record was ignored")
    }
    assert_eq(counts[1], 1)
    assert_eq(counts[2], 0)
  }
  for
    (status, expected) in [
      (-2, "native_failure"),
      (-5, "busy"),
      (-4, "stale_handle"),
      (2, "invalid_input"),
    ] {
    let counts = FixedArray::make(1, 0)
    let read = (_, _) => status
    let dispatch = _ => {
      counts[0] = counts[0] + 1
      0
    }
    match next_event_from_native(read, dispatch, 37) {
      Err(error) => assert_eq(error.code().label(), expected)
      _ => fail("native read error became an empty incremental result")
    }
    assert_eq(counts[0], 0)
  }
  let read = (_, _) => 0
  match next_event_from_native(read, _ => 2, 37) {
    Err(error) => assert_eq(error.code().label(), "native_failure")
    _ => fail("native dispatch error was ignored")
  }
}

///|
fn direct_repeat_key_record(tag : Double, flag : Double) -> FixedArray[Double] {
  let data = FixedArray::make(10, 0.0)
  data[0] = tag
  data[1] = 7.0
  data[2] = 19.0
  data[3] = 1.0
  data[6] = 97.0
  data[7] = flag
  data[8] = 97.0
  data
}

///|
test "v2 key repeat flags preserve physical and synthetic press identity" {
  let no_text = Bytes::make(0, (0).to_byte())
  for flag in [0.0, 1.0] {
    match
      decode_v2_event(
        direct_repeat_key_record(11.0, flag),
        no_text,
        "repeat_test",
      ) {
      Ok(
        Some(
          @platform.Input(
            @primitives.KeyPressed(key=@primitives.Character("a"), repeat~, ..)
          )
        )
      ) => assert_eq(repeat, flag == 1.0)
      _ => fail("exact key repeat flag was not preserved")
    }
  }
  assert_true(
    decode_v2_event(direct_repeat_key_record(12.0, 0.0), no_text, "repeat_test")
    is Ok(Some(@platform.Input(@primitives.KeyReleased(..)))),
  )
}

///|
test "v2 rejects malformed repeat flags with typed invalid input" {
  let no_text = Bytes::make(0, (0).to_byte())
  for flag in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0, 0.5, -1.0, 2.0] {
    for tag in [11.0, 12.0] {
      match
        decode_v2_event(
          direct_repeat_key_record(tag, flag),
          no_text,
          "repeat_flag_test",
        ) {
        Err(error) => {
          assert_eq(error.code().label(), "invalid_input")
          assert_eq(error.operation(), "repeat_flag_test")
        }
        Ok(_) => fail("malformed key repeat flag was accepted")
      }
    }
    let text = direct_text_record(1.0)
    text[7] = flag
    match decode_v2_event(text, @utf8.encode("a"), "repeat_flag_test") {
      Err(error) => assert_eq(error.code().label(), "invalid_input")
      Ok(_) => fail("malformed text repeat flag was accepted")
    }
  }
  match
    decode_v2_event(
      direct_repeat_key_record(12.0, 1.0),
      no_text,
      "repeat_flag_test",
    ) {
    Err(error) => assert_eq(error.code().label(), "invalid_input")
    Ok(_) => fail("synthetic repeat release was accepted")
  }
  let text = direct_text_record(1.0)
  text[7] = 1.0
  match decode_v2_event(text, @utf8.encode("a"), "repeat_flag_test") {
    Err(error) => assert_eq(error.code().label(), "invalid_input")
    Ok(_) => fail("text record gained a key repeat flag")
  }
}

///|
test "direct mode blocks batch dispatch and capability admission is typed" {
  match active_direct_text_dispatch_gate(0) {
    Ok(_) => ()
    Err(_) => fail("inactive direct mode blocked legacy batch dispatch")
  }
  match active_direct_text_dispatch_gate(1) {
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) => fail("active direct mode allowed batch dispatch")
  }
  match active_direct_text_dispatch_gate(-5) {
    Err(error) => assert_eq(error.code().label(), "busy")
    Ok(_) => fail("active-query status was ignored")
  }
  match direct_text_capability_outcome(0) {
    Ok(_) => ()
    Err(_) => fail("native admission success was not accepted")
  }
  match direct_text_capability_outcome(1) {
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) => fail("native capability rejection was not typed")
  }
}

///|
test "direct target IDs cannot wrap from portable Int64 to native Int" {
  assert_eq(direct_window_token(@platform.WindowId::new(1L), "id").unwrap(), 1)
  assert_eq(
    direct_window_token(@platform.WindowId::new(2147483647L), "id").unwrap(),
    2147483647,
  )
  let host : Host = { token: -1, stopped: false, }
  for value in [-1L, 0L, 2147483648L, 4294967297L, 9223372036854775807L] {
    let window = @platform.WindowId::new(value)
    match host.set_direct_keyboard_text(window, true) {
      Err(error) => {
        assert_eq(error.code().label(), "invalid_input")
        assert_eq(error.operation(), "set_direct_keyboard_text")
      }
      Ok(_) => fail("unrepresentable direct target reached native admission")
    }
    match host.direct_keyboard_text_epoch(window) {
      Err(error) => {
        assert_eq(error.code().label(), "invalid_input")
        assert_eq(error.operation(), "direct_keyboard_text_epoch")
      }
      Ok(_) => fail("unrepresentable direct target reached native epoch query")
    }
  }
}
