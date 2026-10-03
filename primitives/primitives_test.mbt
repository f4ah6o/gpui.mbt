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
