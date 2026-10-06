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
#borrow(event, text)
extern "C" fn native_next_v2(
  abi : Int,
  host : Int,
  event : FixedArray[Double],
  event_capacity : Int,
  text : Bytes,
  text_capacity : Int,
) -> Int = "gpui_next_v2"

///|
extern "C" fn native_direct_keyboard_text_mode(
  host : Int,
  window : Int,
  enabled : Int,
) -> Int = "gpui_direct_keyboard_text_mode"

///|
extern "C" fn native_direct_keyboard_text_epoch(
  host : Int,
  window : Int,
) -> Int = "gpui_direct_keyboard_text_epoch"

///|
extern "C" fn native_direct_keyboard_text_active(host : Int) -> Int = "gpui_direct_keyboard_text_active"

///|
#borrow(data)
extern "C" fn native_present(
  host : Int,
  window : Int,
  data : FixedArray[Double],
  length : Int,
) -> Int = "gpui_present"

///|
#borrow(data, text)
extern "C" fn native_present_mixed(
  abi : Int,
  host : Int,
  window : Int,
  data : FixedArray[Double],
  length : Int,
  text : Bytes,
  text_length : Int,
) -> Int = "gpui_present_v2"

///|
#borrow(data, text)
extern "C" fn native_present_origin(
  abi : Int,
  host : Int,
  window : Int,
  data : FixedArray[Double],
  length : Int,
  text : Bytes,
  text_length : Int,
) -> Int = "gpui_present_v3"

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
                @primitives.KeyPressed(
                  key~,
                  modifiers=mods,
                  repeat=data[7] == 1.0,
                )
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
const DIRECT_TEXT_ABI : Int = 2

///|
const DIRECT_TEXT_MAX_BYTES : Int = 128

///|
fn native_text_decode_error(
  code : @diagnostics.ErrorCode,
  operation : String,
  message : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    code,
    operation,
    backend="ubuntu-wayland",
    subsystem="native",
    message~,
  )
}

///|
fn exact_i32(value : Double) -> Bool {
  !value.is_nan() &&
  !value.is_inf() &&
  value >= -2147483648.0 &&
  value <= 2147483647.0 &&
  value.to_int().to_double() == value
}

///|
/// Strictly copies and decodes only the bytes reported by a native text event.
/// The native array is borrowed storage and is never exposed to callers.
fn decode_direct_text_event(
  data : FixedArray[Double],
  text : Bytes,
  operation : String,
) -> Result[@platform.EventKind, @diagnostics.FrameworkError] {
  if !exact_i32(data[0]) || data[0] != 13.0 {
    return Err(
      native_text_decode_error(
        @diagnostics.InvalidInput,
        operation,
        "invalid direct text event tag",
      ),
    )
  }
  let length_value = data[8]
  if length_value.is_nan() ||
    length_value.is_inf() ||
    length_value < 1.0 ||
    length_value > DIRECT_TEXT_MAX_BYTES.to_double() ||
    !exact_i32(length_value) {
    return Err(
      native_text_decode_error(
        @diagnostics.InvalidInput,
        operation,
        "invalid direct text byte length",
      ),
    )
  }
  let length = length_value.to_int()
  if text.length() < length {
    return Err(
      native_text_decode_error(
        @diagnostics.InvalidInput,
        operation,
        "direct text buffer is shorter than its reported length",
      ),
    )
  }
  if !exact_i32(data[1]) ||
    data[1] < 1.0 ||
    !exact_i32(data[2]) ||
    data[2] < 1.0 ||
    !exact_i32(data[9]) ||
    data[9] < 0.0 ||
    data[9] > 15.0 ||
    data[3].is_nan() ||
    data[3].is_inf() ||
    data[3] <= 0.0 ||
    data[6] != 0.0 ||
    data[7] != 0.0 {
    return Err(
      native_text_decode_error(
        @diagnostics.InvalidInput,
        operation,
        "invalid direct text event fields",
      ),
    )
  }
  let exact_bytes = Bytes::makei(length, index => text[index])
  try @utf8.decode(exact_bytes) catch {
    _ =>
      Err(
        native_text_decode_error(
          @diagnostics.ConversionFailed,
          operation,
          "direct text event is not valid UTF-8",
        ),
      )
  } noraise {
    value => Ok(@platform.Input(@primitives.TextInput(text=value)))
  }
}

