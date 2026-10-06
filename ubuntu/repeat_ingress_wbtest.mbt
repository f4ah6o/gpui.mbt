///|
fn repeat_ingress_key_record(
  tag : Double,
  symbol : Double,
  scalar : Double,
  modifier_bits : Double,
  repeat_flag : Double,
) -> FixedArray[Double] {
  let data = native_key_record(tag, symbol, scalar, modifier_bits)
  data[7] = repeat_flag
  data
}

///|
fn repeat_ingress_error_before_text(
  malformed : FixedArray[Double],
  bytes : Bytes,
) -> Unit raise {
  let empty = Bytes::make(0, (0).to_byte())
  let committed = direct_text_record(1.0)
  let records = [
    (native_key_record(11.0, 65505.0, 0.0, 0.0), empty),
    (malformed, bytes),
    (committed, @utf8.encode("a")),
  ]
  records[0].0[2] = 1.0
  committed[2] = 3.0
  let counts = FixedArray::make(4, 0)
  let read = native_record_reader(records, counts)
  let dispatch = timeout => {
    counts[2] = counts[2] + 1
    counts[3] = counts[3] + timeout
    0
  }
  match next_event_from_native(read, dispatch, 37) {
    Err(error) => {
      assert_eq(error.code().label(), "invalid_input")
      assert_eq(error.operation(), "next_event")
    }
    _ => fail("malformed repeat ingress was skipped before following text")
  }
  assert_eq(counts[0], 2)
  assert_eq(counts[1], 2)
  assert_eq(counts[2], 0)
  match next_event_from_native(read, dispatch, 37) {
    Ok(Some(event)) => {
      assert_eq(event.sequence(), 3L)
      assert_true(
        event.kind() is @platform.Input(@primitives.TextInput(text="a")),
      )
    }
    _ => fail("following valid text was consumed with malformed ingress")
  }
  assert_eq(counts[2], 0)
  assert_true(next_event_from_native(read, dispatch, 37) is Ok(None))
  assert_eq(counts[0], 3)
  assert_eq(counts[2], 1)
  assert_eq(counts[3], 37)
}

///|
test "repeat ingress preserves one synthetic key and exact commit through modifiers" {
  let empty = Bytes::make(0, (0).to_byte())
  let records = [
    (native_key_record(11.0, 65505.0, 0.0, 0.0), empty),
    (repeat_ingress_key_record(11.0, 65.0, 65.0, 1.0, 1.0), empty),
    (native_key_record(12.0, 65505.0, 0.0, 1.0), empty),
    (native_key_record(11.0, 65507.0, 0.0, 0.0), empty),
    (direct_text_record(1.0), @utf8.encode("A")),
    (native_key_record(12.0, 65507.0, 0.0, 2.0), empty),
  ]
  for index in 0..<records.length() {
    records[index].0[2] = (index + 1).to_double()
  }
  let counts = FixedArray::make(4, 0)
  let read = native_record_reader(records, counts)
  let dispatch = timeout => {
    counts[2] = counts[2] + 1
    counts[3] = counts[3] + timeout
    0
  }
  match next_event_from_native(read, dispatch, 37) {
    Ok(Some(event)) => {
      assert_eq(event.sequence(), 2L)
      match event.kind() {
        @platform.Input(
          @primitives.KeyPressed(
            key=@primitives.Character("A"),
            modifiers~,
            repeat=true
          )
        ) => assert_true(modifiers.shift() && !modifiers.control())
        _ => fail("synthetic press identity was lost through modifier ingress")
      }
    }
    _ => fail("physical modifier swallowed the following synthetic press")
  }
  assert_eq(counts[0], 2)
  assert_eq(counts[2], 0)
  match next_event_from_native(read, dispatch, 37) {
    Ok(Some(event)) => {
      assert_eq(event.sequence(), 5L)
      assert_true(
        event.kind() is @platform.Input(@primitives.TextInput(text="A")),
      )
    }
    _ => fail("intervening modifiers swallowed the exact synthetic commit")
  }
  assert_eq(counts[0], 5)
  assert_eq(counts[2], 0)
  assert_true(next_event_from_native(read, dispatch, 37) is Ok(None))
  assert_eq(counts[0], 6)
  assert_eq(counts[2], 1)
  assert_eq(counts[3], 37)
}

