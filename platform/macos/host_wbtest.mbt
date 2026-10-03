///|
test "native statuses preserve stable framework categories" {
  let cases = [
    (1, @diagnostics.AppNotRunning),
    (5, @diagnostics.InvalidInput),
    (9, @diagnostics.UnsupportedCapability),
    (10, @diagnostics.StaleHandle),
    (12, @diagnostics.Busy),
    (13, @diagnostics.ResourceExhausted),
    (14, @diagnostics.WindowUnavailable),
    (15, @diagnostics.SurfaceLost),
    (16, @diagnostics.DeviceLost),
    (17, @diagnostics.ConversionFailed),
    (18, @diagnostics.WrongThread),
    (19, @diagnostics.HostStopping),
    (20, @diagnostics.NativeFailure),
  ]
  for (native, expected) in cases {
    match status(native, "operation") {
      Ok(_) => fail("failure was reported as success")
      Err(error) => {
        assert_eq(error.code().label(), expected.label())
        assert_eq(error.operation(), "operation")
        assert_true(error.backend() == Some("macos-metal"))
      }
    }
  }
  match status(0, "operation") {
    Ok(_) => ()
    Err(_) => fail("success rejected")
  }
}

///|
test "macOS physical control keys map to portable input" {
  assert_true(key_from_code(49, "") == @primitives.Space)
  assert_true(key_from_code(36, "") == @primitives.Enter)
  assert_true(key_from_code(76, "") == @primitives.Enter)
  assert_true(key_from_code(53, "") == @primitives.Escape)
  assert_true(key_from_code(123, "") == @primitives.ArrowLeft)
  assert_true(key_from_code(126, "") == @primitives.ArrowUp)
}

///|
test "printable keys retain native Unicode payload" {
  assert_true(key_from_code(0, "あ😀") == @primitives.Character("あ😀"))
}