///|
/// V2 preserves legacy records and validates the key repeat flag. Malformed text records
/// are errors rather than silently disappearing from incremental or batch IO.
fn decode_v2_event(
  data : FixedArray[Double],
  text : Bytes,
  operation : String,
) -> Result[@platform.EventKind?, @diagnostics.FrameworkError] {
  if !exact_i32(data[0]) {
    return Err(
      native_text_decode_error(
        @diagnostics.InvalidInput,
        operation,
        "event tag is not a finite integer",
      ),
    )
  }
  if (data[0] == 11.0 && data[7] != 0.0 && data[7] != 1.0) ||
    (data[0] == 12.0 && data[7] != 0.0) {
    return Err(
      native_text_decode_error(
        @diagnostics.InvalidInput,
        operation,
        "invalid key repeat flag",
      ),
    )
  }
  if data[0] == 13.0 {
    match decode_direct_text_event(data, text, operation) {
      Err(error) => Err(error)
      Ok(kind) => Ok(Some(kind))
    }
  } else if data[0] == 11.0 || data[0] == 12.0 {
    // Modifier/function keysyms have no portable Key value. Only a valid
    // native key record may be ignored; malformed records still fail closed.
    if !exact_i32(data[1]) ||
      data[1] < 1.0 ||
      !exact_i32(data[2]) ||
      data[2] < 1.0 ||
      data[3].is_nan() ||
      data[3].is_inf() ||
      data[3] <= 0.0 ||
      !exact_i32(data[6]) ||
      data[6] < 0.0 ||
      data[6] > 0x10ffff ||
      (data[6] >= 0xd800 && data[6] <= 0xdfff) ||
      !exact_i32(data[8]) ||
      data[8] < 0.0 ||
      data[8] > 0x1fffffff ||
      !exact_i32(data[9]) ||
      data[9] < 0.0 ||
      data[9] > 15.0 {
      return Err(
        native_text_decode_error(
          @diagnostics.InvalidInput,
          operation,
          "invalid native key event fields",
        ),
      )
    }
    Ok(decode_event(data))
  } else {
    match decode_event(data) {
      Some(kind) => Ok(Some(kind))
      None =>
        Err(
          native_text_decode_error(
            @diagnostics.InvalidInput,
            operation,
            "invalid or unknown native event record",
          ),
        )
    }
  }
}

///|
fn make_event(
  buffer : FixedArray[Double],
  kind : @platform.EventKind,
) -> @platform.Event {
  @platform.Event::new(
    @platform.WindowId::new(Int64::from_int(buffer[1].to_int())),
    Int64::from_int(buffer[2].to_int()),
    buffer[3],
    kind,
  )
}

///|
fn active_direct_text_dispatch_gate(
  active : Int,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if active < 0 {
    Err(backend_error(-active, "dispatch"))
  } else if active == 1 {
    Err(backend_error(1, "dispatch"))
  } else if active == 0 {
    Ok(())
  } else {
    Err(backend_error(3, "dispatch"))
  }
}

///|
fn direct_text_capability_outcome(
  status : Int,
) -> Result[Unit, @diagnostics.FrameworkError] {
  outcome(status, "require_capability")
}

