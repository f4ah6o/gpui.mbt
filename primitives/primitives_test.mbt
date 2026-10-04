///|
test "geometry constructors reject invalid and unrepresentable values" {
  assert_true(@primitives.Point::new(1.0, -2.0) is Ok(_))
  assert_true(
    @primitives.Point::new(@double.not_a_number, 0.0) is Err(NonFiniteValue),
  )
  assert_true(
    @primitives.Point::new(@double.infinity, 0.0) is Err(NonFiniteValue),
  )
  assert_true(@primitives.Size::new(-0.1, 1.0) is Err(NegativeExtent))
  assert_true(
    @primitives.Size::new(1.0, @double.neg_infinity) is Err(NonFiniteValue),
  )
  assert_true(
    @primitives.Rect::new(0.0, 0.0, @double.infinity, 1.0)
    is Err(NonFiniteValue),
  )
  assert_true(
    @primitives.Rect::new(1.0e308, 0.0, 1.0e308, 1.0) is Err(BoundsOverflow),
  )
  assert_true(
    @primitives.Rect::new(1.0e16, 0.0, 1.0, 1.0) is Err(BoundsNotRepresentable),
  )
  assert_true(
    @primitives.Rect::new(0.0, 1.0e16, 1.0, 1.0) is Err(BoundsNotRepresentable),
  )
}

///|
test "rectangles contain representable edges and compose geometry operations" {
  let rect = match @primitives.Rect::new(-20.0, -10.0, 40.0, 20.0) {
    Ok(value) => value
    Err(_) => fail("valid rectangle was rejected")
  }
  let top_left = match @primitives.Point::new(rect.left(), rect.top()) {
    Ok(value) => value
    Err(_) => fail("finite edge point was rejected")
  }
  let bottom_right = match @primitives.Point::new(rect.right(), rect.bottom()) {
    Ok(value) => value
    Err(_) => fail("finite edge point was rejected")
  }
  assert_true(rect.contains(top_left))
  assert_true(rect.contains(bottom_right))
  assert_true(rect.clamp_point(top_left) == top_left)

  let other = match @primitives.Rect::new(0.0, 0.0, 30.0, 25.0) {
    Ok(value) => value
    Err(_) => fail("valid rectangle was rejected")
  }
  match rect.intersection(other) {
    Some(overlap) => {
      assert_true(rect.contains_rect(overlap))
      assert_true(other.contains_rect(overlap))
      assert_true(overlap.left() == 0.0 && overlap.top() == 0.0)
    }
    None => fail("expected a non-empty intersection")
  }
  let union = match rect.union(other) {
    Ok(value) => value
    Err(_) => fail("representable union was rejected")
  }
  assert_true(union.contains_rect(rect))
  assert_true(union.contains_rect(other))
  assert_true(rect.union(rect) is Ok(value) && value == rect)
}

///|
test "geometry scale round trips and rejects overflow" {
  let point = match @primitives.Point::new(1.5, -2.25) {
    Ok(value) => value
    Err(_) => fail("finite point was rejected")
  }
  match point.scaled(2.0) {
    Ok(enlarged) => {
      assert_true(enlarged.scaled(0.5) is Ok(restored) && restored == point)
      assert_true(point.scaled(@double.infinity) is Err(NonFiniteValue))
      assert_true(
        test_point(0.0, 0.0).scaled(@double.infinity) is Err(NonFiniteValue),
      )
      assert_true(point.scaled(@double.not_a_number) is Err(NonFiniteValue))
    }
    Err(_) => fail("finite scale was rejected")
  }
  let rect = match @primitives.Rect::new(1.0, 2.0, 3.0, 4.0) {
    Ok(value) => value
    Err(_) => fail("valid rectangle was rejected")
  }
  match rect.scaled(2.0) {
    Ok(enlarged) => {
      assert_true(enlarged.scaled(0.5) is Ok(restored) && restored == rect)
      assert_true(enlarged.left() == 2.0 && enlarged.bottom() == 12.0)
    }
    Err(_) => fail("finite scale was rejected")
  }
  match rect.scaled(-1.0) {
    Ok(mirrored) => {
      assert_true(mirrored.left() == -4.0 && mirrored.right() == -1.0)
      assert_true(mirrored.top() == -6.0 && mirrored.bottom() == -2.0)
    }
    Err(_) => fail("finite negative scale was rejected")
  }
  assert_true(rect.scaled(1.0e308) is Err(BoundsOverflow))
}

