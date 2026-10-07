///|
pub fn Host::next_event(
  self : Host,
  timeout_ms? : Int = 16,
) -> Result[@platform.Event?, @diagnostics.FrameworkError] {
  if timeout_ms < 0 || timeout_ms > 250 {
    return Err(error(@diagnostics.InvalidInput, "next_event"))
  }
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match status(call(6, 0, timeout_ms.to_double(), 0.0, b"", 0), "next_event") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  decode_platform_event()
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
