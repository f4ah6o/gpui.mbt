///|
/// Identity captured when the native editor record was accepted. Epochs and
/// proxy generations fence delayed callbacks; serials are never deduplicated.
pub(all) struct TextSessionTarget {
  window : @platform.WindowId
  sequence : Int64
  epoch : Int
  seat : Int64
  proxy_generation : Int
  serial : Int
}

///|
/// Preedit styling uses UTF-16 endpoints in the decoded preedit document.
/// Style is the text-input-v1 enum value, in the inclusive range 0..7.
pub(all) struct TextSessionStyle {
  range : @text.TextRange
  style : Int
}

///|
/// Signed UTF-8 byte index relative to the committed surrounding cursor.
/// Interpretation and boundary checks against that document belong to the
/// editor applying the atomic commit.
pub(all) struct TextSessionDeletion {
  index_bytes : Int
  length_bytes : Int
}

///|
/// Signed postinsert UTF-8 cursor/anchor indices from text-input-v1. These are
/// preserved exactly rather than interpreted against the inserted string.
pub(all) struct TextSessionPosition {
  cursor_index_bytes : Int
  anchor_index_bytes : Int
}

///|
/// Preedit fallback is captured for inspection and is never committed here.
/// Negative or absent native preedit cursors yield None. Forwarded keysyms
/// retain a raw symbol even when they have no portable command-key mapping.
pub(all) enum TextSessionEvent {
  Preedit(
    text~ : String,
    fallback~ : String,
    cursor_utf16~ : Int?,
    styles~ : Array[TextSessionStyle]
  )
  Commit(
    text~ : String,
    deletion~ : TextSessionDeletion?,
    position~ : TextSessionPosition?
  )
  Entered
  Left
  ForwardedPressed(
    keysym~ : Int,
    key~ : @primitives.Key?,
    modifiers~ : @primitives.Modifiers
  )
  ForwardedReleased(
    keysym~ : Int,
    key~ : @primitives.Key?,
    modifiers~ : @primitives.Modifiers
  )
}

///|
/// Dedicated incremental editor ingress. Portable platform records retain
/// their existing representation; composition stays Ubuntu-specific.
pub(all) enum EditorEvent {
  Platform(@platform.Event)
  TextSession(TextSessionTarget, TextSessionEvent)
}

///|
const EDITOR_ABI : Int = 3

///|
const IME_MAX_BYTES : Int = 4096

///|
const IME_MAX_STYLES : Int = 64

///|
const EDITOR_EVENT_FIELDS : Int = 217

///|
const EDITOR_MAX_PAYLOAD : Int = 8192

///|
#borrow(text)
extern "C" fn native_text_session_begin(
  host : Int,
  window : Int,
  text : Bytes,
  length : Int,
  cursor : Int,
  anchor : Int,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
) -> Int = "gpui_text_session_begin"

///|
#borrow(text)
extern "C" fn native_text_session_update(
  host : Int,
  window : Int,
  epoch : Int,
  text : Bytes,
  length : Int,
  cursor : Int,
  anchor : Int,
  x : Int,
  y : Int,
  width : Int,
  height : Int,
  external_edit : Int,
) -> Int = "gpui_text_session_update"

///|
extern "C" fn native_text_session_cancel(
  host : Int,
  window : Int,
  epoch : Int,
) -> Int = "gpui_text_session_cancel"

///|
extern "C" fn native_text_session_end(
  host : Int,
  window : Int,
  epoch : Int,
) -> Int = "gpui_text_session_end"

///|
extern "C" fn native_text_session_panel(
  host : Int,
  window : Int,
  epoch : Int,
  visible : Int,
) -> Int = "gpui_text_session_panel"

///|
#borrow(event, text)
extern "C" fn native_next_editor(
  abi : Int,
  host : Int,
  event : FixedArray[Double],
  event_capacity : Int,
  text : Bytes,
  text_capacity : Int,
) -> Int = "gpui_next_editor"

