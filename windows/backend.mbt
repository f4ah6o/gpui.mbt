///|
/// Owner-thread Win32 host. All HWND, DXGI and D3D11 objects remain private to
/// the native shim; callers exchange only framework values and snapshots.
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
extern "C" fn native_start(version : Int) -> Int = "gpui_windows_start"

///|
extern "C" fn native_stop(host : Int) -> Int = "gpui_windows_stop"

///|
extern "C" fn native_state(host : Int) -> Int = "gpui_windows_state"

///|
extern "C" fn native_wake(host : Int) -> Int = "gpui_windows_wake"

///|
extern "C" fn native_exit(host : Int) -> Int = "gpui_windows_exit"

///|
#borrow(title)
extern "C" fn native_create(
  host : Int,
  width : Int,
  height : Int,
  title : Bytes,
  length : Int,
) -> Int = "gpui_windows_create"

///|
extern "C" fn native_close(host : Int, window : Int) -> Int = "gpui_windows_close"

///|
extern "C" fn native_destroy(host : Int, window : Int) -> Int = "gpui_windows_destroy"

///|
#borrow(title)
extern "C" fn native_title(
  host : Int,
  window : Int,
  title : Bytes,
  length : Int,
) -> Int = "gpui_windows_title"

///|
extern "C" fn native_size(
  host : Int,
  window : Int,
  width : Int,
  height : Int,
) -> Int = "gpui_windows_size"

///|
#borrow(metrics)
extern "C" fn native_metrics(
  host : Int,
  window : Int,
  metrics : FixedArray[Double],
) -> Int = "gpui_windows_metrics"

///|
extern "C" fn native_dispatch(host : Int, timeout : Int) -> Int = "gpui_windows_dispatch"

///|
#borrow(event)
extern "C" fn native_next(host : Int, event : FixedArray[Double]) -> Int = "gpui_windows_next"

///|
#borrow(data)
extern "C" fn native_present(
  host : Int,
  window : Int,
  data : FixedArray[Double],
  length : Int,
) -> Int = "gpui_windows_present"

///|
#borrow(data, text_bytes)
extern "C" fn native_present_text(
  abi : Int,
  host : Int,
  window : Int,
  data : FixedArray[Double],
  length : Int,
  text_bytes : Bytes,
  text_length : Int,
) -> Int = "gpui_windows_present_text"

///|
extern "C" fn native_recover(host : Int, window : Int) -> Int = "gpui_windows_recover"

///|
extern "C" fn native_cursor(host : Int, cursor : Int) -> Int = "gpui_windows_cursor"

///|
#borrow(output)
extern "C" fn native_clipboard_read(
  host : Int,
  output : Bytes,
  capacity : Int,
) -> Int = "gpui_windows_clipboard_read"

