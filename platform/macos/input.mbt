///|
pub fn Host::next_event(
  self : Host,
  timeout_ms? : Int = 16,
) -> Result[@platform.Event?, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match status(call(6, 0, timeout_ms.to_double(), 0.0, b"", 0), "next_event") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let tag = integer(1).to_int()
  if tag == 0 {
    return Ok(None)
  }
  let bits = integer(4).to_int()
  let modifiers = @primitives.Modifiers::new(
    shift=(bits & 1) != 0,
    control=(bits & 2) != 0,
    alt=(bits & 4) != 0,
    meta=(bits & 8) != 0,
  )
  let kind = match tag {
    1 => @platform.Created
    2 => @platform.Resized(width=number(3), height=number(4))
    3 => @platform.Moved(x=number(1), y=number(2))
    4 => @platform.ScaleChanged
    5 => @platform.FocusChanged(true)
    6 => @platform.FocusChanged(false)
    7 | 8 | 9 => {
      let position = match @primitives.Point::new(number(1), number(2)) {
        Ok(value) => value
        Err(_) => return Err(error(@diagnostics.InvalidInput, "next_event"))
      }
      let button = match integer(5).to_int() {
        1 => @primitives.Secondary
        2 => @primitives.Middle
        3 => @primitives.Back
        4 => @primitives.Forward
        _ => @primitives.Primary
      }
      @platform.Input(
        match tag {
          8 => @primitives.PointerButtonPressed(position~, button~, modifiers~)
          9 => @primitives.PointerButtonReleased(position~, button~, modifiers~)
          _ => @primitives.PointerMoved(position~)
        },
      )
    }
    10 | 11 => {
      let text = match read_text() {
        Ok(text) => text
        Err(error) => return Err(error)
      }
      let key = key_from_code(integer(5).to_int(), text)
      @platform.Input(
        if tag == 10 {
          @primitives.KeyPressed(key~, modifiers~, repeat=integer(6) != 0)
        } else {
          @primitives.KeyReleased(key~, modifiers~)
        },
      )
    }
    16 =>
      match
        decode_scroll_event(
          number(1),
          number(2),
          number(3),
          number(4),
          modifiers,
        ) {
        Ok(kind) => kind
        Err(error) => return Err(error)
      }
    12 => @platform.CloseRequested
    13 => @platform.Destroyed
    14 => @platform.Wake
    15 => @platform.ExitRequested
    _ => return Err(error(@diagnostics.NativeFailure, "next_event"))
  }
  Ok(
    Some({
      window: @platform.WindowId::new(integer(2)),
      sequence: integer(3),
      scale: number(0),
      kind,
    }),
  )
}

///|
/// Decodes AppKit scroll-wheel values without imposing a cross-platform unit
/// conversion. Precise deltas are points; non-precise deltas are lines/rows.
fn decode_scroll_event(
  x : Double,
  y : Double,
  delta_x : Double,
  delta_y : Double,
  modifiers : @primitives.Modifiers,
) -> Result[@platform.EventKind, @diagnostics.FrameworkError] {
  let position = match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => return Err(error(@diagnostics.InvalidInput, "next_event"))
  }
  let delta = match @primitives.Point::new(delta_x, delta_y) {
    Ok(value) => value
    Err(_) => return Err(error(@diagnostics.InvalidInput, "next_event"))
  }
  Ok(@platform.Input(@primitives.Scroll(position~, delta~, modifiers~)))
}

///|
fn key_from_code(code : Int, text : String) -> @primitives.Key {
  match code {
    36 | 76 => @primitives.Enter
    53 => @primitives.Escape
    51 => @primitives.Backspace
    117 => @primitives.Delete
    48 => @primitives.Tab
    49 => @primitives.Space
    123 => @primitives.ArrowLeft
    124 => @primitives.ArrowRight
    125 => @primitives.ArrowDown
    126 => @primitives.ArrowUp
    115 => @primitives.Home
    119 => @primitives.End
    116 => @primitives.PageUp
    121 => @primitives.PageDown
    _ => @primitives.Character(text)
  }
}
