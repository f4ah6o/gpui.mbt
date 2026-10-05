///|
/// Explicitly stopped, UI-owner-thread Ubuntu/Wayland backend. One host and
/// one live window are supported. Native tokens remain private.
pub struct Host {
  priv token : Int
  priv mut stopped : Bool
}

///|
pub(all) enum HostState {
  Running
  Quiescing
  Stopped
} derive(Eq)

///|
pub extend HostState with Eq::{not_equal, equal}

///|
extern "C" fn native_start(version : Int) -> Int = "gpui_start"

///|
extern "C" fn native_stop(host : Int) -> Int = "gpui_stop"

///|
extern "C" fn native_state(host : Int) -> Int = "gpui_state"

///|
extern "C" fn native_wake(host : Int) -> Int = "gpui_wake"

///|
extern "C" fn native_exit(host : Int) -> Int = "gpui_exit"

///|
#borrow(title)
extern "C" fn native_create(
  host : Int,
  width : Int,
  height : Int,
  title : Bytes,
  length : Int,
) -> Int = "gpui_create"

///|
extern "C" fn native_close(host : Int, window : Int) -> Int = "gpui_close"

///|
extern "C" fn native_destroy(host : Int, window : Int) -> Int = "gpui_destroy"

///|
#borrow(title)
extern "C" fn native_title(
  host : Int,
  window : Int,
  title : Bytes,
  length : Int,
) -> Int = "gpui_title"

///|
extern "C" fn native_size(
  host : Int,
  window : Int,
  width : Int,
  height : Int,
) -> Int = "gpui_size"

///|
#borrow(metrics)
extern "C" fn native_metrics(
  host : Int,
  window : Int,
  metrics : FixedArray[Double],
) -> Int = "gpui_metrics"

///|
extern "C" fn native_dispatch(host : Int, timeout : Int) -> Int = "gpui_dispatch"

///|
#borrow(event)
extern "C" fn native_next(host : Int, event : FixedArray[Double]) -> Int = "gpui_next"

///|
#borrow(data)
extern "C" fn native_present(
  host : Int,
  window : Int,
  data : FixedArray[Double],
  length : Int,
) -> Int = "gpui_present"

///|
extern "C" fn native_recover(host : Int, window : Int) -> Int = "gpui_recover"

///|
#borrow(text)
extern "C" fn native_write_clipboard(
  host : Int,
  text : Bytes,
  length : Int,
) -> Int = "gpui_write_clipboard"

///|
extern "C" fn native_read_clipboard(host : Int) -> Int = "gpui_read_clipboard"

///|
extern "C" fn native_clipboard_length(host : Int) -> Int = "gpui_clipboard_length"

///|
#borrow(bytes)
extern "C" fn native_clipboard_copy(
  host : Int,
  bytes : Bytes,
  capacity : Int,
) -> Int = "gpui_clipboard_copy"

///|
extern "C" fn native_set_cursor(host : Int, cursor : Int) -> Int = "gpui_set_cursor"

///|
extern "C" fn native_capability(host : Int, capability : Int) -> Int = "gpui_capability"

///|
fn backend_error(
  status : Int,
  operation : String,
) -> @diagnostics.FrameworkError {
  let code = match status {
    1 => @diagnostics.UnsupportedCapability
    3 => @diagnostics.InvalidInput
    4 => @diagnostics.StaleHandle
    5 => @diagnostics.Busy
    6 => @diagnostics.HostStopping
    7 => @diagnostics.WrongThread
    8 => @diagnostics.ResourceExhausted
    9 => @diagnostics.SurfaceLost
    10 => @diagnostics.DeviceLost
    _ => @diagnostics.NativeFailure
  }
  @diagnostics.FrameworkError::new(
    code,
    operation,
    backend="ubuntu-wayland",
    subsystem="native",
  )
}

///|
fn outcome(
  status : Int,
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if status == 0 {
    Ok(())
  } else {
    Err(backend_error(status, operation))
  }
}

