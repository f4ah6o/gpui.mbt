///|
test "UTF-16 validator rejects unpaired surrogate code units" {
  assert_true(
    validate_utf16_units([UInt16(0xD83D), UInt16(0xDE00)][:]) is Ok(_),
  )
  assert_true(validate_utf16_units([UInt16(0xD800)][:]) is Err(MalformedUtf16))
  assert_true(validate_utf16_units([UInt16(0xDC00)][:]) is Err(MalformedUtf16))
  assert_true(
    validate_utf16_units([UInt16(0xD800), UInt16(0x0041)][:])
    is Err(MalformedUtf16),
  )
  assert_true(
    validate_utf16_units([UInt16(0xD800), UInt16(0xD800), UInt16(0xDC00)][:])
    is Err(MalformedUtf16),
  )
  assert_true(validate_utf16_units([UInt16(0x0041)][:]) is Ok(_))
  assert_true(validate_utf16_units([UInt16(0x0000)][:]) is Ok(_))
  assert_true(validate_utf16_units([UInt16(0x0000)][:0]) is Ok(_))
}

///|
test "checked text length detects overflow without allocating strings" {
  assert_true(
    checked_resulting_length(@int.MAX_VALUE, 0, 0) is Ok(@int.MAX_VALUE),
  )
  assert_true(
    checked_resulting_length(@int.MAX_VALUE, 1, 1) is Ok(@int.MAX_VALUE),
  )
  assert_true(
    checked_resulting_length(@int.MAX_VALUE, 0, 1) is Err(LengthOverflow),
  )
  assert_true(checked_resulting_length(4, 5, 0) is Err(OutOfBounds))
}
