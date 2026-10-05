///|
fn drag_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(point) => point
    Err(_) => abort("finite drag test point rejected")
  }
}

///|
fn drag_gesture(threshold : Double) -> @element.DragGesture {
  match @element.DragGesture::new(threshold) {
    Ok(gesture) => gesture
    Err(_) => abort("valid drag test threshold rejected")
  }
}

///|
test "drag threshold rejects nonfinite negative and excessive distances" {
  for
    threshold in [
      @double.not_a_number,
      @double.infinity,
      @double.neg_infinity,
      -0.1,
      @element.MAX_DRAG_THRESHOLD + 1.0,
    ] {
    assert_true(
      @element.DragGesture::new(threshold) is Err(@element.InvalidThreshold),
    )
  }
  assert_true(@element.DragGesture::new(0.0) is Ok(_))
  assert_true(@element.DragGesture::new(-0.0) is Ok(_))
  assert_true(@element.DragGesture::new(@element.MAX_DRAG_THRESHOLD) is Ok(_))
}

///|
test "idle drag ignores update release and cancellation" {
  let idle = drag_gesture(5.0)
  assert_true(!idle.is_pending())
  assert_true(!idle.is_dragging())
  assert_true(idle.source() == None)
  assert_true(idle.origin() == None)
  assert_true(idle.position() == None)
  let (released, source) = idle
    .update(drag_point(10.0, 20.0))
    .release(drag_point(90.0, 20.0))
  assert_true(source == None)
  assert_true(released.source() == None)
  assert_true(released.origin() == None)
  assert_true(released.position() == None)
  assert_true(!released.is_pending() && !released.is_dragging())
  let cancelled = released.cancel().cancel()
  assert_true(cancelled.source() == None)
  assert_true(cancelled.origin() == None)
  assert_true(cancelled.position() == None)
}

///|
test "pending drag retains source origin and latest position immutably" {
  let origin = drag_point(10.0, 20.0)
  let latest = drag_point(12.0, 22.0)
  let idle = drag_gesture(5.0)
  let begun = idle.begin(42, origin)
  let moved = begun.update(latest)
  assert_true(idle.source() == None)
  assert_true(begun.is_pending() && !begun.is_dragging())
  assert_true(begun.source() == Some(42))
  assert_true(begun.origin() == Some(origin))
  assert_true(begun.position() == Some(origin))
  assert_true(moved.is_pending() && !moved.is_dragging())
  assert_true(moved.source() == Some(42))
  assert_true(moved.origin() == Some(origin))
  assert_true(moved.position() == Some(latest))
}

///|
test "drag activates at the threshold along every axis and diagonal" {
  let origin = drag_point(10.0, -20.0)
  let gesture = drag_gesture(5.0).begin(7, origin)
  for
    below in [
      drag_point(14.999, -20.0),
      drag_point(5.001, -20.0),
      drag_point(10.0, -15.001),
      drag_point(10.0, -24.999),
      drag_point(13.0, -17.0),
    ] {
    let pending = gesture.update(below)
    assert_true(pending.is_pending() && !pending.is_dragging())
  }
  for
    boundary in [
      drag_point(15.0, -20.0),
      drag_point(5.0, -20.0),
      drag_point(10.0, -15.0),
      drag_point(10.0, -25.0),
      drag_point(13.0, -16.0),
      drag_point(7.0, -24.0),
    ] {
    let active = gesture.update(boundary)
    assert_true(active.is_dragging() && !active.is_pending())
    assert_true(active.origin() == Some(origin))
    assert_true(active.position() == Some(boundary))
  }
}

///|
test "zero drag threshold activates on begin and releases without movement" {
  let origin = drag_point(1.0, 2.0)
  let gesture = drag_gesture(0.0).begin(0, origin)
  assert_true(gesture.is_dragging() && !gesture.is_pending())
  let (idle, source) = gesture.release(origin)
  assert_true(source == Some(0))
  assert_true(idle.source() == None)
  assert_true(!idle.is_pending() && !idle.is_dragging())
  let (_, duplicate) = idle.release(origin)
  assert_true(duplicate == None)
}

///|
test "activated drag stays active when returning to its origin" {
  let origin = drag_point(10.0, 20.0)
  let pending = drag_gesture(5.0).begin(7, origin)
  let active = pending.update(drag_point(15.0, 20.0)).update(origin)
  assert_true(pending.is_pending())
  assert_true(active.is_dragging() && !active.is_pending())
  assert_true(active.source() == Some(7))
  assert_true(active.origin() == Some(origin))
  assert_true(active.position() == Some(origin))
  let (_, source) = active.release(origin)
  assert_true(source == Some(7))
}