///|
/// Requires WAYLAND_DISPLAY and a Wayland session (XDG_SESSION_TYPE, when set,
/// must be wayland). Missing protocols/session return UnsupportedCapability.
pub fn Host::start() -> Result[Host, @diagnostics.FrameworkError] {
  let token = native_start(1)
  if token > 0 {
    Ok({ token, stopped: false, })
  } else {
    Err(backend_error(-token, "start"))
  }
}

///|
pub fn Host::state(self : Host) -> HostState {
  if self.stopped {
    Stopped
  } else {
    match native_state(self.token) {
      0 => Running
      1 => Quiescing
      _ => Stopped
    }
  }
}

///|
pub fn Host::wake(self : Host) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(native_wake(self.token), "wake")
}

///|
pub fn Host::request_exit(
  self : Host,
) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(native_exit(self.token), "request_exit")
}

///|
pub fn Host::stop(self : Host) -> Result[Unit, @diagnostics.FrameworkError] {
  if self.stopped {
    Ok(())
  } else {
    match outcome(native_stop(self.token), "stop") {
      Ok(_) => {
        self.stopped = true
        Ok(())
      }
      Err(error) => Err(error)
    }
  }
}

///|
pub fn Host::create_window(
  self : Host,
  width : Int,
  height : Int,
  title : String,
) -> Result[@platform.WindowId, @diagnostics.FrameworkError] {
  let bytes = @utf8.encode(title)
  let id = native_create(self.token, width, height, bytes, bytes.length())
  if id > 0 {
    Ok(@platform.WindowId::new(Int64::from_int(id)))
  } else {
    Err(backend_error(-id, "create_window"))
  }
}

///|
pub fn Host::destroy_window(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(native_destroy(self.token, window.value().to_int()), "destroy_window")
}

///|
pub fn Host::set_title(
  self : Host,
  window : @platform.WindowId,
  title : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let bytes = @utf8.encode(title)
  outcome(
    native_title(self.token, window.value().to_int(), bytes, bytes.length()),
    "set_title",
  )
}

///|
pub fn Host::set_size(
  self : Host,
  window : @platform.WindowId,
  width : Int,
  height : Int,
) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(
    native_size(self.token, window.value().to_int(), width, height),
    "set_size",
  )
}

///|
pub fn Host::window_metrics(
  self : Host,
  window : @platform.WindowId,
) -> Result[(Double, Double, Double), @diagnostics.FrameworkError] {
  let metrics = FixedArray::make(3, 0.0)
  match
    outcome(
      native_metrics(self.token, window.value().to_int(), metrics),
      "window_metrics",
    ) {
    Err(error) => Err(error)
    Ok(_) => Ok((metrics[0], metrics[1], metrics[2]))
  }
}

///|
/// Explicit renderer recreation. Automatic timed recovery remains a later gate.
pub fn Host::recover_renderer(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(
    native_recover(self.token, window.value().to_int()),
    "recover_renderer",
  )
}

///|
fn modifiers(bits : Int) -> @primitives.Modifiers {
  @primitives.Modifiers::new(
    shift=(bits & 1) != 0,
    control=(bits & 2) != 0,
    alt=(bits & 4) != 0,
    meta=(bits & 8) != 0,
  )
}

///|
fn key(symbol : Int, scalar : Int) -> @primitives.Key? {
  match symbol {
    0xff0d => Some(@primitives.Enter)
    0xff1b => Some(@primitives.Escape)
    0xff08 => Some(@primitives.Backspace)
    0xffff => Some(@primitives.Delete)
    0xff09 | 0xfe20 => Some(@primitives.Tab)
    0x20 => Some(@primitives.Space)
    0xff51 => Some(@primitives.ArrowLeft)
    0xff52 => Some(@primitives.ArrowUp)
    0xff53 => Some(@primitives.ArrowRight)
    0xff54 => Some(@primitives.ArrowDown)
    0xff50 => Some(@primitives.Home)
    0xff57 => Some(@primitives.End)
    0xff55 => Some(@primitives.PageUp)
    0xff56 => Some(@primitives.PageDown)
    _ =>
      if scalar >= 32 &&
        scalar <= 0x10ffff &&
        !(scalar >= 0xd800 && scalar <= 0xdfff) {
        Some(@primitives.Character(scalar.unsafe_to_char().to_string()))
      } else {
        None
      }
  }
}