///|
fn text_session_epoch_outcome(
  epoch : Int,
  operation : String,
) -> Result[Int, @diagnostics.FrameworkError] {
  if epoch > 0 {
    Ok(epoch)
  } else if epoch < 0 {
    Err(backend_error(-epoch, operation))
  } else {
    Err(backend_error(3, operation))
  }
}

///|
/// Validate integral surface-logical coordinates. No output-scale conversion.
fn text_session_rect(
  rect : @primitives.Rect,
  operation : String,
) -> Result[(Int, Int, Int, Int), @diagnostics.FrameworkError] {
  let x = rect.left()
  let y = rect.top()
  let width = rect.size().width()
  let height = rect.size().height()
  if !exact_i32(x) ||
    !exact_i32(y) ||
    !exact_i32(width) ||
    !exact_i32(height) ||
    width <= 0.0 ||
    height <= 0.0 {
    Err(backend_error(3, operation))
  } else {
    Ok((x.to_int(), y.to_int(), width.to_int(), height.to_int()))
  }
}

///|
fn text_session_surrounding(
  document : @text.TextDocument,
  operation : String,
) -> Result[(Bytes, Int, Int), @diagnostics.FrameworkError] {
  let length = match document.utf8_length() {
    Ok(value) => value
    Err(_) => return Err(backend_error(3, operation))
  }
  if length > IME_MAX_BYTES {
    return Err(backend_error(8, operation))
  }
  // Wayland transmits a NUL-terminated string. Reject interior NUL before any
  // native action, even though it is otherwise valid document text.
  for scalar in document.text().iter() {
    if scalar.to_int() == 0 {
      return Err(backend_error(3, operation))
    }
  }
  let selection = document.selection()
  let cursor = match document.utf8_offset(selection.head()) {
    Ok(value) => value
    Err(_) => return Err(backend_error(3, operation))
  }
  let anchor = match document.utf8_offset(selection.anchor()) {
    Ok(value) => value
    Err(_) => return Err(backend_error(3, operation))
  }
  Ok((@utf8.encode(document.text()), cursor, anchor))
}