///|
#borrow(text)
extern "C" fn native_clipboard_write(
  host : Int,
  text : Bytes,
  length : Int,
) -> Int = "gpui_windows_clipboard_write"

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
    11 => @diagnostics.ConversionFailed
    _ => @diagnostics.NativeFailure
  }
  @diagnostics.FrameworkError::new(
    code,
    operation,
    backend="windows-d3d11",
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
/// Starts a per-monitor-DPI-aware Win32 UI host. On non-Windows native targets,
/// the package's C stub returns UnsupportedCapability without faking a window.
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
    0 => Some(@platform.Created)
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
                @primitives.KeyPressed(
                  key~,
                  modifiers=mods,
                  repeat=data[7] != 0.0,
                )
              } else {
                @primitives.KeyReleased(key~, modifiers=mods)
              },
            ),
          )
      }
    15 =>
      match key(0, data[6].to_int()) {
        None => None
        Some(key) =>
          Some(
            @platform.Input(
              @primitives.KeyPressed(
                key~,
                modifiers=mods,
                repeat=data[7] != 0.0,
              ),
            ),
          )
      }
    16 =>
      if data[6].is_nan() ||
        data[6].is_inf() ||
        data[6] < 0.0 ||
        data[6] > 1114111.0 {
        None
      } else {
        let scalar = data[6].to_int()
        if scalar.to_double() != data[6] ||
          (scalar >= 0xd800 && scalar <= 0xdfff) {
          None
        } else {
          let text = scalar.unsafe_to_char().to_string()
          Some(@platform.Input(@primitives.TextInput(text~)))
        }
      }
    13 => Some(@platform.Wake)
    14 => Some(@platform.ExitRequested)
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
              buffer[2].to_int64(),
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
                buffer[2].to_int64(),
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
/// Serialize the supported SceneSnapshot v1 quad subset into a borrowed ABI
/// buffer. Clip chains are intersected in logical viewport coordinates.
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
  // Reject unsupported paint variants before writing any frame records. In
  // particular, origin-aware text must never be coerced to the quad layout.
  for item in items {
    match item {
      @scene.TextItem(..) | @scene.TextRunItem(..) =>
        return Err(backend_error(1, "present"))
      @scene.QuadItem(..) => ()
    }
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
      @scene.TextItem(..) | @scene.TextRunItem(..) =>
        return Err(backend_error(1, "present"))
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
priv struct MixedFrame {
  data : FixedArray[Double]
  text_bytes : Bytes
}

///|
/// Windows private mixed-frame ABI v2. It preserves item order, borrows one
/// bounded UTF-8 sidecar, and keeps the legacy 19-double quad ABI unchanged.
fn mixed_frame_data(
  snapshot : @scene.SceneSnapshot,
) -> Result[MixedFrame, @diagnostics.FrameworkError] {
  if snapshot.schema_version() != 1 || snapshot.resources().length() != 0 {
    return Err(backend_error(1, "present"))
  }
  let viewport = snapshot.viewport()
  let items = snapshot.items()
  if items.length() > 100000 {
    return Err(backend_error(8, "present"))
  }
  let data = FixedArray::make(5 + items.length() * 25, 0.0)
  data[0] = viewport.left()
  data[1] = viewport.top()
  data[2] = viewport.size().width()
  data[3] = viewport.size().height()
  data[4] = snapshot.scale()
  let blob : Array[Byte] = []
  let chains = snapshot.clip_chains()
  let mut text_runs = 0
  for index = 0; index < items.length(); index = index + 1 {
    let offset = 5 + index * 25
    match items[index] {
      @scene.TextItem(text~, font_size~, ..)
      | @scene.TextRunItem(text~, font_size~, ..) => {
        text_runs += 1
        if text_runs > @windows_text.max_scene_text_runs {
          return Err(backend_error(8, "present"))
        }
        if font_size > @windows_text.max_scene_font_size_px {
          return Err(backend_error(1, "present"))
        }
        let document = match @text.TextDocument::new(text) {
          Ok(value) => value
          Err(_) => return Err(backend_error(1, "present"))
        }
        let byte_length = match document.utf8_length() {
          Ok(value) => value
          Err(_) => return Err(backend_error(8, "present"))
        }
        if byte_length > @windows_text.max_scene_text_bytes ||
          blob.length() > @windows_text.max_frame_text_bytes - byte_length {
          return Err(backend_error(8, "present"))
        }
        let bytes = @utf8.encode(document.text())
        if bytes.length() != byte_length ||
          blob.length() > @windows_text.max_frame_text_bytes - bytes.length() {
          return Err(backend_error(8, "present"))
        }
        for scalar in text.iter() {
          if scalar.to_int() == 0 ||
            scalar.to_int() == 0x0A ||
            scalar.to_int() == 0x0D ||
            scalar.to_int() == 0x2028 ||
            scalar.to_int() == 0x2029 {
            return Err(backend_error(1, "present"))
          }
        }
        data[offset] = if items[index] is @scene.TextRunItem(..) {
          2.0
        } else {
          1.0
        }
        data[offset + 20] = blob.length().to_double()
        data[offset + 21] = bytes.length().to_double()
        data[offset + 22] = font_size
        if items[index] is @scene.TextRunItem(text_origin~, ..) {
          data[offset + 23] = text_origin.x()
          data[offset + 24] = text_origin.y()
        }
        for byte in bytes {
          blob.push(byte)
        }
      }
      @scene.QuadItem(..) => ()
    }
    match items[index] {
      @scene.QuadItem(bounds~, color~, transform~, opacity~, clip_chain_id~, ..)
      | @scene.TextItem(
        bounds~,
        color~,
        transform~,
        opacity~,
        clip_chain_id~,
        ..
      )
      | @scene.TextRunItem(
        bounds~,
        color~,
        transform~,
        opacity~,
        clip_chain_id~,
        ..
      ) => {
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
        let item_offset = if items[index] is @scene.QuadItem(..) {
          offset + 1
        } else {
          offset + 1
        }
        data[item_offset] = bounds.left()
        data[item_offset + 1] = bounds.top()
        data[item_offset + 2] = bounds.size().width()
        data[item_offset + 3] = bounds.size().height()
        data[item_offset + 4] = color.red().to_double()
        data[item_offset + 5] = color.green().to_double()
        data[item_offset + 6] = color.blue().to_double()
        data[item_offset + 7] = color.alpha().to_double()
        data[item_offset + 8] = transform.a()
        data[item_offset + 9] = transform.b()
        data[item_offset + 10] = transform.c()
        data[item_offset + 11] = transform.d()
        data[item_offset + 12] = transform.tx()
        data[item_offset + 13] = transform.ty()
        data[item_offset + 14] = opacity
        if clip is Some(rect) {
          data[item_offset + 15] = rect.left()
          data[item_offset + 16] = rect.top()
          data[item_offset + 17] = rect.size().width()
          data[item_offset + 18] = rect.size().height()
        }
      }
    }
  }
  Ok({ data, text_bytes: Bytes::from_array(blob), })
}

///|
pub fn Host::present(
  self : Host,
  window : @platform.WindowId,
  snapshot : @scene.SceneSnapshot,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let mut contains_text = false
  for item in snapshot.items() {
    if item is @scene.TextItem(..) || item is @scene.TextRunItem(..) {
      contains_text = true
    }
  }
  if contains_text {
    match mixed_frame_data(snapshot) {
      Err(error) => Err(error)
      Ok(frame) =>
        outcome(
          native_present_text(
            2,
            self.token,
            window.value().to_int(),
            frame.data,
            frame.data.length(),
            frame.text_bytes,
            frame.text_bytes.length(),
          ),
          "present",
        )
    }
  } else {
    match frame_data(snapshot) {
      Err(error) => Err(error)
      Ok(data) =>
        outcome(
          native_present(
            self.token,
            window.value().to_int(),
            data,
            data.length(),
          ),
          "present",
        )
    }
  }
}

///|
pub fn Host::read_clipboard(
  self : Host,
) -> Result[String, @diagnostics.FrameworkError] {
  let empty = b""
  let size = native_clipboard_read(self.token, empty, 0)
  if size < 0 {
    return Err(backend_error(-size, "read_clipboard"))
  }
  if size > 16 * 1024 * 1024 {
    return Err(backend_error(8, "read_clipboard"))
  }
  let zero : Int = 0
  let output = Bytes::makei(size, _ => zero.to_byte())
  let result = native_clipboard_read(self.token, output, size)
  if result < 0 {
    return Err(backend_error(-result, "read_clipboard"))
  }
  if result != size {
    return Err(backend_error(2, "read_clipboard"))
  }
  try @utf8.decode(output) catch {
    _ => Err(backend_error(2, "read_clipboard"))
  } noraise {
    text => Ok(text)
  }
}

///|
pub fn Host::write_clipboard(
  self : Host,
  text : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let bytes = @utf8.encode(text)
  outcome(
    native_clipboard_write(self.token, bytes, bytes.length()),
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
  outcome(native_cursor(self.token, tag), "set_cursor")
}

///|
pub fn Host::require_capability(
  _self : Host,
  capability : @platform.Capability,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match capability {
    @platform.NativeWindow
    | @platform.LogicalViewport
    | @platform.QuadFrames
    | @platform.FrameScheduling
    | @platform.PointerKeyboard
    | @platform.GrayscaleTextFrames
    | @platform.Clipboard
    | @platform.Cursor => Ok(())
    _ => Err(backend_error(1, "require_capability"))
  }
}

///|
fn logical_dimension(
  value : Double,
  operation : String,
) -> Result[Int, @diagnostics.FrameworkError] {
  if value.is_nan() || value.is_inf() || value < 1.0 || value > 16384.0 {
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
pub fn Host::request_close(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(native_close(self.token, window.value().to_int()), "request_close")
}

///|
pub impl @platform.Backend for Host with fn require_capability(self, capability) {
  self.require_capability(capability)
}

///|
pub impl @platform.Backend for Host with fn stop(self) {
  self.stop()
}

///|
pub impl @platform.Backend for Host with fn create_window(
  self,
  title,
  width,
  height,
) {
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
pub impl @platform.Backend for Host with fn set_title(self, window, title) {
  self.set_title(window, title)
}

///|
pub impl @platform.Backend for Host with fn set_size(
  self,
  window,
  width,
  height,
) {
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
pub impl @platform.Backend for Host with fn window_metrics(self, window) {
  self.window_metrics(window)
}

///|
pub impl @platform.Backend for Host with fn next_event(self, timeout_ms? = 16) {
  self.next_event(timeout_ms~)
}

///|
pub impl @platform.Backend for Host with fn present(self, window, snapshot) {
  self.present(window, snapshot)
}

///|
pub impl @platform.Backend for Host with fn request_close(self, window) {
  self.request_close(window)
}

///|
pub impl @platform.Backend for Host with fn destroy_window(self, window) {
  self.destroy_window(window)
}

///|
pub impl @platform.Backend for Host with fn wake(self) {
  self.wake()
}

///|
pub impl @platform.Backend for Host with fn request_exit(self) {
  self.request_exit()
}
