///|
/// Identity attached when the Windows native editor record was accepted.
/// `owner_generation` is a stable field identity; `epoch` changes when the
/// application explicitly rearms or externally replaces its committed text.
/// It is not a revision counter for each preedit callback.
pub(all) struct TextSessionTarget {
  window : @platform.WindowId
  sequence : Int64
  epoch : Int
  owner_generation : Int
}

///|
/// Copied records produced by the experimental Win32 IMM32 composition path.
/// All ranges and cursor offsets use UTF-16 code units. `replacement_range`
/// addresses the committed snapshot captured for the current composition.
pub(all) enum TextSessionEvent {
  CompositionStarted(replacement_range~ : @text.TextRange)
  Marked(
    text~ : String,
    cursor_utf16~ : Int?,
    attributes~ : Array[Int],
    replacement_range~ : @text.TextRange
  )
  Inserted(text~ : String, replacement_range~ : @text.TextRange)
  CompositionEnded
  Cancelled
}

///|
/// A single ordered reader for portable window events and experimental text
/// session records. Use `Host::next_event` only when no text session is armed;
/// it refuses to consume a typed queue head.
pub(all) enum EditorEvent {
  Platform(@platform.Event)
  TextSession(TextSessionTarget, TextSessionEvent)
}

///|
const SESSION_EVENT_FIELDS : Int = 20

///|
const SESSION_MAX_STRING_BYTES : Int = 4096

///|
const SESSION_MAX_ATTRIBUTES : Int = 4096

///|
const SESSION_MAX_PAYLOAD : Int = SESSION_MAX_STRING_BYTES +
  SESSION_MAX_ATTRIBUTES

