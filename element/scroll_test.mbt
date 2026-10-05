///|
fn scroll_size(width : Double, height : Double) -> @primitives.Size {
  match @primitives.Size::new(width, height) {
    Ok(value) => value
    Err(_) => abort("valid scroll size rejected")
  }
}

///|
fn scroll_bounds(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("valid scroll bounds rejected")
  }
}

///|
fn scroll_ok(
  result : Result[@element.ScrollState, @element.ScrollError],
) -> @element.ScrollState {
  match result {
    Ok(value) => value
    Err(_) => abort("finite scroll update rejected")
  }
}

///|
test "scroll offsets clamp independently and leave the source unchanged" {
  let initial = @element.ScrollState::new(
    scroll_size(100.0, 80.0),
    scroll_size(360.0, 240.0),
  )
  assert_true(initial.offset().x() == 0.0)
  assert_true(initial.offset().y() == 0.0)
  assert_true(initial.max_offset().x() == 260.0)
  assert_true(initial.max_offset().y() == 160.0)
  let moved = scroll_ok(initial.scroll_to(60.0, 50.0))
  let clamped = scroll_ok(moved.scroll_by(-80.0, 200.0))
  assert_true(clamped.offset().x() == 0.0)
  assert_true(clamped.offset().y() == 160.0)
  let horizontal = scroll_ok(clamped.scroll_by(90.0, 0.0))
  assert_true(horizontal.offset().x() == 90.0)
  assert_true(horizontal.offset().y() == 160.0)
  let absolute = scroll_ok(horizontal.scroll_to(999.0, -20.0))
  assert_true(absolute.offset().x() == 260.0)
  assert_true(absolute.offset().y() == 0.0)
  assert_true(initial.offset().x() == 0.0 && initial.offset().y() == 0.0)
  assert_true(moved.offset().x() == 60.0 && moved.offset().y() == 50.0)
}

///|
test "content fitting the viewport cannot scroll on either axis" {
  let fitted = @element.ScrollState::new(
    scroll_size(100.0, 80.0),
    scroll_size(50.0, 80.0),
  )
  assert_true(fitted.max_offset().x() == 0.0)
  assert_true(fitted.max_offset().y() == 0.0)
  let moved = scroll_ok(fitted.scroll_by(200.0, -200.0))
  assert_true(moved.offset().x() == 0.0 && moved.offset().y() == 0.0)
  let outside = moved.ensure_visible(scroll_bounds(400.0, 500.0, 10.0, 10.0))
  assert_true(outside.offset().x() == 0.0 && outside.offset().y() == 0.0)
}

///|
test "layout changes retain valid offsets and clamp only changed limits" {
  let moved = scroll_ok(
    @element.ScrollState::new(
      scroll_size(100.0, 80.0),
      scroll_size(400.0, 300.0),
    ).scroll_to(240.0, 170.0),
  )
  let shrunk = moved.with_sizes(
    scroll_size(100.0, 80.0),
    scroll_size(180.0, 300.0),
  )
  assert_true(shrunk.offset().x() == 80.0)
  assert_true(shrunk.offset().y() == 170.0)
  let larger_viewport = shrunk.with_sizes(
    scroll_size(200.0, 160.0),
    scroll_size(180.0, 300.0),
  )
  assert_true(larger_viewport.offset().x() == 0.0)
  assert_true(larger_viewport.offset().y() == 140.0)
  let grown = larger_viewport.with_sizes(
    scroll_size(50.0, 50.0),
    scroll_size(500.0, 500.0),
  )
  assert_true(grown.offset().x() == 0.0 && grown.offset().y() == 140.0)
  assert_true(moved.offset().x() == 240.0 && moved.offset().y() == 170.0)
}

///|
test "ensure visible moves minimally and preserves already visible bounds" {
  let state = scroll_ok(
    @element.ScrollState::new(
      scroll_size(100.0, 80.0),
      scroll_size(500.0, 500.0),
    ).scroll_to(100.0, 100.0),
  )
  let visible = state.ensure_visible(scroll_bounds(100.0, 100.0, 100.0, 80.0))
  assert_true(visible.offset().x() == 100.0 && visible.offset().y() == 100.0)
  let left_bottom = state.ensure_visible(scroll_bounds(90.0, 170.0, 20.0, 20.0))
  assert_true(left_bottom.offset().x() == 90.0)
  assert_true(left_bottom.offset().y() == 110.0)
  let right_top = state.ensure_visible(scroll_bounds(190.0, 80.0, 30.0, 20.0))
  assert_true(right_top.offset().x() == 120.0)
  assert_true(right_top.offset().y() == 80.0)
  let repeated = right_top.ensure_visible(
    scroll_bounds(190.0, 80.0, 30.0, 20.0),
  )
  assert_true(repeated.offset() == right_top.offset())
}