///|
test "point and rectangle translations apply the requested signed offset" {
  let point = test_point(10.0, -3.0)
  let offset = test_point(-2.0, 4.0)
  match point.translated(offset) {
    Ok(moved) => assert_true(moved.x() == 8.0 && moved.y() == 1.0)
    Err(_) => fail("finite point translation was rejected")
  }

  let rect = test_rect(10.0, 20.0, 3.0, 4.0)
  match rect.translated(offset) {
    Ok(moved) => {
      assert_true(moved.left() == 8.0 && moved.top() == 24.0)
      assert_true(moved.size().width() == 3.0 && moved.size().height() == 4.0)
    }
    Err(_) => fail("finite rectangle translation was rejected")
  }
}

///|
test "rectangle containment rejects a child crossing each individual edge" {
  let outer = test_rect(0.0, 0.0, 10.0, 10.0)
  assert_false(outer.contains_rect(test_rect(-1.0, 2.0, 5.0, 5.0)))
  assert_false(outer.contains_rect(test_rect(5.0, 2.0, 6.0, 5.0)))
  assert_false(outer.contains_rect(test_rect(2.0, -1.0, 5.0, 5.0)))
  assert_false(outer.contains_rect(test_rect(2.0, 5.0, 5.0, 6.0)))
}

///|
test "rectangle intersection is absent when either axis is separated" {
  let left = test_rect(0.0, 0.0, 2.0, 2.0)
  let right = test_rect(3.0, 0.0, 2.0, 2.0)
  let above = test_rect(0.0, 3.0, 2.0, 2.0)
  assert_true(left.intersection(right) is None)
  assert_true(left.intersection(above) is None)
}

///|
test "rectangle scaling reports non-finite factors and overflowing extents" {
  let ordinary = test_rect(1.0, 2.0, 3.0, 4.0)
  assert_true(ordinary.scaled(@double.infinity) is Err(NonFiniteValue))
  assert_true(ordinary.scaled(@double.not_a_number) is Err(NonFiniteValue))

  let width_overflow = test_rect(-8.0e307, 0.0, 1.6e308, 0.0)
  let height_overflow = test_rect(0.0, -8.0e307, 0.0, 1.6e308)
  assert_true(width_overflow.scaled(1.5) is Err(BoundsOverflow))
  assert_true(height_overflow.scaled(1.5) is Err(BoundsOverflow))
}

///|
test "rectangle union rejects a rounded bound that would exclude an input" {
  let left = test_rect(-1.0e16, 0.0, 0.0, 0.0)
  let right = test_rect(1.0, 0.0, 0.0, 0.0)
  assert_true(left.union(right) is Err(BoundsNotRepresentable))
}

///|
test "clamping preserves interior points and clamps each outside edge" {
  let rect = test_rect(0.0, 0.0, 10.0, 10.0)
  let center = test_point(5.0, 5.0)
  assert_true(rect.clamp_point(center) == center)
  assert_true(rect.clamp_point(test_point(-1.0, 5.0)) == test_point(0.0, 5.0))
  assert_true(rect.clamp_point(test_point(11.0, 5.0)) == test_point(10.0, 5.0))
  assert_true(rect.clamp_point(test_point(5.0, -1.0)) == test_point(5.0, 0.0))
  assert_true(rect.clamp_point(test_point(5.0, 11.0)) == test_point(5.0, 10.0))
}

///|
test "rectangle union reports spans that cannot be represented" {
  let left = match @primitives.Rect::new(-1.0e308, 0.0, 1.0e307, 1.0) {
    Ok(value) => value
    Err(_) => fail("valid finite rectangle was rejected")
  }
  let right = match @primitives.Rect::new(1.0e308, 0.0, 1.0e307, 1.0) {
    Ok(value) => value
    Err(_) => fail("valid finite rectangle was rejected")
  }
  assert_true(left.union(right) is Err(BoundsOverflow))
}

