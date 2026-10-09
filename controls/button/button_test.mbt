///|
fn button_test_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("valid button test bounds rejected")
  }
}

///|
fn button_test_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid button test point rejected")
  }
}

///|
fn button_test_button() -> @button.Button {
  @button.Button::new(
    17UL,
    button_test_rect(20.0, 30.0, 160.0, 40.0),
    "Save changes",
  ).unwrap()
}

///|
fn button_test_pointer(
  press : Bool,
  x : Double,
  y : Double,
  primary : Bool,
) -> @primitives.InputEvent {
  let point = button_test_point(x, y)
  if press {
    @primitives.PointerButtonPressed(
      position=point,
      button=if primary { @primitives.Primary } else { @primitives.Secondary },
      modifiers=@primitives.Modifiers::none(),
    )
  } else {
    @primitives.PointerButtonReleased(
      position=point,
      button=if primary { @primitives.Primary } else { @primitives.Secondary },
      modifiers=@primitives.Modifiers::none(),
    )
  }
}

///|
fn button_test_key_down(
  key : @primitives.Key,
  repeat : Bool,
) -> @primitives.InputEvent {
  @primitives.KeyPressed(key~, modifiers=@primitives.Modifiers::none(), repeat~)
}

///|
fn button_test_key_up(key : @primitives.Key) -> @primitives.InputEvent {
  @primitives.KeyReleased(key~, modifiers=@primitives.Modifiers::none())
}

///|
test "pointer activation requires one primary in-bounds down and up" {
  let button = button_test_button()
  let (pressed, down) = button.handle_input(
    button_test_pointer(true, 40.0, 50.0, true),
  )
  assert_true(down.consumed())
  assert_true(down.effect() is @button.None)
  assert_true(pressed.is_pressed())

  let (released, up) = pressed.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(up.consumed())
  assert_true(up.effect() is @button.Activated)
  assert_true(!released.is_pressed())

  let (_, stray_up) = released.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(stray_up.effect() is @button.None)
}

///|
test "pointer repeats do not duplicate a press and outside release cancels it" {
  let button = button_test_button()
  let (pressed, first_down) = button.handle_input(
    button_test_pointer(true, 40.0, 50.0, true),
  )
  let (pressed_again, duplicate_down) = pressed.handle_input(
    button_test_pointer(true, 40.0, 50.0, true),
  )
  assert_true(first_down.effect() is @button.None)
  assert_true(duplicate_down.effect() is @button.None)
  assert_true(pressed_again.is_pressed())
  let (cancelled, outside_up) = pressed_again.handle_input(
    button_test_pointer(false, 260.0, 90.0, true),
  )
  assert_true(outside_up.effect() is @button.None)
  assert_true(!cancelled.is_pressed())
  let (_, later_up) = cancelled.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(later_up.effect() is @button.None)
}

///|
test "outside origins and secondary mouse buttons never arm the control" {
  let button = button_test_button()
  let (outside_down, outside) = button.handle_input(
    button_test_pointer(true, 260.0, 90.0, true),
  )
  assert_true(outside.effect() is @button.None)
  assert_true(!outside_down.is_pressed())
  let (_, inside_up) = outside_down.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(inside_up.effect() is @button.None)

  let (secondary, secondary_down) = button.handle_input(
    button_test_pointer(true, 40.0, 50.0, false),
  )
  let (_, secondary_up) = secondary.handle_input(
    button_test_pointer(false, 40.0, 50.0, false),
  )
  assert_true(secondary_down.effect() is @button.None)
  assert_true(secondary_up.effect() is @button.None)
  assert_true(!secondary.is_pressed())
}

///|
test "Enter activates on its first key-down and ignores repeats until release" {
  let button = button_test_button().with_focus(true)
  let (held, first_down) = button.handle_input(
    button_test_key_down(@primitives.Enter, false),
  )
  assert_true(first_down.effect() is @button.Activated)
  assert_true(held.is_pressed())

  let (repeated, repeat_down) = held.handle_input(
    button_test_key_down(@primitives.Enter, true),
  )
  assert_true(repeat_down.consumed())
  assert_true(repeat_down.effect() is @button.None)
  let (released, key_up) = repeated.handle_input(
    button_test_key_up(@primitives.Enter),
  )
  assert_true(key_up.effect() is @button.None)
  assert_true(!released.is_pressed())
  let (_, unmatched_repeat) = released.handle_input(
    button_test_key_down(@primitives.Enter, true),
  )
  assert_true(unmatched_repeat.effect() is @button.None)
}

///|
test "Enter blur cancels its repeat latch and only a fresh down activates again" {
  let button = button_test_button().with_focus(true)
  let (held, first_down) = button.handle_input(
    button_test_key_down(@primitives.Enter, false),
  )
  assert_true(first_down.effect() is @button.Activated)

  let refocused = held.with_focus(false).with_focus(true)
  let (after_repeat, stale_repeat) = refocused.handle_input(
    button_test_key_down(@primitives.Enter, true),
  )
  assert_true(stale_repeat.effect() is @button.None)
  let (after_release, stale_release) = after_repeat.handle_input(
    button_test_key_up(@primitives.Enter),
  )
  assert_true(stale_release.effect() is @button.None)
  assert_true(!after_release.is_pressed())

  let (_, fresh_down) = after_release.handle_input(
    button_test_key_down(@primitives.Enter, false),
  )
  assert_true(fresh_down.effect() is @button.Activated)
}