///|
fn decode_event(data : FixedArray[Double]) -> @platform.EventKind? {
  let detail = data[8].to_int()
  let mods = modifiers(data[9].to_int())
  match data[0].to_int() {
    1 => Some(@platform.Resized(width=data[4], height=data[5]))
    2 => Some(@platform.ScaleChanged)
    3 => Some(@platform.CloseRequested)
    4 => Some(@platform.Destroyed)
    5 => Some(@platform.FrameCompleted)
    6 => Some(@platform.FocusChanged(detail != 0))
    7 | 8 | 9 =>
      match @primitives.Point::new(data[6], data[7]) {
        Err(_) => None
        Ok(position) => {
          let button = match detail {
            0 => @primitives.Primary
            1 => @primitives.Secondary
            2 => @primitives.Middle
            3 => @primitives.Back
            _ => @primitives.Forward
          }
          let input = match data[0].to_int() {
            7 => @primitives.PointerMoved(position~)
            8 =>
              @primitives.PointerButtonPressed(
                position~,
                button~,
                modifiers=mods,
              )
            _ =>
              @primitives.PointerButtonReleased(
                position~,
                button~,
                modifiers=mods,
              )
          }
          Some(@platform.Input(input))
        }
      }
    10 => {
      let delta = if detail == 0 {
        @primitives.Point::new(0.0, data[4])
      } else {
        @primitives.Point::new(data[4], 0.0)
      }
      match (@primitives.Point::new(data[6], data[7]), delta) {
        (Ok(position), Ok(delta)) =>
          Some(
            @platform.Input(
              @primitives.Scroll(position~, delta~, modifiers=mods),
            ),
          )
        _ => None
      }
    }
    11 | 12 =>
      match key(detail, data[6].to_int()) {
        None => None
        Some(key) =>
          Some(
            @platform.Input(
              if data[0] == 11.0 {
                @primitives.KeyPressed(key~, modifiers=mods, repeat=false)
              } else {
                @primitives.KeyReleased(key~, modifiers=mods)
              },
            ),
          )
      }
    _ => None
  }
}