///|
#borrow(text)
extern "C" fn native_session_begin(
  host : Int,
  window : Int,
  owner_generation : Int,
  text : Bytes,
  text_length : Int,
  anchor_utf16 : Int,
  head_utf16 : Int,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Int = "gpui_windows_session_begin"

///|
#borrow(text)
extern "C" fn native_session_update(
  host : Int,
  window : Int,
  epoch : Int,
  owner_generation : Int,
  text : Bytes,
  text_length : Int,
  anchor_utf16 : Int,
  head_utf16 : Int,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
  external_edit : Int,
) -> Int = "gpui_windows_session_update"

///|
extern "C" fn native_session_cancel(
  host : Int,
  window : Int,
  epoch : Int,
  owner_generation : Int,
) -> Int = "gpui_windows_session_cancel"

///|
extern "C" fn native_session_end(
  host : Int,
  window : Int,
  epoch : Int,
  owner_generation : Int,
) -> Int = "gpui_windows_session_end"

///|
#borrow(event, payload)
extern "C" fn native_next_editor(
  host : Int,
  event : FixedArray[Double],
  payload : FixedArray[Byte],
  payload_capacity : Int,
) -> Int = "gpui_windows_next_editor"

///|
extern "C" fn native_window_has_keyboard_focus(host : Int, window : Int) -> Int = "gpui_windows_window_has_keyboard_focus"

///|
extern "C" fn native_session_is_current(
  host : Int,
  window : Int,
  epoch : Int,
  owner_generation : Int,
) -> Int = "gpui_windows_session_is_current"

///|
fn session_exact_i32(value : Double) -> Bool {
  !value.is_nan() &&
  !value.is_inf() &&
  value >= -2147483648.0 &&
  value <= 2147483647.0 &&
  value.to_int().to_double() == value
}

///|
fn session_window_token(
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
fn session_epoch_outcome(
  value : Int,
  operation : String,
) -> Result[Int, @diagnostics.FrameworkError] {
  if value > 0 {
    Ok(value)
  } else if value < 0 {
    Err(backend_error(-value, operation))
  } else {
    Err(backend_error(3, operation))
  }
}

///|
fn session_rect_valid(
  rect : @primitives.Rect,
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let x = rect.left()
  let y = rect.top()
  let width = rect.size().width()
  let height = rect.size().height()
  if x.is_nan() ||
    x.is_inf() ||
    y.is_nan() ||
    y.is_inf() ||
    width.is_nan() ||
    width.is_inf() ||
    height.is_nan() ||
    height.is_inf() ||
    width < 0.0 ||
    height < 0.0 {
    Err(backend_error(3, operation))
  } else {
    Ok(())
  }
}

///|
/// The native session copies the committed UTF-8 snapshot and validates both
/// directional UTF-16 selection endpoints before arming IMM32.
fn session_document(
  document : @text.TextDocument,
  operation : String,
) -> Result[(Bytes, Int, Int), @diagnostics.FrameworkError] {
  let length = match document.utf8_length() {
    Ok(value) => value
    Err(_) => return Err(backend_error(3, operation))
  }
  if length > SESSION_MAX_STRING_BYTES {
    return Err(backend_error(8, operation))
  }
  for scalar in document.text().iter() {
    if scalar.to_int() == 0 {
      return Err(backend_error(3, operation))
    }
  }
  let selection = document.selection()
  Ok((@utf8.encode(document.text()), selection.anchor(), selection.head()))
}

///|
/// Arm the experimental one-window IMM32 text session. `owner_generation`
/// should stay constant for a field instance. The returned positive epoch is
/// the first armed epoch; an actual IMM composition begins with
/// `CompositionStarted`. This does not advertise portable TextInput support.
pub fn Host::begin_text_session(
  self : Host,
  window : @platform.WindowId,
  owner_generation : Int,
  document : @text.TextDocument,
  caret_rect : @primitives.Rect,
) -> Result[Int, @diagnostics.FrameworkError] {
  let operation = "begin_text_session"
  if owner_generation <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match session_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (text, anchor, head) = match session_document(document, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match session_rect_valid(caret_rect, operation) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  session_epoch_outcome(
    native_session_begin(
      self.token,
      native_window,
      owner_generation,
      text,
      text.length(),
      anchor,
      head,
      caret_rect.left(),
      caret_rect.top(),
      caret_rect.size().width(),
      caret_rect.size().height(),
    ),
    operation,
  )
}

///|
/// Refresh the committed snapshot and caret. `external_edit=true` invalidates
/// the current epoch, cancels marked text, and returns a replacement epoch.
/// Pass false when acknowledging an accepted native insertion or changing only
/// caret geometry; queued records retain their already-copied targets.
pub fn Host::update_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  owner_generation : Int,
  document : @text.TextDocument,
  caret_rect : @primitives.Rect,
  external_edit? : Bool = true,
) -> Result[Int, @diagnostics.FrameworkError] {
  let operation = "update_text_session"
  if epoch <= 0 || owner_generation <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match session_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (text, anchor, head) = match session_document(document, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match session_rect_valid(caret_rect, operation) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  session_epoch_outcome(
    native_session_update(
      self.token,
      native_window,
      epoch,
      owner_generation,
      text,
      text.length(),
      anchor,
      head,
      caret_rect.left(),
      caret_rect.top(),
      caret_rect.size().width(),
      caret_rect.size().height(),
      if external_edit {
        1
      } else {
        0
      },
    ),
    operation,
  )
}

///|
/// Cancel composition and rearm under a fresh epoch. The owner identity is
/// unchanged. Win32 IMM messages carry no source epoch; the native backend
/// detaches/reassociates the current HIMC, drains queued WM_IME messages, and
/// accepts composition only after a fresh START while that HIMC still matches.
pub fn Host::cancel_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  owner_generation : Int,
) -> Result[Int, @diagnostics.FrameworkError] {
  let operation = "cancel_text_session"
  if epoch <= 0 || owner_generation <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match session_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  session_epoch_outcome(
    native_session_cancel(self.token, native_window, epoch, owner_generation),
    operation,
  )
}

///|
pub fn Host::end_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  owner_generation : Int,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let operation = "end_text_session"
  if epoch <= 0 || owner_generation <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match session_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  outcome(
    native_session_end(self.token, native_window, epoch, owner_generation),
    operation,
  )
}

///|
/// Read the current OS keyboard-focus owner on the UI thread. This is useful
/// for guarding reentrant clipboard operations even when no IMM session is
/// armed; cached framework focus events can lag a synchronous focus transfer.
pub fn Host::window_has_keyboard_focus(
  self : Host,
  window : @platform.WindowId,
) -> Result[Bool, @diagnostics.FrameworkError] {
  let operation = "window_has_keyboard_focus"
  let native_window = match session_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status = native_window_has_keyboard_focus(self.token, native_window)
  if status < 0 {
    Err(backend_error(-status, operation))
  } else if status == 0 {
    Ok(false)
  } else if status == 1 {
    Ok(true)
  } else {
    Err(backend_error(3, operation))
  }
}

///|
/// Check that this exact native session owner remains armed. A window can
/// regain OS focus before the app consumes its queued focus-loss event, while
/// Win32 has already revoked the prior IMM32 session.
pub fn Host::text_session_is_current(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  owner_generation : Int,
) -> Result[Bool, @diagnostics.FrameworkError] {
  let operation = "text_session_is_current"
  if epoch <= 0 || owner_generation <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match session_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status = native_session_is_current(
    self.token,
    native_window,
    epoch,
    owner_generation,
  )
  if status < 0 {
    Err(backend_error(-status, operation))
  } else if status == 0 {
    Ok(false)
  } else if status == 1 {
    Ok(true)
  } else {
    Err(backend_error(3, operation))
  }
}

///|
fn session_decode_error(operation : String) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.InvalidInput,
    operation,
    backend="windows-d3d11",
    subsystem="text-session",
  )
}

