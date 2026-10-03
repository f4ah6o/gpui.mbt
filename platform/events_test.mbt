///|
fn ingress_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid ingress point rejected")
  }
}

///|
test "event ingress preserves callback order and captures the latest scale" {
  let ingress = @platform.EventIngress::new(@platform.WindowId::new(42))
  ignore(ingress.enqueue(@platform.ScaleChanged, 2.0))
  ignore(ingress.enqueue(@platform.Resized(width=320.0, height=180.0), 2.0))
  ignore(
    ingress.enqueue(
      @platform.Input(
        @primitives.PointerMoved(position=ingress_point(16.0, 24.0)),
      ),
      2.0,
    ),
  )

  let drained = ingress.drain()
  assert_eq(drained.length(), 3)
  assert_true(drained[0].sequence() == 1)
  assert_true(drained[0].kind() is @platform.ScaleChanged)
  assert_true(drained[1].sequence() == 2)
  assert_true(drained[1].kind() is @platform.Resized(width=320.0, height=180.0))
  assert_true(drained[2].sequence() == 3)
  assert_true(drained[2].scale() == 2.0)
  assert_eq(drained[2].window().value(), 42)
  assert_eq(ingress.pending_count(), 0)
}

///|
test "event ingress coalesces wake notifications but keeps input work" {
  let ingress = @platform.EventIngress::new(@platform.WindowId::new(8))
  ignore(ingress.enqueue(@platform.VisibilityChanged(false), 1.0))
  assert_true(ingress.enqueue_wake(1.0) is Ok(true))
  assert_true(ingress.enqueue_wake(1.0) is Ok(false))
  assert_eq(ingress.pending_count(), 2)

  let first_drain = ingress.drain()
  assert_eq(first_drain.length(), 2)
  assert_true(first_drain[0].kind() is @platform.VisibilityChanged(false))
  assert_true(first_drain[1].kind() is @platform.Wake)
  assert_true(ingress.enqueue_wake(1.0) is Ok(true))
}

///|
test "event ingress validates scale and rejects work after teardown" {
  let ingress = @platform.EventIngress::new(@platform.WindowId::new(9))
  assert_true(
    ingress.enqueue(@platform.Wake, 0.0) is Err(@platform.InvalidScale),
  )
  assert_eq(ingress.pending_count(), 0)
  ignore(ingress.enqueue(@platform.Wake, 1.0))
  ingress.close()
  assert_true(ingress.is_closed())
  assert_eq(ingress.pending_count(), 0)
  assert_true(ingress.enqueue(@platform.Wake, 1.0) is Err(@platform.Closed))
}
