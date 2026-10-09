///|
fn button_pbt_rect() -> @primitives.Rect {
  match @primitives.Rect::new(16.0, 24.0, 160.0, 40.0) {
    Ok(value) => value
    Err(_) => abort("valid property bounds rejected")
  }
}

///|
fn button_pbt_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid property point rejected")
  }
}

///|
fn button_pbt_pointer(
  pressed : Bool,
  x : Double,
  y : Double,
) -> @primitives.InputEvent {
  let point = button_pbt_point(x, y)
  if pressed {
    @primitives.PointerButtonPressed(
      position=point,
      button=@primitives.Primary,
      modifiers=@primitives.Modifiers::none(),
    )
  } else {
    @primitives.PointerButtonReleased(
      position=point,
      button=@primitives.Primary,
      modifiers=@primitives.Modifiers::none(),
    )
  }
}

///|
fn button_pbt_key_down(
  key : @primitives.Key,
  repeat : Bool,
) -> @primitives.InputEvent {
  @primitives.KeyPressed(key~, modifiers=@primitives.Modifiers::none(), repeat~)
}

///|
fn button_pbt_key_up(key : @primitives.Key) -> @primitives.InputEvent {
  @primitives.KeyReleased(key~, modifiers=@primitives.Modifiers::none())
}

///|
// Stable suite ID: controls.button.accepted-gesture.once
test "property accepted activation gestures fire once across repeated input" {
  @quickcheck.check(
    (selector : Int) => {
      let repeats = if selector % 17 < 0 {
        selector % 17 + 17
      } else {
        selector % 17
      }
      let mut count = 0
      let mut button = @button.Button::new(9UL, button_pbt_rect(), "Run")
        .unwrap()
        .with_focus(true)

      let (enter_held, enter_down) = button.handle_input(
        button_pbt_key_down(@primitives.Enter, false),
      )
      button = enter_held
      if enter_down.effect() is @button.Activated {
        count += 1
      }
      for _ in 0..<repeats {
        let (next, repeated) = button.handle_input(
          button_pbt_key_down(@primitives.Enter, true),
        )
        button = next
        if repeated.effect() is @button.Activated {
          count += 1
        }
      }
      let (after_enter, enter_up) = button.handle_input(
        button_pbt_key_up(@primitives.Enter),
      )
      button = after_enter
      if enter_up.effect() is @button.Activated {
        count += 1
      }

      let (space_held, space_down) = button.handle_input(
        button_pbt_key_down(@primitives.Space, false),
      )
      button = space_held
      if space_down.effect() is @button.Activated {
        count += 1
      }
      for _ in 0..<repeats {
        let (next, repeated) = button.handle_input(
          button_pbt_key_down(@primitives.Space, true),
        )
        button = next
        if repeated.effect() is @button.Activated {
          count += 1
        }
      }
      let (after_space, space_up) = button.handle_input(
        button_pbt_key_up(@primitives.Space),
      )
      button = after_space
      if space_up.effect() is @button.Activated {
        count += 1
      }

      let (pointer_held, pointer_down) = button.handle_input(
        button_pbt_pointer(true, 40.0, 40.0),
      )
      button = pointer_held
      if pointer_down.effect() is @button.Activated {
        count += 1
      }
      for _ in 0..<repeats {
        let (next, repeated) = button.handle_input(
          button_pbt_pointer(true, 40.0, 40.0),
        )
        button = next
        if repeated.effect() is @button.Activated {
          count += 1
        }
      }
      let (after_pointer, pointer_up) = button.handle_input(
        button_pbt_pointer(false, 40.0, 40.0),
      )
      button = after_pointer
      if pointer_up.effect() is @button.Activated {
        count += 1
      }

      count == 3 && !button.is_pressed()
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=2718184410097731559,
  )
}
