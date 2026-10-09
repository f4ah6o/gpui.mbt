///|
test "accessibility owner identity sequence never wraps" {
  let start = { next: MAX_UINT64 - 1UL, exhausted: false, }
  let (after_before_max, before_max) = advance_owner_sequence(start)
  let (after_max, at_max) = advance_owner_sequence(after_before_max)
  let (after_exhaustion, after_max_id) = advance_owner_sequence(after_max)

  assert_true(before_max == Some(MAX_UINT64 - 1UL))
  assert_true(at_max == Some(MAX_UINT64))
  assert_true(after_max_id is None)
  assert_true(after_exhaustion.exhausted)
  assert_true(after_exhaustion.next == MAX_UINT64)
}