///|
pub fn Host::next_event(
  self : Host,
  timeout_ms? : Int = 16,
) -> Result[@platform.Event?, @diagnostics.FrameworkError] {
  let buffer = FixedArray::make(10, 0.0)
  let mut status = native_next(self.token, buffer)
  if status == 0 {
    match outcome(native_dispatch(self.token, timeout_ms), "next_event") {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    status = native_next(self.token, buffer)
  }
  if status < 0 {
    Err(backend_error(-status, "next_event"))
  } else if status == 0 {
    Ok(None)
  } else {
    match decode_event(buffer) {
      None => Err(backend_error(2, "next_event"))
      Some(kind) =>
        Ok(
          Some(
            @platform.Event::new(
              @platform.WindowId::new(Int64::from_int(buffer[1].to_int())),
              Int64::from_int(buffer[2].to_int()),
              buffer[3],
              kind,
            ),
          ),
        )
    }
  }
}

///|
pub fn Host::dispatch(
  self : Host,
  timeout_ms : Int,
) -> Result[Array[@platform.Event], @diagnostics.FrameworkError] {
  match outcome(native_dispatch(self.token, timeout_ms), "dispatch") {
    Err(error) => Err(error)
    Ok(_) => {
      let events : Array[@platform.Event] = []
      let buffer = FixedArray::make(10, 0.0)
      let mut status = native_next(self.token, buffer)
      while status == 1 {
        match decode_event(buffer) {
          None => ()
          Some(kind) =>
            events.push(
              @platform.Event::new(
                @platform.WindowId::new(Int64::from_int(buffer[1].to_int())),
                Int64::from_int(buffer[2].to_int()),
                buffer[3],
                kind,
              ),
            )
        }
        status = native_next(self.token, buffer)
      }
      if status < 0 {
        Err(backend_error(-status, "dispatch"))
      } else {
        Ok(events)
      }
    }
  }
}

///|
/// Flatten only the supported immutable v1 subset; intersect clips in logical
/// viewport coordinates. No MoonBit buffer is retained by native code.
fn frame_data(
  snapshot : @scene.SceneSnapshot,
) -> Result[FixedArray[Double], @diagnostics.FrameworkError] {
  if snapshot.schema_version() != 1 || snapshot.resources().length() != 0 {
    return Err(backend_error(1, "present"))
  }
  let viewport = snapshot.viewport()
  let items = snapshot.items()
  if items.length() > 100000 {
    return Err(backend_error(8, "present"))
  }
  let data = FixedArray::make(5 + items.length() * 19, 0.0)
  data[0] = viewport.left()
  data[1] = viewport.top()
  data[2] = viewport.size().width()
  data[3] = viewport.size().height()
  data[4] = snapshot.scale()
  let chains = snapshot.clip_chains()
  for index = 0; index < items.length(); index = index + 1 {
    match items[index] {
      @scene.TextItem(..) => return Err(backend_error(1, "present"))
      @scene.QuadItem(bounds~, color~, transform~, opacity~, clip_chain_id~, ..) => {
        let mut clip = Some(viewport)
        if clip_chain_id is Some(id) {
          for chain in chains {
            if chain.id() == id {
              for rect in chain.rects() {
                clip = match clip {
                  Some(current) => current.intersection(rect)
                  None => None
                }
              }
            }
          }
        }
        let offset = 5 + index * 19
        data[offset] = bounds.left()
        data[offset + 1] = bounds.top()
        data[offset + 2] = bounds.size().width()
        data[offset + 3] = bounds.size().height()
        data[offset + 4] = color.red().to_double()
        data[offset + 5] = color.green().to_double()
        data[offset + 6] = color.blue().to_double()
        data[offset + 7] = color.alpha().to_double()
        data[offset + 8] = transform.a()
        data[offset + 9] = transform.b()
        data[offset + 10] = transform.c()
        data[offset + 11] = transform.d()
        data[offset + 12] = transform.tx()
        data[offset + 13] = transform.ty()
        data[offset + 14] = opacity
        if clip is Some(rect) {
          data[offset + 15] = rect.left()
          data[offset + 16] = rect.top()
          data[offset + 17] = rect.size().width()
          data[offset + 18] = rect.size().height()
        }
      }
    }
  }
  Ok(data)
}

///|
pub fn Host::present(
  self : Host,
  window : @platform.WindowId,
  snapshot : @scene.SceneSnapshot,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match frame_data(snapshot) {
    Err(error) => Err(error)
    Ok(data) =>
      outcome(
        native_present(self.token, window.value().to_int(), data, data.length()),
        "present",
      )
  }
}

///|
pub fn Host::require_capability(
  self : Host,
  capability : @platform.Capability,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match capability {
    @platform.NativeWindow
    | @platform.QuadFrames
    | @platform.PointerKeyboard
    | @platform.RendererRecovery => Ok(())
    @platform.Clipboard =>
      outcome(native_capability(self.token, 1), "require_capability")
    @platform.Cursor =>
      outcome(native_capability(self.token, 2), "require_capability")
    _ => Err(backend_error(1, "require_capability"))
  }
}

///|
/// Read the active UTF-8 selection. The Wayland offer is consumed through a
/// bounded pipe transfer on the owner thread; no process-local cache is used.
pub fn Host::read_clipboard(
  self : Host,
) -> Result[String, @diagnostics.FrameworkError] {
  match outcome(native_read_clipboard(self.token), "read_clipboard") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let length = native_clipboard_length(self.token)
  if length < 0 {
    return Err(backend_error(-length, "read_clipboard"))
  }
  if length > 16 * 1024 * 1024 {
    return Err(backend_error(8, "read_clipboard"))
  }
  let bytes = Bytes::makei(length, _ => (0).to_byte())
  match
    outcome(native_clipboard_copy(self.token, bytes, length), "read_clipboard") {
    Err(error) => Err(error)
    Ok(_) =>
      try @utf8.decode(bytes) catch {
        _ => Err(backend_error(2, "read_clipboard"))
      } noraise {
        text => Ok(text)
      }
  }
}

///|
pub fn Host::write_clipboard(
  self : Host,
  text : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let bytes = @utf8.encode(text)
  outcome(
    native_write_clipboard(self.token, bytes, bytes.length()),
    "write_clipboard",
  )
}

///|
pub fn Host::set_cursor(
  self : Host,
  cursor : @platform.Cursor,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let tag = match cursor {
    @platform.Arrow => 0
    @platform.PointingHand => 1
    @platform.Text => 2
  }
  outcome(native_set_cursor(self.token, tag), "set_cursor")
}

///|
pub fn Host::set_candidate_rect(
  _self : Host,
  _window : @platform.WindowId,
  _rect : @primitives.Rect,
) -> Result[Unit, @diagnostics.FrameworkError] {
  Err(backend_error(1, "set_candidate_rect"))
}

///|
fn logical_dimension(
  value : Double,
  operation : String,
) -> Result[Int, @diagnostics.FrameworkError] {
  if value != value || value < 1.0 || value > 16384.0 {
    return Err(backend_error(3, operation))
  }
  let integer = value.to_int()
  if integer.to_double() != value {
    Err(backend_error(3, operation))
  } else {
    Ok(integer)
  }
}

///|
pub impl @platform.Backend for Host with fn require_capability(
  self,
  capability : @platform.Capability,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.require_capability(capability)
}

///|
pub impl @platform.Backend for Host with fn stop(self) -> Result[
  Unit,
  @diagnostics.FrameworkError,
] {
  self.stop()
}

///|
pub impl @platform.Backend for Host with fn create_window(
  self,
  title : String,
  width : Double,
  height : Double,
) -> Result[@platform.WindowId, @diagnostics.FrameworkError] {
  let width = match logical_dimension(width, "create_window") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let height = match logical_dimension(height, "create_window") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.create_window(width, height, title)
}

///|
pub impl @platform.Backend for Host with fn set_title(
  self,
  window : @platform.WindowId,
  title : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.set_title(window, title)
}

///|
pub impl @platform.Backend for Host with fn set_size(
  self,
  window : @platform.WindowId,
  width : Double,
  height : Double,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let width = match logical_dimension(width, "set_size") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let height = match logical_dimension(height, "set_size") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.set_size(window, width, height)
}

///|
pub impl @platform.Backend for Host with fn window_metrics(
  self,
  window : @platform.WindowId,
) -> Result[(Double, Double, Double), @diagnostics.FrameworkError] {
  self.window_metrics(window)
}

///|
pub impl @platform.Backend for Host with fn next_event(
  self,
  timeout_ms? : Int = 16,
) -> Result[@platform.Event?, @diagnostics.FrameworkError] {
  self.next_event(timeout_ms~)
}

///|
pub impl @platform.Backend for Host with fn present(
  self,
  window : @platform.WindowId,
  snapshot : @scene.SceneSnapshot,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.present(window, snapshot)
}

///|
pub impl @platform.Backend for Host with fn request_close(
  self,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.request_close(window)
}

///|
pub impl @platform.Backend for Host with fn destroy_window(
  self,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.destroy_window(window)
}

///|
pub impl @platform.Backend for Host with fn wake(self) -> Result[
  Unit,
  @diagnostics.FrameworkError,
] {
  self.wake()
}

///|
pub impl @platform.Backend for Host with fn request_exit(self) -> Result[
  Unit,
  @diagnostics.FrameworkError,
] {
  self.request_exit()
}

///|
/// Request application close policy; this does not destroy the native window.
pub fn Host::request_close(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(native_close(self.token, window.value().to_int()), "request_close")
}
