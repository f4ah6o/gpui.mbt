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