///|
fn session_zero_fields(
  data : FixedArray[Double],
  start : Int,
  end : Int,
) -> Bool {
  for index = start; index < end; index = index + 1 {
    if data[index] != 0.0 {
      return false
    }
  }
  true
}

///|
fn session_range(
  start : Double,
  length : Double,
  operation : String,
) -> Result[@text.TextRange, @diagnostics.FrameworkError] {
  if !session_exact_i32(start) ||
    !session_exact_i32(length) ||
    start < 0.0 ||
    length < 0.0 ||
    start > 2147483647.0 - length {
    Err(session_decode_error(operation))
  } else {
    match @text.TextRange::new(start.to_int(), (start + length).to_int()) {
      Ok(range) => Ok(range)
      Err(_) => Err(session_decode_error(operation))
    }
  }
}

///|
fn session_decode_text(
  bytes : Bytes,
  length : Int,
  operation : String,
) -> Result[String, @diagnostics.FrameworkError] {
  if length < 0 || length > SESSION_MAX_STRING_BYTES || bytes.length() < length {
    return Err(session_decode_error(operation))
  }
  let exact = Bytes::makei(length, index => bytes[index])
  for byte in exact {
    if byte == (0).to_byte() {
      return Err(session_decode_error(operation))
    }
  }
  try @utf8.decode(exact) catch {
    _ => Err(session_decode_error(operation))
  } noraise {
    text => Ok(text)
  }
}