///|
test "repeat ingress uses one dispatch budget for appended key text and modifiers" {
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
    if counts[2] == 1 {
      records.push((native_key_record(11.0, 65507.0, 0.0, 0.0), empty))
      records.push(
        (repeat_ingress_key_record(11.0, 97.0, 97.0, 0.0, 1.0), empty),
      )
      records.push((native_key_record(12.0, 65507.0, 0.0, 2.0), empty))
      records.push((direct_text_record(1.0), @utf8.encode("a")))
      records.push((native_key_record(11.0, 65513.0, 0.0, 0.0), empty))
      for index in 0..<records.length() {
        records[index].0[2] = (index + 1).to_double()
      }
    }
    0
  }
  match next_event_from_native(read, dispatch, 37) {
    Ok(Some(event)) => {
      assert_eq(event.sequence(), 4L)
      assert_true(
        event.kind()
        is @platform.Input(
          @primitives.KeyPressed(
            key=@primitives.Character("a"),
            repeat=true,
            ..
          )
        ),
      )
    }
    _ => fail("dispatch-appended synthetic key was not drained")
  }
  assert_eq(counts[0], 4)
  assert_eq(counts[1], 5)
  assert_eq(counts[2], 1)
  assert_eq(counts[3], 37)
  match next_event_from_native(read, dispatch, 37) {
    Ok(Some(event)) => {
      assert_eq(event.sequence(), 6L)
      assert_true(
        event.kind() is @platform.Input(@primitives.TextInput(text="a")),
      )
    }
    _ => fail("dispatch-appended exact text was not retained for the next call")
  }
  assert_eq(counts[0], 6)
  assert_eq(counts[1], 7)
  assert_eq(counts[2], 1)
  assert_true(next_event_from_native(read, dispatch, 37) is Ok(None))
  assert_eq(counts[0], 7)
  assert_eq(counts[1], 10)
  assert_eq(counts[2], 2)
  assert_eq(counts[3], 74)
}

///|
test "repeat ingress rejects malformed flags before following valid text" {
  let empty = Bytes::make(0, (0).to_byte())
  for flag in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0, 0.5, -1.0, 2.0] {
    for (symbol, scalar) in [(97.0, 97.0), (65505.0, 0.0)] {
      for tag in [11.0, 12.0] {
        repeat_ingress_error_before_text(
          repeat_ingress_key_record(tag, symbol, scalar, 0.0, flag),
          empty,
        )
      }
    }
    let text = direct_text_record(1.0)
    text[7] = flag
    repeat_ingress_error_before_text(text, @utf8.encode("a"))
  }
  for (symbol, scalar) in [(97.0, 97.0), (65505.0, 0.0)] {
    repeat_ingress_error_before_text(
      repeat_ingress_key_record(12.0, symbol, scalar, 0.0, 1.0),
      empty,
    )
  }
  let text = direct_text_record(1.0)
  text[7] = 1.0
  repeat_ingress_error_before_text(text, @utf8.encode("a"))
}

///|
test "repeat ingress never treats unknown tags or malformed keys as modifier skips" {
  let empty = Bytes::make(0, (0).to_byte())
  for tag in [0.0, -1.0, 14.0, 999.0, 11.5, 0.0 / 0.0, 1.0 / 0.0] {
    repeat_ingress_error_before_text(
      repeat_ingress_key_record(tag, 65505.0, 0.0, 0.0, 1.0),
      empty,
    )
  }
  for
    (index, invalid) in [
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
      (8, -1.0),
      (8, (0x20000000).to_double()),
      (8, 65505.25),
      (9, -1.0),
      (9, 16.0),
      (9, 1.5),
    ] {
    let malformed = repeat_ingress_key_record(11.0, 65505.0, 0.0, 0.0, 1.0)
    malformed[index] = invalid
    repeat_ingress_error_before_text(malformed, empty)
  }
}

///|
test "repeat flagged unmapped modifiers remain intentional bounded ingress skips" {
  let empty = Bytes::make(0, (0).to_byte())
  for symbol in [65505.0, 65507.0, 65513.0, 65515.0, 65027.0] {
    let repeated = repeat_ingress_key_record(11.0, symbol, 0.0, 0.0, 1.0)
    assert_true(decode_v2_event(repeated, empty, "repeat_ingress") is Ok(None))
    let records = [(repeated, empty)]
    let counts = FixedArray::make(4, 0)
    let read = native_record_reader(records, counts)
    let dispatch = timeout => {
      counts[2] = counts[2] + 1
      counts[3] = counts[3] + timeout
      records.push(
        (repeat_ingress_key_record(11.0, symbol, 0.0, 0.0, 1.0), empty),
      )
      0
    }
    assert_true(next_event_from_native(read, dispatch, 37) is Ok(None))
    assert_eq(counts[0], 2)
    assert_eq(counts[1], 4)
    assert_eq(counts[2], 1)
    assert_eq(counts[3], 37)
  }
}
