///|
/// Single UI owner. All methods must execute on the macOS main thread.
pub struct Host {
  priv marker : Int64
}

///|
pub fn Host::start() -> Result[Host, @diagnostics.FrameworkError] {
  match status(call(1, 0, 0.0, 0.0, b"", 0), "start") {
    Ok(_) => Ok({ marker: integer(9), })
    Err(error) => Err(error)
  }
}

///|
pub fn Host::stop(self : Host) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(call(2, 0, 0.0, 0.0, b"", 0), "stop")
}

///|
pub fn Host::create_window(
  self : Host,
  title : String,
  width : Double,
  height : Double,
) -> Result[@platform.WindowId, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let bytes = @utf8.encode(title)
  match
    status(call(3, 0, width, height, bytes, bytes.length()), "create_window") {
    Ok(_) => Ok(@platform.WindowId::new(integer(0)))
    Err(error) => Err(error)
  }
}

///|
pub fn Host::set_title(
  self : Host,
  window : @platform.WindowId,
  title : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let bytes = @utf8.encode(title)
  status(call(4, window.value(), 0.0, 0.0, bytes, bytes.length()), "set_title")
}

///|
pub fn Host::set_size(
  self : Host,
  window : @platform.WindowId,
  width : Double,
  height : Double,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(call(5, window.value(), width, height, b"", 0), "set_size")
}

///|
pub fn Host::request_close(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(call(7, window.value(), 0.0, 0.0, b"", 0), "request_close")
}

///|
pub fn Host::destroy_window(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(call(8, window.value(), 0.0, 0.0, b"", 0), "destroy_window")
}

///|
pub fn Host::present(
  self : Host,
  window : @platform.WindowId,
  snapshot : @scene.SceneSnapshot,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let bytes = @utf8.encode(snapshot.canonical_json())
  status(call(9, window.value(), 0.0, 0.0, bytes, bytes.length()), "present")
}

///|
pub fn Host::wake(self : Host) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(call(10, 0, 0.0, 0.0, b"", 0), "wake")
}

///|
pub fn Host::request_exit(
  self : Host,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(call(11, 0, 0.0, 0.0, b"", 0), "request_exit")
}

///|
/// Rebuild Metal device, queue and pipeline state, then rebind all live window
/// layers while preserving their logical identities.
pub fn Host::recover_renderer(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(call(16, window.value(), 0.0, 0.0, b"", 0), "recover_renderer")
}

///|
fn error(
  code : @diagnostics.ErrorCode,
  operation : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    code,
    operation,
    subsystem="platform",
    backend="macos-metal",
  )
}

///|
fn status(
  value : Int,
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if value == 0 {
    return Ok(())
  }
  let code = match value {
    1 => @diagnostics.AppNotRunning
    5 => @diagnostics.InvalidInput
    9 => @diagnostics.UnsupportedCapability
    10 => @diagnostics.StaleHandle
    12 => @diagnostics.Busy
    13 => @diagnostics.ResourceExhausted
    14 => @diagnostics.WindowUnavailable
    15 => @diagnostics.SurfaceLost
    16 => @diagnostics.DeviceLost
    17 => @diagnostics.ConversionFailed
    18 => @diagnostics.WrongThread
    19 => @diagnostics.HostStopping
    _ => @diagnostics.NativeFailure
  }
  Err(error(code, operation))
}

///|
fn Host::check(self : Host) -> Result[Unit, @diagnostics.FrameworkError] {
  status(call(0, self.marker, 0.0, 0.0, b"", 0), "host_generation")
}

///|
/// Current logical content size and backing scale, sampled on the UI owner.
pub fn Host::window_metrics(
  self : Host,
  window : @platform.WindowId,
) -> Result[(Double, Double, Double), @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match status(call(15, window.value(), 0.0, 0.0, b"", 0), "window_metrics") {
    Err(error) => Err(error)
    Ok(_) => Ok((number(3), number(4), number(0)))
  }
}