///|
test "color validates every rgba channel" {
  let color = match @primitives.Color::rgba(20, 40, 60, 255) {
    Ok(value) => value
    Err(_) => fail("valid color was rejected")
  }
  assert_true(color.red() == 20 && color.green() == 40)
  assert_true(color.blue() == 60 && color.alpha() == 255)
  assert_true(color.is_opaque())
  assert_true(@primitives.Color::rgba(-1, 0, 0, 0) is Err(ChannelOutOfRange))
  assert_true(@primitives.Color::rgba(0, 256, 0, 0) is Err(ChannelOutOfRange))
  assert_true(@primitives.Color::rgba(0, 0, 256, 0) is Err(ChannelOutOfRange))
  assert_true(@primitives.Color::rgba(0, 0, 0, 256) is Err(ChannelOutOfRange))
  assert_true(
    @primitives.Color::rgba(255, 255, 255, 0) is Ok(value) && !value.is_opaque(),
  )
}

///|
test "input values preserve keys modifiers pointer coordinates and text" {
  let no_modifiers = @primitives.Modifiers::none()
  assert_true(no_modifiers.is_empty())
  let modifiers = @primitives.Modifiers::new(
    shift=true,
    control=true,
    alt=false,
    meta=true,
  )
  assert_true(modifiers.shift() && modifiers.control() && modifiers.meta())
  assert_true(!modifiers.alt() && !modifiers.is_empty())

  let keys : Array[@primitives.Key] = [
    Character("x"),
    Enter,
    Escape,
    Backspace,
    Delete,
    Tab,
    Space,
    ArrowLeft,
    ArrowRight,
    ArrowUp,
    ArrowDown,
    Home,
    End,
    PageUp,
    PageDown,
  ]
  let buttons : Array[@primitives.MouseButton] = [
    Primary,
    Secondary,
    Middle,
    Back,
    Forward,
  ]
  assert_true(keys.length() == 15 && buttons.length() == 5)
  let point = match @primitives.Point::new(12.5, 24.0) {
    Ok(value) => value
    Err(_) => fail("finite pointer location was rejected")
  }
  let delta = match @primitives.Point::new(-1.0, 3.0) {
    Ok(value) => value
    Err(_) => fail("finite scroll delta was rejected")
  }
  let events : Array[@primitives.InputEvent] = [
    KeyPressed(key=Enter, modifiers=no_modifiers, repeat=false),
    KeyReleased(key=Escape, modifiers~),
    TextInput(text="日本語"),
    PointerMoved(position=point),
    PointerButtonPressed(position=point, button=Primary, modifiers~),
    PointerButtonReleased(
      position=point,
      button=Secondary,
      modifiers=no_modifiers,
    ),
    Scroll(position=point, delta~, modifiers=no_modifiers),
  ]
  assert_true(events.length() == 7)
}

///|
test "modifier emptiness matches every combination of modifier bits" {
  for mask in 0..<16 {
    let shift = mask % 2 == 1
    let control = mask / 2 % 2 == 1
    let alt = mask / 4 % 2 == 1
    let meta = mask / 8 % 2 == 1
    let modifiers = @primitives.Modifiers::new(shift~, control~, alt~, meta~)
    assert_true(modifiers.is_empty() == (mask == 0))
  }
}

///|
test "rect containment, union, and scaling hold over deterministic values" {
  let starts : Array[Double] = [-100.0, -3.0, 0.0, 0.5, 8.0, 128.0]
  let extents : Array[Double] = [0.0, 0.25, 1.0, 7.5, 32.0]
  for x in starts {
    for y in starts {
      for width in extents {
        for height in extents {
          let rect = match @primitives.Rect::new(x, y, width, height) {
            Ok(value) => value
            Err(_) => fail("finite deterministic rectangle was rejected")
          }
          let corner = match
            @primitives.Point::new(rect.right(), rect.bottom()) {
            Ok(value) => value
            Err(_) => fail("representable corner was rejected")
          }
          assert_true(rect.contains(corner))
          assert_true(rect.union(rect) is Ok(value) && value == rect)
          match rect.scaled(2.0) {
            Ok(scaled) => {
              let scaled_origin = unwrap_point(rect.origin().scaled(2.0))
              assert_true(scaled.contains(scaled_origin))
            }
            Err(_) => fail("bounded scale was rejected")
          }
        }
      }
    }
  }
}

///|
fn unwrap_point(
  result : Result[@primitives.Point, @primitives.GeometryError],
) -> @primitives.Point raise {
  match result {
    Ok(value) => value
    Err(_) => fail("bounded point scale was rejected")
  }
}

///|
fn test_point(x : Double, y : Double) -> @primitives.Point raise {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => fail("finite test point was rejected")
  }
}

///|
fn test_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect raise {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => fail("valid test rectangle was rejected")
  }
}