///|
/// Opt in to experimental text-input-v1 with a committed document and logical
/// caret rectangle. A positive epoch identifies the session; wait for matching
/// Entered before accepting text events. Entered proves protocol focus, not
/// engine/grab readiness. The native backend copies borrowed text.
pub fn Host::begin_text_session(
  self : Host,
  window : @platform.WindowId,
  document : @text.TextDocument,
  rect : @primitives.Rect,
) -> Result[Int, @diagnostics.FrameworkError] {
  let operation = "begin_text_session"
  let native_window = match direct_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (bytes, cursor, anchor) = match
    text_session_surrounding(document, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (x, y, width, height) = match text_session_rect(rect, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  text_session_epoch_outcome(
    native_text_session_begin(
      self.token,
      native_window,
      bytes,
      bytes.length(),
      cursor,
      anchor,
      x,
      y,
      width,
      height,
    ),
    operation,
  )
}

///|
/// By default an external edit fences delayed composition through a native
/// deactivate/leave/reactivate cycle and returns a replacement epoch. Pass
/// external_edit=false only when acknowledging an applied normal IME commit
/// or updating geometry while the committed transaction remains unchanged.
pub fn Host::update_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  document : @text.TextDocument,
  rect : @primitives.Rect,
  external_edit? : Bool = true,
) -> Result[Int, @diagnostics.FrameworkError] {
  let operation = "update_text_session"
  if epoch <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match direct_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (bytes, cursor, anchor) = match
    text_session_surrounding(document, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (x, y, width, height) = match text_session_rect(rect, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  text_session_epoch_outcome(
    native_text_session_update(
      self.token,
      native_window,
      epoch,
      bytes,
      bytes.length(),
      cursor,
      anchor,
      x,
      y,
      width,
      height,
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
/// Discard pending preedit and fence delayed callbacks. Wait for Entered on
/// the returned replacement epoch before accepting further composition.
pub fn Host::cancel_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
) -> Result[Int, @diagnostics.FrameworkError] {
  let operation = "cancel_text_session"
  if epoch <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match direct_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  text_session_epoch_outcome(
    native_text_session_cancel(self.token, native_window, epoch),
    operation,
  )
}

///|
/// Request input-panel visibility for the current text session. During a
/// leave/reactivate fence, native code retains the choice for reactivation.
pub fn Host::set_text_session_panel(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  visible : Bool,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let operation = "set_text_session_panel"
  if epoch <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match direct_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  outcome(
    native_text_session_panel(
      self.token,
      native_window,
      epoch,
      if visible {
        1
      } else {
        0
      },
    ),
    operation,
  )
}

///|
pub fn Host::end_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let operation = "end_text_session"
  if epoch <= 0 {
    return Err(backend_error(3, operation))
  }
  let native_window = match direct_window_token(window, operation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  outcome(native_text_session_end(self.token, native_window, epoch), operation)
}

///|
fn editor_decode_error(
  operation : String,
  message : String,
) -> @diagnostics.FrameworkError {
  native_text_decode_error(@diagnostics.InvalidInput, operation, message)
}

///|
fn editor_zero_fields(
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
fn editor_flag(value : Double) -> Bool {
  value == 0.0 || value == 1.0
}

///|
fn editor_decode_string(
  bytes : Bytes,
  start : Int,
  length : Int,
  operation : String,
) -> Result[String, @diagnostics.FrameworkError] {
  let exact = Bytes::makei(length, index => bytes[start + index])
  for byte in exact {
    if byte == (0).to_byte() {
      return Err(editor_decode_error(operation, "editor payload contains NUL"))
    }
  }
  try @utf8.decode(exact) catch {
    _ =>
      Err(
        native_text_decode_error(
          @diagnostics.ConversionFailed,
          operation,
          "editor payload is not valid UTF-8",
        ),
      )
  } noraise {
    value => Ok(value)
  }
}

///|
/// Defensively decode the complete ABI3 record before exposing any typed value.
fn decode_editor_event(
  data : FixedArray[Double],
  bytes : Bytes,
  operation : String,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  if data.length() < EDITOR_EVENT_FIELDS {
    return Err(editor_decode_error(operation, "short editor event buffer"))
  }
  if !exact_i32(data[0]) ||
    !exact_i32(data[1]) ||
    data[1] <= 0.0 ||
    !exact_i32(data[2]) ||
    data[2] <= 0.0 ||
    data[3].is_nan() ||
    data[3].is_inf() ||
    data[3] <= 0.0 {
    return Err(editor_decode_error(operation, "invalid editor event identity"))
  }
  let tag = data[0].to_int()
  if tag >= 1 && tag <= 13 {
    if !editor_zero_fields(data, 10, EDITOR_EVENT_FIELDS) {
      return Err(
        editor_decode_error(operation, "ordinary event has editor metadata"),
      )
    }
    match decode_v2_event(data, bytes, operation) {
      Err(error) => Err(error)
      Ok(None) => Ok(None)
      Ok(Some(kind)) => Ok(Some(Platform(make_event(data, kind))))
    }
  } else if tag < 20 || tag > 25 {
    Err(editor_decode_error(operation, "unknown editor event tag"))
  } else {
    if !exact_i32(data[10]) ||
      data[10] <= 0.0 ||
      data[11].is_nan() ||
      data[11].is_inf() ||
      data[11] < 1.0 ||
      data[11] > 4294967295.0 ||
      data[11].to_int64().to_double() != data[11] ||
      !exact_i32(data[12]) ||
      data[12] <= 0.0 ||
      !exact_i32(data[13]) ||
      (if tag == 22 || tag == 23 { data[13] != 0.0 } else { data[13] <= 0.0 }) {
      return Err(
        editor_decode_error(operation, "invalid text session identity"),
      )
    }
    if !exact_i32(data[14]) ||
      data[14] < 0.0 ||
      data[14] > IME_MAX_BYTES.to_double() ||
      !exact_i32(data[15]) ||
      data[15] < 0.0 ||
      data[15] > IME_MAX_BYTES.to_double() ||
      !editor_flag(data[16]) ||
      !exact_i32(data[17]) ||
      !editor_flag(data[18]) ||
      !exact_i32(data[19]) ||
      !exact_i32(data[20]) ||
      data[20] < 0.0 ||
      data[20] > IME_MAX_BYTES.to_double() ||
      !editor_flag(data[21]) ||
      !exact_i32(data[22]) ||
      !exact_i32(data[23]) ||
      !exact_i32(data[24]) ||
      data[24] < 0.0 ||
      data[24] > IME_MAX_STYLES.to_double() {
      return Err(editor_decode_error(operation, "invalid editor metadata"))
    }
    let length = data[14].to_int()
    let fallback_length = data[15].to_int()
    let style_count = data[24].to_int()
    if bytes.length() < length + fallback_length ||
      !editor_zero_fields(data, 25 + style_count * 3, EDITOR_EVENT_FIELDS) ||
      (data[16] == 0.0 && data[17] != 0.0) ||
      (data[18] == 0.0 && (data[19] != 0.0 || data[20] != 0.0)) ||
      (data[21] == 0.0 && (data[22] != 0.0 || data[23] != 0.0)) ||
      !editor_zero_fields(data, 4, 6) {
      return Err(editor_decode_error(operation, "inconsistent editor metadata"))
    }
    let target : TextSessionTarget = {
      window: @platform.WindowId::new(data[1].to_int64()),
      sequence: data[2].to_int64(),
      epoch: data[10].to_int(),
      seat: data[11].to_int64(),
      proxy_generation: data[12].to_int(),
      serial: data[13].to_int(),
    }
    if tag == 22 || tag == 23 {
      if !editor_zero_fields(data, 6, 10) ||
        !editor_zero_fields(data, 14, EDITOR_EVENT_FIELDS) {
        return Err(
          editor_decode_error(operation, "lifecycle event has text metadata"),
        )
      }
      Ok(Some(TextSession(target, if tag == 22 { Entered } else { Left })))
    } else if tag == 24 || tag == 25 {
      if data[6] != 0.0 ||
        data[7] != 0.0 ||
        !exact_i32(data[8]) ||
        data[8] < 0.0 ||
        data[8] > 0x1fffffff ||
        !exact_i32(data[9]) ||
        data[9] < 0.0 ||
        data[9] > 15.0 ||
        !editor_zero_fields(data, 14, EDITOR_EVENT_FIELDS) {
        return Err(
          editor_decode_error(operation, "invalid forwarded key fields"),
        )
      }
      let keysym = data[8].to_int()
      let key = key(keysym, 0)
      let modifiers = modifiers(data[9].to_int())
      let event = if tag == 24 {
        ForwardedPressed(keysym~, key~, modifiers~)
      } else {
        ForwardedReleased(keysym~, key~, modifiers~)
      }
      Ok(Some(TextSession(target, event)))
    } else {
      if !editor_zero_fields(data, 6, 10) {
        return Err(editor_decode_error(operation, "text event has key fields"))
      }
      let text = match editor_decode_string(bytes, 0, length, operation) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if tag == 21 {
        if fallback_length != 0 || data[16] != 0.0 || style_count != 0 {
          return Err(
            editor_decode_error(operation, "commit has preedit metadata"),
          )
        }
        let deletion = if data[18] == 1.0 {
          Some({
            index_bytes: data[19].to_int(),
            length_bytes: data[20].to_int(),
          })
        } else {
          None
        }
        let position = if data[21] == 1.0 {
          Some({
            cursor_index_bytes: data[22].to_int(),
            anchor_index_bytes: data[23].to_int(),
          })
        } else {
          None
        }
        Ok(Some(TextSession(target, Commit(text~, deletion~, position~))))
      } else {
        if data[18] != 0.0 || data[21] != 0.0 {
          return Err(
            editor_decode_error(operation, "preedit has commit metadata"),
          )
        }
        let fallback = match
          editor_decode_string(bytes, length, fallback_length, operation) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let document = match @text.TextDocument::new(text) {
          Ok(value) => value
          Err(_) =>
            return Err(
              editor_decode_error(operation, "invalid preedit document"),
            )
        }
        let cursor_utf16 = if data[16] == 1.0 && data[17] >= 0.0 {
          match document.utf16_offset(data[17].to_int()) {
            Ok(value) => Some(value)
            Err(_) =>
              return Err(
                editor_decode_error(operation, "preedit cursor splits UTF-8"),
              )
          }
        } else {
          None
        }
        let styles : Array[TextSessionStyle] = []
        for index = 0; index < style_count; index = index + 1 {
          let slot = 25 + index * 3
          if !exact_i32(data[slot]) ||
            data[slot] < 0.0 ||
            data[slot] > length.to_double() ||
            !exact_i32(data[slot + 1]) ||
            data[slot + 1] < 0.0 ||
            data[slot + 1] > length.to_double() - data[slot] ||
            !exact_i32(data[slot + 2]) ||
            data[slot + 2] < 0.0 ||
            data[slot + 2] > 7.0 {
            return Err(editor_decode_error(operation, "invalid preedit style"))
          }
          let start_bytes = data[slot].to_int()
          let end_bytes = start_bytes + data[slot + 1].to_int()
          let start = match document.utf16_offset(start_bytes) {
            Ok(value) => value
            Err(_) =>
              return Err(
                editor_decode_error(operation, "preedit style splits UTF-8"),
              )
          }
          let end = match document.utf16_offset(end_bytes) {
            Ok(value) => value
            Err(_) =>
              return Err(
                editor_decode_error(operation, "preedit style splits UTF-8"),
              )
          }
          let range = match @text.TextRange::new(start, end) {
            Ok(value) => value
            Err(_) =>
              return Err(
                editor_decode_error(operation, "invalid preedit style range"),
              )
          }
          styles.push({ range, style: data[slot + 2].to_int(), })
        }
        Ok(
          Some(
            TextSession(
              target,
              Preedit(text~, fallback~, cursor_utf16~, styles~),
            ),
          ),
        )
      }
    }
  }
}

///|
fn next_editor_event_from_native(
  read : (FixedArray[Double], FixedArray[Byte]) -> Int,
  dispatch : (Int) -> Int,
  timeout_ms : Int,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  let buffer = FixedArray::make(EDITOR_EVENT_FIELDS, 0.0)
  let payload_buffer = FixedArray::make(EDITOR_MAX_PAYLOAD, (0).to_byte())
  let payload = payload_buffer.unsafe_reinterpret_as_bytes()
  let mut dispatched = false
  while true {
    let status = read(buffer, payload_buffer)
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
      match decode_editor_event(buffer, payload, "next_editor_event") {
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
/// Drain one immutable copied editor/platform record. At most one dispatch
/// budget is spent per call, including when an unmapped ordinary key is ignored.
pub fn Host::next_editor_event(
  self : Host,
  timeout_ms? : Int = 16,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  next_editor_event_from_native(
    (buffer, payload) => {
      native_next_editor(
        EDITOR_ABI,
        self.token,
        buffer,
        buffer.length(),
        payload.unsafe_reinterpret_as_bytes(),
        payload.length(),
      )
    },
    timeout => native_dispatch(self.token, timeout),
    timeout_ms,
  )
}