///|
fn session_decode_event(
  data : FixedArray[Double],
  payload : Bytes,
  operation : String,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  if data.length() < SESSION_EVENT_FIELDS ||
    !session_exact_i32(data[0]) ||
    !session_exact_i32(data[1]) ||
    data[1] < 0.0 ||
    data[2].is_nan() ||
    data[2].is_inf() ||
    data[2] < 0.0 ||
    data[2] > 9007199254740991.0 ||
    data[2].to_int64().to_double() != data[2] ||
    data[3].is_nan() ||
    data[3].is_inf() ||
    data[3] <= 0.0 {
    return Err(session_decode_error(operation))
  }
  let tag = data[0].to_int()
  if tag < 20 || tag > 24 {
    if (data[1] == 0.0 && data[2] != 0.0) || (data[1] > 0.0 && data[2] < 1.0) {
      return Err(session_decode_error(operation))
    }
    if !session_zero_fields(data, 10, SESSION_EVENT_FIELDS) {
      return Err(session_decode_error(operation))
    }
    match decode_event(data) {
      Some(kind) =>
        Ok(
          Some(
            Platform(
              @platform.Event::new(
                @platform.WindowId::new(Int64::from_int(data[1].to_int())),
                data[2].to_int64(),
                data[3],
                kind,
              ),
            ),
          ),
        )
      None => Ok(None)
    }
  } else {
    if data[1] <= 0.0 ||
      data[2] < 1.0 ||
      !session_exact_i32(data[10]) ||
      data[10] <= 0.0 ||
      !session_exact_i32(data[11]) ||
      data[11] <= 0.0 ||
      !session_exact_i32(data[12]) ||
      data[12] < 0.0 ||
      data[12] > SESSION_MAX_STRING_BYTES.to_double() ||
      (data[13] != 0.0 && data[13] != 1.0) ||
      !session_exact_i32(data[14]) ||
      data[14] < 0.0 ||
      (data[15] != 0.0 && data[15] != 1.0) ||
      !session_exact_i32(data[16]) ||
      data[16] < 0.0 ||
      !session_exact_i32(data[17]) ||
      data[17] < 0.0 ||
      !session_exact_i32(data[18]) ||
      data[18] < 0.0 ||
      data[18] > SESSION_MAX_ATTRIBUTES.to_double() ||
      data[19] != 0.0 {
      return Err(session_decode_error(operation))
    }
    let target : TextSessionTarget = {
      window: @platform.WindowId::new(Int64::from_int(data[1].to_int())),
      sequence: data[2].to_int64(),
      epoch: data[11].to_int(),
      owner_generation: data[10].to_int(),
    }
    let text_length = data[12].to_int()
    let attribute_count = data[18].to_int()
    if payload.length() < text_length + attribute_count {
      return Err(session_decode_error(operation))
    }
    if tag == 20 || tag == 21 || tag == 22 {
      if data[15] != 1.0 {
        return Err(session_decode_error(operation))
      }
      let range = match session_range(data[16], data[17], operation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if tag == 20 {
        if text_length != 0 ||
          data[13] != 0.0 ||
          data[14] != 0.0 ||
          attribute_count != 0 ||
          !session_zero_fields(data, 4, 10) {
          return Err(session_decode_error(operation))
        }
        Ok(
          Some(TextSession(target, CompositionStarted(replacement_range=range))),
        )
      } else if tag == 22 {
        if data[13] != 0.0 ||
          data[14] != 0.0 ||
          attribute_count != 0 ||
          !session_zero_fields(data, 4, 10) {
          return Err(session_decode_error(operation))
        }
        let text = match session_decode_text(payload, text_length, operation) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Ok(Some(TextSession(target, Inserted(text~, replacement_range=range))))
      } else {
        if !session_zero_fields(data, 4, 10) {
          return Err(session_decode_error(operation))
        }
        let text = match session_decode_text(payload, text_length, operation) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let document = match @text.TextDocument::new(text) {
          Ok(value) => value
          Err(_) => return Err(session_decode_error(operation))
        }
        if attribute_count != 0 && attribute_count != document.utf16_length() {
          return Err(session_decode_error(operation))
        }
        let cursor_utf16 = if data[13] == 1.0 {
          let cursor = data[14].to_int()
          if cursor > document.utf16_length() {
            return Err(session_decode_error(operation))
          }
          let selection = match @text.TextSelection::new(cursor, cursor) {
            Ok(value) => value
            Err(_) => return Err(session_decode_error(operation))
          }
          match document.with_selection(selection) {
            Ok(_) => Some(cursor)
            Err(_) => return Err(session_decode_error(operation))
          }
        } else {
          if data[14] != 0.0 {
            return Err(session_decode_error(operation))
          }
          None
        }
        let attributes : Array[Int] = []
        let attribute_start = text_length
        for index = 0; index < attribute_count; index = index + 1 {
          attributes.push(payload[attribute_start + index].to_int() & 0xff)
        }
        Ok(
          Some(
            TextSession(
              target,
              Marked(text~, cursor_utf16~, attributes~, replacement_range=range),
            ),
          ),
        )
      }
    } else {
      if text_length != 0 ||
        data[13] != 0.0 ||
        data[14] != 0.0 ||
        data[15] != 0.0 ||
        data[16] != 0.0 ||
        data[17] != 0.0 ||
        attribute_count != 0 ||
        !session_zero_fields(data, 4, 10) {
        return Err(session_decode_error(operation))
      }
      if tag == 23 {
        Ok(Some(TextSession(target, CompositionEnded)))
      } else {
        Ok(Some(TextSession(target, Cancelled)))
      }
    }
  }
}

///|
/// Read the shared FIFO through its typed view. One dispatch budget is spent
/// per call; platform records and text records retain one total order.
fn next_editor_event_from_native(
  read : (FixedArray[Double], FixedArray[Byte]) -> Int,
  dispatch : (Int) -> Int,
  timeout_ms : Int,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  let fields = FixedArray::make(SESSION_EVENT_FIELDS, 0.0)
  let payload = FixedArray::make(SESSION_MAX_PAYLOAD, (0).to_byte())
  let mut dispatched = false
  while true {
    let status = read(fields, payload)
    if status < 0 {
      return Err(backend_error(-status, "next_editor_event"))
    } else if status == 0 {
      if dispatched {
        return Ok(None)
      }
      dispatched = true
      match outcome(dispatch(timeout_ms), "next_editor_event") {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    } else if status != 1 {
      return Err(backend_error(3, "next_editor_event"))
    } else {
      match
        session_decode_event(
          fields,
          payload.unsafe_reinterpret_as_bytes(),
          "next_editor_event",
        ) {
        Err(error) => return Err(error)
        Ok(None) => continue
        Ok(Some(event)) => return Ok(Some(event))
      }
    }
  } nobreak {
    Ok(None)
  }
}

///|
pub fn Host::next_editor_event(
  self : Host,
  timeout_ms? : Int = 16,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  next_editor_event_from_native(
    (fields, payload) => {
      native_next_editor(self.token, fields, payload, payload.length())
    },
    timeout => native_dispatch(self.token, timeout),
    timeout_ms,
  )
}

///|
test "Windows session geometry and snapshots enforce bounded editor input" {
  let rect = @primitives.Rect::new(3.0, 4.0, 0.0, 18.0).unwrap()
  assert_true(
    match session_rect_valid(rect, "test") {
      Ok(_) => true
      Err(_) => false
    },
  )
  let document = @text.TextDocument::new("A😀").unwrap()
  let selection = @text.TextSelection::new(3, 1).unwrap()
  let selected = document.with_selection(selection).unwrap()
  let (bytes, anchor, head) = session_document(selected, "test").unwrap()
  assert_eq(bytes.length(), 5)
  assert_eq(anchor, 3)
  assert_eq(head, 1)
  let invalid_rect = @primitives.Rect::new(0.0, 0.0, 1.0, 1.0).unwrap()
  assert_true(
    match session_rect_valid(invalid_rect, "test") {
      Ok(_) => true
      Err(_) => false
    },
  )
}

///|
test "Windows text session decoder preserves UTF-16 ranges and attributes" {
  let text = "あ😀"
  let bytes = @utf8.encode(text)
  let payload_buffer = FixedArray::make(8192, (0).to_byte())
  for index = 0; index < bytes.length(); index = index + 1 {
    payload_buffer[index] = bytes[index]
  }
  payload_buffer[bytes.length()] = (0).to_byte()
  payload_buffer[bytes.length() + 1] = (1).to_byte()
  payload_buffer[bytes.length() + 2] = (2).to_byte()
  let payload = payload_buffer.unsafe_reinterpret_as_bytes()
  let data = FixedArray::make(SESSION_EVENT_FIELDS, 0.0)
  data[0] = 21.0
  data[1] = 9.0
  data[2] = 17.0
  data[3] = 1.5
  data[10] = 7.0
  data[11] = 4.0
  data[12] = bytes.length().to_double()
  data[13] = 1.0
  data[14] = 1.0
  data[15] = 1.0
  data[16] = 3.0
  data[17] = 2.0
  data[18] = 3.0
  match session_decode_event(data, payload, "test") {
    Err(_) => fail("well-formed UTF-16 editor record should decode")
    Ok(
      Some(
        TextSession(
          target,
          Marked(text~, cursor_utf16~, attributes~, replacement_range~)
        )
      )
    ) => {
      assert_eq(text, "あ😀")
      assert_true(target.window == @platform.WindowId::new(9L))
      assert_eq(target.sequence, 17L)
      assert_eq(target.epoch, 4)
      assert_eq(target.owner_generation, 7)
      assert_eq(cursor_utf16, Some(1))
      assert_eq(attributes, [0, 1, 2])
      assert_true(replacement_range == @text.TextRange::new(3, 5).unwrap())
    }
    _ => fail("expected marked text record")
  }
  data[4] = 640.0
  data[5] = 480.0
  assert_true(
    match session_decode_event(data, payload, "test") {
      Err(_) => true
      Ok(_) => false
    },
  )
}

///|
test "Windows session cursor rejects offsets inside surrogate pairs" {
  let bytes = @utf8.encode("😀")
  let payload_buffer = FixedArray::make(8192, (0).to_byte())
  for index = 0; index < bytes.length(); index = index + 1 {
    payload_buffer[index] = bytes[index]
  }
  let payload = payload_buffer.unsafe_reinterpret_as_bytes()
  let data = FixedArray::make(SESSION_EVENT_FIELDS, 0.0)
  data[0] = 21.0
  data[1] = 1.0
  data[2] = 1.0
  data[3] = 1.0
  data[10] = 1.0
  data[11] = 1.0
  data[12] = bytes.length().to_double()
  data[13] = 1.0
  data[14] = 1.0
  data[15] = 1.0
  data[18] = 0.0
  assert_true(
    match session_decode_event(data, payload, "test") {
      Err(_) => true
      Ok(_) => false
    },
  )
}

///|
test "typed Windows reader accepts host lifecycle and exact Int64 sequences" {
  let data = FixedArray::make(SESSION_EVENT_FIELDS, 0.0)
  data[0] = 13.0
  data[3] = 1.0
  assert_true(
    match
      session_decode_event(data, Bytes::makei(0, _ => (0).to_byte()), "test") {
      Ok(Some(Platform(event))) => event.sequence() == 0L
      _ => false
    },
  )

  data[1] = 9.0
  data[2] = 9007199254740991.0
  assert_true(
    match
      session_decode_event(data, Bytes::makei(0, _ => (0).to_byte()), "test") {
      Ok(Some(Platform(event))) =>
        event.sequence() == 9007199254740991L &&
        event.window() == @platform.WindowId::new(9L)
      _ => false
    },
  )
}

///|
test "Windows session decoder retains an empty active preedit" {
  let data = FixedArray::make(SESSION_EVENT_FIELDS, 0.0)
  data[0] = 21.0
  data[1] = 1.0
  data[2] = 1.0
  data[3] = 1.0
  data[10] = 2.0
  data[11] = 3.0
  data[13] = 1.0
  data[15] = 1.0
  data[16] = 2.0
  data[17] = 0.0
  let payload = Bytes::makei(0, _ => (0).to_byte())
  assert_true(
    match session_decode_event(data, payload, "test") {
      Ok(Some(TextSession(_, Marked(text~, cursor_utf16~, ..)))) =>
        text == "" && cursor_utf16 == Some(0)
      _ => false
    },
  )
}