///|
test "release distinguishes a click and clears pending metadata" {
  let origin = drag_point(10.0, 20.0)
  let pending = drag_gesture(5.0).begin(42, origin)
  let (idle, source) = pending.release(drag_point(13.0, 23.0))
  assert_true(source == None)
  assert_true(idle.source() == None)
  assert_true(idle.origin() == None)
  assert_true(idle.position() == None)
  assert_true(!idle.is_pending() && !idle.is_dragging())
  assert_true(pending.is_pending())
  let repeated = idle.begin(43, origin).update(drag_point(14.0, 20.0))
  assert_true(repeated.is_pending())
  assert_true(repeated.update(drag_point(15.0, 20.0)).is_dragging())
}

///|
test "release evaluates the final point when no move event arrived" {
  let origin = drag_point(0.0, 0.0)
  let far = drag_point(100.0, 100.0)
  for final_position in [drag_point(3.0, 4.0), far] {
    let (idle, source) = drag_gesture(5.0)
      .begin(42, origin)
      .release(final_position)
    assert_true(source == Some(42))
    assert_true(idle.source() == None)
    assert_true(idle.origin() == None)
    assert_true(idle.position() == None)
    assert_true(!idle.is_pending() && !idle.is_dragging())
    let (still_idle, duplicate) = idle.release(far)
    assert_true(duplicate == None)
    assert_true(still_idle.source() == None)
  }
}

///|
test "cancel clears pending and active drags without producing a drop" {
  let origin = drag_point(0.0, 0.0)
  let pending = drag_gesture(5.0).begin(9, origin)
  for gesture in [pending, pending.update(drag_point(6.0, 0.0))] {
    let cancelled = gesture.cancel()
    assert_true(cancelled.source() == None)
    assert_true(cancelled.origin() == None)
    assert_true(cancelled.position() == None)
    assert_true(!cancelled.is_pending() && !cancelled.is_dragging())
    let (_, released) = cancelled.release(drag_point(100.0, 100.0))
    assert_true(released == None)
    let restarted = cancelled.begin(10, origin).update(drag_point(4.0, 0.0))
    assert_true(restarted.is_pending())
    assert_true(restarted.source() == Some(10))
    assert_true(restarted.update(drag_point(5.0, 0.0)).is_dragging())
  }
}

///|
test "repeated begin cannot replace a pending or active source" {
  let origin = drag_point(1.0, 2.0)
  let pending = drag_gesture(5.0).begin(7, origin).update(drag_point(2.0, 3.0))
  let active = pending.update(drag_point(9.0, 2.0))
  for gesture in [pending, active] {
    let unchanged = gesture.begin(99, drag_point(100.0, 100.0))
    assert_true(unchanged.source() == gesture.source())
    assert_true(unchanged.origin() == gesture.origin())
    assert_true(unchanged.position() == gesture.position())
    assert_true(unchanged.is_pending() == gesture.is_pending())
    assert_true(unchanged.is_dragging() == gesture.is_dragging())
  }
  let (idle, _) = active.release(origin)
  let next = idle.begin(99, drag_point(100.0, 100.0))
  assert_true(next.source() == Some(99))
  assert_true(next.is_pending())
}

///|
test "drag distance handles finite extreme coordinates without overflow" {
  let maximum = @double.max_value
  let far_positive = drag_point(maximum, maximum)
  let far_negative = drag_point(-maximum, -maximum)
  let threshold = @element.MAX_DRAG_THRESHOLD
  for origin in [far_positive, far_negative] {
    let pending = drag_gesture(threshold).begin(7, origin).update(origin)
    assert_true(pending.is_pending())
    let crossed = pending.update(
      if origin == far_positive {
        far_negative
      } else {
        far_positive
      },
    )
    assert_true(crossed.is_dragging())
    assert_true(pending.update(drag_point(0.0, 0.0)).is_dragging())
  }
  let same_sign = drag_gesture(threshold)
    .begin(7, far_positive)
    .update(drag_point(1.0e308, maximum))
  assert_true(same_sign.is_dragging())
}

///|
test "drag normalization preserves tiny thresholds and opposite signs" {
  let tiny = 1.0e-300
  let origin = drag_point(0.0, 0.0)
  let pending = drag_gesture(tiny).begin(7, origin)
  assert_true(pending.update(drag_point(0.5e-300, 0.5e-300)).is_pending())
  assert_true(pending.update(drag_point(0.8e-300, 0.8e-300)).is_dragging())
  assert_true(pending.update(drag_point(tiny, 0.0)).is_dragging())
  let crossed = drag_gesture(5.0).begin(7, drag_point(-1.0, -1.0))
  assert_true(crossed.update(drag_point(1.0, 1.0)).is_pending())
  assert_true(crossed.update(drag_point(2.0, 3.0)).is_dragging())
}
