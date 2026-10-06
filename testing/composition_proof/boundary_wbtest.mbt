///|
test "range length machine limits and source-exact Unicode partitions" {
  assert_eq(({ start: 0, end: 2147483647, } : TextRange).length(), 2147483647)
  assert_eq(({ start: 2147483647, end: 2147483647, } : TextRange).length(), 0)
  assert_eq(({ start: 4, end: 9, } : TextRange).length(), 5)
  for
    (scalar, width8, width16) in [
      (0, 1, 1),
      (0x7F, 1, 1),
      (0x80, 2, 1),
      (0x7FF, 2, 1),
      (0x800, 3, 1),
      (0xD7FF, 3, 1),
      (0xE000, 3, 1),
      (0xFFFF, 3, 1),
      (0x10000, 4, 2),
      (0x10FFFF, 4, 2),
    ] {
    assert_eq(utf8_scalar_width(scalar), width8)
    assert_eq(utf16_scalar_width(scalar), width16)
  }
}