///|
test "Space activates once on matching release and blur cancels the hold" {
  let button = button_test_button().with_focus(true)
  let (held, down) = button.handle_input(
    button_test_key_down(@primitives.Space, false),
  )
  assert_true(down.effect() is @button.None)
  assert_true(held.is_pressed())

  let (repeated, repeat_down) = held.handle_input(
    button_test_key_down(@primitives.Space, true),
  )
  assert_true(repeat_down.effect() is @button.None)
  let (released, up) = repeated.handle_input(
    button_test_key_up(@primitives.Space),
  )
  assert_true(up.effect() is @button.Activated)
  assert_true(!released.is_pressed())
  let (_, stray_up) = released.handle_input(
    button_test_key_up(@primitives.Space),
  )
  assert_true(stray_up.effect() is @button.None)

  let (armed, _) = button.handle_input(
    button_test_key_down(@primitives.Space, false),
  )
  let blurred = armed.with_focus(false)
  let (_, blur_up) = blurred.handle_input(button_test_key_up(@primitives.Space))
  assert_true(!blurred.is_pressed())
  assert_true(blur_up.effect() is @button.None)
}

///|
test "disabled and loading transitions cancel pointer and keyboard activation" {
  let button = button_test_button().with_focus(true)
  let (pointer_held, _) = button.handle_input(
    button_test_pointer(true, 40.0, 50.0, true),
  )
  let disabled = pointer_held.with_enabled(false)
  let (_, disabled_up) = disabled.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(!disabled.is_focused())
  assert_true(!disabled.is_pressed())
  assert_true(!disabled.element_node(None).is_focusable())
  assert_true(!disabled.with_focus(true).is_focused())
  assert_true(disabled_up.effect() is @button.None)
  let (_, disabled_enter) = disabled.handle_input(
    button_test_key_down(@primitives.Enter, false),
  )
  assert_true(disabled_enter.effect() is @button.None)

  let (space_held, _) = button.handle_input(
    button_test_key_down(@primitives.Space, false),
  )
  let loading = space_held.with_loading(true)
  let (_, loading_up) = loading.handle_input(
    button_test_key_up(@primitives.Space),
  )
  assert_true(!loading.can_activate())
  assert_true(loading.is_focused())
  assert_true(!loading.is_pressed())
  assert_true(loading.element_node(None).is_focusable())
  assert_true(!loading.element_node(None).accepts_pointer_events())
  assert_true(loading_up.effect() is @button.None)
  let (_, loading_enter) = loading.handle_input(
    button_test_key_down(@primitives.Enter, false),
  )
  assert_true(loading_enter.effect() is @button.None)
}

///|
test "explicit cancellation and bounds replacement retire stale releases" {
  let button = button_test_button()
  let (held, _) = button.handle_input(
    button_test_pointer(true, 40.0, 50.0, true),
  )
  let cancelled = held.cancel_press()
  let (_, stale_up) = cancelled.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(stale_up.effect() is @button.None)

  let (held_again, _) = button.handle_input(
    button_test_pointer(true, 40.0, 50.0, true),
  )
  let moved = held_again
    .with_bounds(button_test_rect(24.0, 32.0, 180.0, 48.0))
    .unwrap()
  let (_, resized_up) = moved.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(!moved.is_pressed())
  assert_true(resized_up.effect() is @button.None)
}

///|
test "removing the element retires an armed pointer sequence" {
  let button = button_test_button()
  let root = @element.ElementNode::new(
    1UL,
    None,
    button_test_rect(0.0, 0.0, 240.0, 120.0),
  )
  let tree = @element.ElementTree::new([root, button.element_node(Some(1UL))]).unwrap()
  let (armed, _) = button.handle_input(
    button_test_pointer(true, 40.0, 50.0, true),
  )
  let removed_tree = tree.without_subtree(button.id()).unwrap()
  assert_true(removed_tree.node(button.id()) is None)
  let removed = armed.cancel_press()
  let (_, late_release) = removed.handle_input(
    button_test_pointer(false, 40.0, 50.0, true),
  )
  assert_true(!removed.is_pressed())
  assert_true(late_release.effect() is @button.None)
}

///|
test "painting retains label text and distinguishes focused and disabled states" {
  let button = button_test_button()
  let normal = button.paint_items(100UL).unwrap()
  assert_eq(normal.length(), 3)
  assert_eq(normal[0].id(), 100UL)
  assert_eq(normal[1].id(), 101UL)
  match normal[2] {
    @scene.TextItem(id=102, text="Save changes", font_size=16.0, ..) => ()
    _ => fail("button label must remain real scene text")
  }

  let focused = button.with_focus(true).paint_items(200UL).unwrap()
  let normal_border = match normal[0] {
    @scene.QuadItem(color~, ..) => color
    _ => fail("normal button border should be a quad")
  }
  let focus_border = match focused[0] {
    @scene.QuadItem(color~, ..) => color
    _ => fail("focused button border should be a quad")
  }
  assert_true(normal_border != focus_border)

  let disabled = button.with_enabled(false).paint_items(300UL).unwrap()
  let normal_fill = match normal[1] {
    @scene.QuadItem(color~, ..) => color
    _ => fail("normal button fill should be a quad")
  }
  let disabled_fill = match disabled[1] {
    @scene.QuadItem(color~, ..) => color
    _ => fail("disabled button fill should be a quad")
  }
  assert_true(normal_fill != disabled_fill)
}

///|
test "button IDs and paint item ranges reject invalid sentinels" {
  assert_true(
    @button.Button::new(
      0UL,
      button_test_rect(20.0, 30.0, 160.0, 40.0),
      "Invalid",
    )
    is Err(@button.InvalidId),
  )
  assert_true(
    @button.Button::new(
      17UL,
      button_test_rect(20.0, 30.0, 20.0, 20.0),
      "Too small",
    )
    is Err(@button.InvalidBounds),
  )
  assert_true(
    button_test_button().paint_items(0UL) is Err(@button.InvalidItemId),
  )
}
