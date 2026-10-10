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

///|
test "scroll decoder preserves logical position, native deltas and modifiers" {
  let mods = @primitives.Modifiers::new(
    shift=true,
    control=false,
    alt=true,
    meta=true,
  )
  match decode_scroll_event(12.5, 8.25, -4.5, 7.25, mods) {
    Ok(@platform.Input(@primitives.Scroll(position~, delta~, modifiers=actual))) => {
      assert_eq(position.x(), 12.5)
      assert_eq(position.y(), 8.25)
      assert_eq(delta.x(), -4.5)
      assert_eq(delta.y(), 7.25)
      assert_true(actual.shift() && actual.alt() && actual.meta())
      assert_true(!actual.control())
    }
    _ => fail("valid scroll values were rejected")
  }
  assert_true(decode_scroll_event(0.0 / 0.0, 0.0, 0.0, 1.0, mods) is Err(_))
  assert_true(decode_scroll_event(0.0, 0.0, 0.0, 1.0 / 0.0, mods) is Err(_))
}