///|
fn next_event_from_native(
  read : (FixedArray[Double], FixedArray[Byte]) -> Int,
  dispatch : (Int) -> Int,
  timeout_ms : Int,
) -> Result[@platform.Event?, @diagnostics.FrameworkError] {
  let buffer = FixedArray::make(10, 0.0)
  let text_buffer = FixedArray::make(DIRECT_TEXT_MAX_BYTES, (0).to_byte())
  let text = text_buffer.unsafe_reinterpret_as_bytes()
  let mut dispatched = false
  while true {
    let status = read(buffer, text_buffer)
    if status < 0 {
      return Err(backend_error(-status, "next_event"))
    } else if status == 0 {
      if dispatched {
        return Ok(None)
      }
      // One native dispatch budget per call, even after ignored key records.
      dispatched = true
      match outcome(dispatch(timeout_ms), "next_event") {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    } else if status != 1 {
      return Err(backend_error(3, "next_event"))
    } else {
      match decode_v2_event(buffer, text, "next_event") {
        Err(error) => return Err(error)
        Ok(None) => continue
        Ok(Some(kind)) => return Ok(Some(make_event(buffer, kind)))
      }
    }
  } nobreak {
    Ok(None)
  }
}

///|
pub fn Host::next_event(
  self : Host,
  timeout_ms? : Int = 16,
) -> Result[@platform.Event?, @diagnostics.FrameworkError] {
  next_event_from_native(
    (buffer, text) => {
      native_next_v2(
        DIRECT_TEXT_ABI,
        self.token,
        buffer,
        buffer.length(),
        text.unsafe_reinterpret_as_bytes(),
        text.length(),
      )
    },
    timeout => native_dispatch(self.token, timeout),
    timeout_ms,
  )
}

///|
pub fn Host::dispatch(
  self : Host,
  timeout_ms : Int,
) -> Result[Array[@platform.Event], @diagnostics.FrameworkError] {
  match
    active_direct_text_dispatch_gate(
      native_direct_keyboard_text_active(self.token),
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match outcome(native_dispatch(self.token, timeout_ms), "dispatch") {
    Err(error) => Err(error)
    Ok(_) => {
      let events : Array[@platform.Event] = []
      let buffer = FixedArray::make(10, 0.0)
      let text = Bytes::makei(DIRECT_TEXT_MAX_BYTES, _ => (0).to_byte())
      let mut status = native_next_v2(
        DIRECT_TEXT_ABI,
        self.token,
        buffer,
        buffer.length(),
        text,
        text.length(),
      )
      while status == 1 {
        match decode_v2_event(buffer, text, "dispatch") {
          Err(error) => return Err(error)
          Ok(None) => ()
          Ok(Some(kind)) => events.push(make_event(buffer, kind))
        }
        status = native_next_v2(
          DIRECT_TEXT_ABI,
          self.token,
          buffer,
          buffer.length(),
          text,
          text.length(),
        )
      }
      if status < 0 {
        Err(backend_error(-status, "dispatch"))
      } else if status != 0 {
        Err(backend_error(3, "dispatch"))
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
  abi : Int
  data : FixedArray[Double]
  text : Bytes
}

///|
/// Private v2 records preserve ordered items and separately borrow one UTF-8
/// blob. Local text clipping is implemented by the native raster path.
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
  let mut has_origin = false
  for item in items {
    if item is @scene.TextRunItem(..) {
      has_origin = true
    }
  }
  let stride = if has_origin { 25 } else { 23 }
  let data = FixedArray::make(5 + items.length() * stride, 0.0)
  data[0] = viewport.left()
  data[1] = viewport.top()
  data[2] = viewport.size().width()
  data[3] = viewport.size().height()
  data[4] = snapshot.scale()
  let blob : Array[Byte] = []
  let chains = snapshot.clip_chains()
  let mut text_count = 0
  for index = 0; index < items.length(); index = index + 1 {
    let offset = 5 + index * stride
    match items[index] {
      @scene.TextItem(text~, font_size~, ..)
      | @scene.TextRunItem(text~, font_size~, ..) => {
        text_count += 1
        if text_count > 256 {
          return Err(backend_error(8, "present"))
        }
        if font_size > @linux_text.max_font_size_px {
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
        if byte_length > @linux_text.max_text_bytes ||
          blob.length() > 1048576 - byte_length {
          return Err(backend_error(8, "present"))
        }
        let bytes = @utf8.encode(document.text())
        if bytes.length() > @linux_text.max_text_bytes ||
          blob.length() > 1048576 - bytes.length() {
          return Err(backend_error(8, "present"))
        }
        data[offset] = if items[index] is @scene.TextRunItem(..) {
          2.0
        } else {
          1.0
        }
        data[offset + 20] = blob.length().to_double()
        data[offset + 21] = bytes.length().to_double()
        data[offset + 22] = font_size
        for byte in bytes {
          if byte == b'\x00' {
            return Err(backend_error(1, "present"))
          }
          blob.push(byte)
        }
      }
      @scene.QuadItem(..) => ()
    }
    if items[index] is @scene.TextRunItem(text_origin~, ..) {
      data[offset + 23] = text_origin.x()
      data[offset + 24] = text_origin.y()
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
        data[offset + 1] = bounds.left()
        data[offset + 2] = bounds.top()
        data[offset + 3] = bounds.size().width()
        data[offset + 4] = bounds.size().height()
        data[offset + 5] = color.red().to_double()
        data[offset + 6] = color.green().to_double()
        data[offset + 7] = color.blue().to_double()
        data[offset + 8] = color.alpha().to_double()
        data[offset + 9] = transform.a()
        data[offset + 10] = transform.b()
        data[offset + 11] = transform.c()
        data[offset + 12] = transform.d()
        data[offset + 13] = transform.tx()
        data[offset + 14] = transform.ty()
        data[offset + 15] = opacity
        if clip is Some(rect) {
          data[offset + 16] = rect.left()
          data[offset + 17] = rect.top()
          data[offset + 18] = rect.size().width()
          data[offset + 19] = rect.size().height()
        }
      }
    }
  }
  Ok({
    abi: if has_origin {
      3
    } else {
      2
    },
    data,
    text: Bytes::from_array(blob),
  })
}

///|
pub fn Host::present(
  self : Host,
  window : @platform.WindowId,
  snapshot : @scene.SceneSnapshot,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let mut has_text = false
  for item in snapshot.items() {
    if item is @scene.TextItem(..) || item is @scene.TextRunItem(..) {
      has_text = true
    }
  }
  if !has_text {
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
  } else {
    match @linux_text.require_grayscale_raster() {
      Ok(_) => ()
      Err(_) => return Err(backend_error(1, "present"))
    }
    match mixed_frame_data(snapshot) {
      Err(error) => Err(error)
      Ok(frame) => {
        let status = if frame.abi == 3 {
          native_present_origin(
            3,
            self.token,
            window.value().to_int(),
            frame.data,
            frame.data.length(),
            frame.text,
            frame.text.length(),
          )
        } else {
          native_present_mixed(
            2,
            self.token,
            window.value().to_int(),
            frame.data,
            frame.data.length(),
            frame.text,
            frame.text.length(),
          )
        }
        outcome(status, "present")
      }
    }
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
    @platform.GrayscaleTextFrames =>
      match @linux_text.require_grayscale_raster() {
        Ok(_) => Ok(())
        Err(_) => Err(backend_error(1, "require_capability"))
      }
    @platform.Clipboard =>
      outcome(native_capability(self.token, 1), "require_capability")
    @platform.Cursor =>
      outcome(native_capability(self.token, 2), "require_capability")
    @platform.DirectKeyboardText =>
      direct_text_capability_outcome(native_capability(self.token, 3))
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
/// Reject portable identities that cannot be represented by the native ABI.
fn direct_window_token(
  window : @platform.WindowId,
  operation : String,
) -> Result[Int, @diagnostics.FrameworkError] {
  let value = window.value()
  if value < 1L || value > 2147483647L {
    Err(backend_error(3, operation))
  } else {
    Ok(value.to_int())
  }
}

///|
/// Explicitly arm or disarm copied direct-keyboard text for this logical
/// window. Keyboard text remains unsupported until the native target admits it.
pub fn Host::set_direct_keyboard_text(
  self : Host,
  window : @platform.WindowId,
  enabled : Bool,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let native_window = match
    direct_window_token(window, "set_direct_keyboard_text") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  outcome(
    native_direct_keyboard_text_mode(
      self.token,
      native_window,
      if enabled {
        1
      } else {
        0
      },
    ),
    "set_direct_keyboard_text",
  )
}

///|
/// Current positive, nonwrapping epoch of an armed native direct-text target.
pub fn Host::direct_keyboard_text_epoch(
  self : Host,
  window : @platform.WindowId,
) -> Result[Int, @diagnostics.FrameworkError] {
  let native_window = match
    direct_window_token(window, "direct_keyboard_text_epoch") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let epoch = native_direct_keyboard_text_epoch(self.token, native_window)
  if epoch > 0 {
    Ok(epoch)
  } else if epoch < 0 {
    Err(backend_error(-epoch, "direct_keyboard_text_epoch"))
  } else {
    Err(backend_error(3, "direct_keyboard_text_epoch"))
  }
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
