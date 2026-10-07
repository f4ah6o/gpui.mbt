///|
fn read_text() -> Result[String, @diagnostics.FrameworkError] {
  let length = integer(8).to_int()
  if length < 0 || length > 16 * 1024 * 1024 {
    return Err(error(@diagnostics.ResourceExhausted, "read_text"))
  }
  let bytes = Bytes::makei(length, i => integer(100 + i).to_int().to_byte())
  try @utf8.decode(bytes) catch {
    _ => Err(error(@diagnostics.ConversionFailed, "read_text"))
  } noraise {
    text => Ok(text)
  }
}

///|
pub fn Host::read_clipboard(
  self : Host,
) -> Result[String, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match status(call(13, 0, 0.0, 0.0, b"", 0), "read_clipboard") {
    Err(error) => Err(error)
    Ok(_) => read_text()
  }
}

///|
pub fn Host::write_clipboard(
  self : Host,
  text : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let bytes = @utf8.encode(text)
  status(call(14, 0, 0.0, 0.0, bytes, bytes.length()), "write_clipboard")
}

///|
pub fn Host::set_cursor(
  self : Host,
  cursor : @platform.Cursor,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let tag = match cursor {
    @platform.Arrow => 0
    @platform.PointingHand => 1
    @platform.Text => 2
  }
  status(call(12, 0, tag.to_double(), 0.0, b"", 0), "set_cursor")
}

///|
pub fn Host::require_capability(
  self : Host,
  capability : @platform.Capability,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match capability {
    @platform.NativeWindow
    | @platform.QuadFrames
    | @platform.PointerKeyboard
    | @platform.Clipboard
    | @platform.Cursor => Ok(())
    @platform.GrayscaleTextFrames =>
      status(call(30, 0, 0.0, 0.0, b"", 0), "require_capability")
    _ => Err(error(@diagnostics.UnsupportedCapability, "require_capability"))
  }
}