///|
test "oversized reveal aligns the leading edge consistently per axis" {
  let state = scroll_ok(
    @element.ScrollState::new(
      scroll_size(100.0, 80.0),
      scroll_size(500.0, 500.0),
    ).scroll_to(100.0, 100.0),
  )
  let target = scroll_bounds(40.0, 20.0, 250.0, 220.0)
  let aligned = state.ensure_visible(target)
  assert_true(aligned.offset().x() == 40.0 && aligned.offset().y() == 20.0)
  assert_true(aligned.ensure_visible(target).offset() == aligned.offset())
  let mixed = state.ensure_visible(scroll_bounds(40.0, 170.0, 250.0, 20.0))
  assert_true(mixed.offset().x() == 40.0 && mixed.offset().y() == 110.0)
  let outside = state.ensure_visible(scroll_bounds(480.0, 460.0, 200.0, 200.0))
  assert_true(outside.offset().x() == 400.0 && outside.offset().y() == 420.0)
}

///|
test "zero viewport and outside bounds have stable bounded offsets" {
  let state = @element.ScrollState::new(
    scroll_size(0.0, 0.0),
    scroll_size(100.0, 80.0),
  )
  assert_true(state.max_offset().x() == 100.0 && state.max_offset().y() == 80.0)
  let reveal = state.ensure_visible(scroll_bounds(20.0, 30.0, 10.0, 10.0))
  assert_true(reveal.offset().x() == 20.0 && reveal.offset().y() == 30.0)
  let point = reveal.ensure_visible(scroll_bounds(60.0, 70.0, 0.0, 0.0))
  assert_true(point.offset().x() == 60.0 && point.offset().y() == 70.0)
  let outside = point.ensure_visible(scroll_bounds(-50.0, 120.0, 20.0, 10.0))
  assert_true(outside.offset().x() == 0.0 && outside.offset().y() == 80.0)
  let empty = outside.with_sizes(scroll_size(0.0, 0.0), scroll_size(0.0, 0.0))
  assert_true(empty.offset().x() == 0.0 && empty.offset().y() == 0.0)
}

///|
test "huge finite deltas saturate without overflowing stored offsets" {
  let largest = 1.7976931348623157e308
  let state = @element.ScrollState::new(
    scroll_size(0.0, 0.0),
    scroll_size(largest, largest),
  )
  let moved = scroll_ok(state.scroll_to(1.0e308, 1.0e308))
  let end = scroll_ok(moved.scroll_by(largest, largest))
  assert_true(end.offset().x() == largest && end.offset().y() == largest)
  let still_end = scroll_ok(end.scroll_by(largest, 1.0))
  assert_true(still_end.offset() == end.offset())
  let start = scroll_ok(end.scroll_by(-largest, -largest))
  assert_true(start.offset().x() == 0.0 && start.offset().y() == 0.0)
  let still_start = scroll_ok(start.scroll_by(-largest, -largest))
  assert_true(still_start.offset() == start.offset())
  let small = end.with_sizes(scroll_size(50.0, 50.0), scroll_size(100.0, 100.0))
  assert_true(small.offset().x() == 50.0 && small.offset().y() == 50.0)
}

///|
test "huge finite reveal stays within content on independent axes" {
  let state = scroll_ok(
    @element.ScrollState::new(
      scroll_size(8.0e307, 8.0e307),
      scroll_size(1.7e308, 1.7e308),
    ).scroll_to(8.0e307, 8.0e307),
  )
  let target = scroll_bounds(-1.7e308, 1.6e308, 0.0, 0.0)
  let reveal = state.ensure_visible(target)
  assert_true(reveal.offset().x() == 0.0)
  assert_true(reveal.offset().y() == 8.0e307)
  let oversized = reveal.ensure_visible(
    scroll_bounds(-1.7e308, 0.0, 1.7e308, 1.7e308),
  )
  assert_true(oversized.offset().x() == 0.0 && oversized.offset().y() == 0.0)
}

///|
test "non-finite updates reject both axes without changing the value" {
  let state = scroll_ok(
    @element.ScrollState::new(
      scroll_size(100.0, 100.0),
      scroll_size(400.0, 400.0),
    ).scroll_to(20.0, 30.0),
  )
  for invalid in [@double.not_a_number, @double.infinity, @double.neg_infinity] {
    assert_true(state.scroll_by(invalid, 10.0) is Err(NonFiniteValue))
    assert_true(state.scroll_by(10.0, invalid) is Err(NonFiniteValue))
    assert_true(state.scroll_to(invalid, 10.0) is Err(NonFiniteValue))
    assert_true(state.scroll_to(10.0, invalid) is Err(NonFiniteValue))
  }
  assert_true(state.offset().x() == 20.0 && state.offset().y() == 30.0)
  assert_true(
    state.max_offset().x() == 300.0 && state.max_offset().y() == 300.0,
  )
}
