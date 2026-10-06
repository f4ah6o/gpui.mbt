///|
/// Identity copied when one native input dispatch produced an editor batch.
pub(all) struct TextSessionTarget {
  window : @platform.WindowId
  host_epoch : Int64
  epoch : Int
  sequence : Int64
  owner_revision : Int64
}

///|
pub(all) struct TextSessionStyle {
  range : @text.TextRange
  style : Int
}

///|
pub(all) enum TextSessionEvent {
  Preedit(
    text~ : String,
    fallback~ : String,
    cursor_utf16~ : Int?,
    styles~ : Array[TextSessionStyle],
    replacement_range~ : @text.TextRange?
  )
  Commit(text~ : String, replacement_range~ : @text.TextRange?)
  Entered
  Left
  Cancelled
  ForwardedPressed(
    key_code~ : Int,
    key~ : @primitives.Key?,
    modifiers~ : @primitives.Modifiers
  )
  ForwardedReleased(
    key_code~ : Int,
    key~ : @primitives.Key?,
    modifiers~ : @primitives.Modifiers
  )
}

///|
pub(all) struct EditorBatch {
  target : TextSessionTarget
  events : Array[TextSessionEvent]
}

///|
pub(all) enum EditorEvent {
  Platform(@platform.Event)
  TextSession(EditorBatch)
}

///|
pub fn EditorBatch::target(self : EditorBatch) -> TextSessionTarget {
  self.target
}

///|
pub fn EditorBatch::events(self : EditorBatch) -> Array[TextSessionEvent] {
  self.events.copy()
}

///|
pub fn TextSessionTarget::window(
  self : TextSessionTarget,
) -> @platform.WindowId {
  self.window
}

///|
pub fn TextSessionTarget::host_epoch(self : TextSessionTarget) -> Int64 {
  self.host_epoch
}

///|
pub fn TextSessionTarget::epoch(self : TextSessionTarget) -> Int {
  self.epoch
}

///|
pub fn TextSessionTarget::sequence(self : TextSessionTarget) -> Int64 {
  self.sequence
}

///|
pub fn TextSessionTarget::owner_revision(self : TextSessionTarget) -> Int64 {
  self.owner_revision
}

///|
pub fn TextSessionStyle::range(self : TextSessionStyle) -> @text.TextRange {
  self.range
}

///|
pub fn TextSessionStyle::style(self : TextSessionStyle) -> Int {
  self.style
}

///|
fn Host::window_token(
  _self : Host,
  window : @platform.WindowId,
  operation : String,
) -> Result[Int64, @diagnostics.FrameworkError] {
  if window.value() <= 0L {
    Err(error(@diagnostics.InvalidInput, operation))
  } else {
    Ok(window.value())
  }
}

///|
fn text_session_payload(
  document : @text.TextDocument,
  caret : @primitives.Rect,
  owner_revision : Int64,
  external_edit : Bool,
  acknowledged_sequence : Int64?,
  operation : String,
) -> Result[Bytes, @diagnostics.FrameworkError] {
  let byte_length = match document.utf8_length() {
    Ok(value) => value
    Err(_) => return Err(error(@diagnostics.InvalidInput, operation))
  }
  if byte_length > 16384 || document.utf16_length() > 16384 {
    return Err(error(@diagnostics.ResourceExhausted, operation))
  }
  let x = caret.left()
  let y = caret.top()
  let width = caret.size().width()
  let height = caret.size().height()
  for value in [x, y, width, height] {
    if value.is_nan() ||
      value.is_inf() ||
      value < -1000000000.0 ||
      value > 1000000000.0 {
      return Err(error(@diagnostics.InvalidInput, operation))
    }
  }
  if width <= 0.0 || height <= 0.0 || width > 4096.0 || height > 4096.0 {
    return Err(error(@diagnostics.InvalidInput, operation))
  }
  let selection = document.selection()
  let cursor = selection.head()
  let anchor = selection.anchor()
  let max_exact_json_integer = 9007199254740991L
  if owner_revision < 0L || owner_revision > max_exact_json_integer {
    return Err(error(@diagnostics.InvalidInput, operation))
  }
  match acknowledged_sequence {
    Some(sequence) if sequence < 0L || sequence > max_exact_json_integer =>
      return Err(error(@diagnostics.InvalidInput, operation))
    _ => ()
  }
  let ack : Json = match acknowledged_sequence {
    Some(value) => value.to_double().to_json()
    None => Json::null()
  }
  let json : Json = {
    "text": document.text().to_json(),
    "cursor": cursor.to_json(),
    "anchor": anchor.to_json(),
    "utf16_length": document.utf16_length().to_json(),
    "rect": {
      "x": x.to_json(),
      "y": y.to_json(),
      "width": width.to_json(),
      "height": height.to_json(),
    },
    "owner_revision": owner_revision.to_double().to_json(),
    "external_edit": external_edit.to_json(),
    "acknowledged_sequence": ack,
  }
  Ok(@utf8.encode(json.stringify()))
}

///|
pub fn Host::generation(
  self : Host,
) -> Result[Int64, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => Err(value)
    Ok(_) => Ok(self.marker)
  }
}

///|
/// Enable commit-only AppKit text input. TextInput comes from insertText after
/// AppKit resolves dead keys/modifiers; raw key characters are not promoted.
pub fn Host::set_direct_keyboard_text(
  self : Host,
  window : @platform.WindowId,
  enabled : Bool,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "set_direct_keyboard_text") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  status(
    call(17, token, if enabled { 1.0 } else { 0.0 }, 0.0, b"", 0),
    "set_direct_keyboard_text",
  )
}

///|
pub fn Host::direct_keyboard_text_epoch(
  self : Host,
  window : @platform.WindowId,
) -> Result[Int, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "direct_keyboard_text_epoch") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match
    status(call(18, token, 0.0, 0.0, b"", 0), "direct_keyboard_text_epoch") {
    Err(value) => Err(value)
    Ok(_) => {
      let epoch = integer(0).to_int()
      if epoch > 0 {
        Ok(epoch)
      } else {
        Err(error(@diagnostics.NativeFailure, "direct_keyboard_text_epoch"))
      }
    }
  }
}

///|
/// Enable the direct AppKit text mirror after the owner has accepted a field
/// frame. This publishes only copied document/caret state and never delivers
/// text back to the owner.
pub fn Host::update_direct_keyboard_text(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  document : @text.TextDocument,
  caret_rect : @primitives.Rect,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if epoch <= 0 {
    return Err(error(@diagnostics.InvalidInput, "update_direct_keyboard_text"))
  }
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "update_direct_keyboard_text") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  let bytes = match
    text_session_payload(
      document,
      caret_rect,
      0L,
      false,
      None,
      "update_direct_keyboard_text",
    ) {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  status(
    call(28, token, epoch.to_double(), 0.0, bytes, bytes.length()),
    "update_direct_keyboard_text",
  )
}

///|
pub fn Host::begin_text_session(
  self : Host,
  window : @platform.WindowId,
  document : @text.TextDocument,
  caret_rect : @primitives.Rect,
  owner_revision? : Int64 = 0L,
) -> Result[Int, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "begin_text_session") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  let bytes = match
    text_session_payload(
      document,
      caret_rect,
      owner_revision,
      false,
      None,
      "begin_text_session",
    ) {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match
    status(
      call(19, token, 0.0, 0.0, bytes, bytes.length()),
      "begin_text_session",
    ) {
    Err(value) => Err(value)
    Ok(_) => {
      let epoch = integer(0).to_int()
      if epoch > 0 {
        Ok(epoch)
      } else {
        Err(error(@diagnostics.NativeFailure, "begin_text_session"))
      }
    }
  }
}

///|
pub fn Host::update_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
  document : @text.TextDocument,
  caret_rect : @primitives.Rect,
  external_edit? : Bool = true,
  acknowledged_sequence? : Int64? = None,
  owner_revision? : Int64 = 0L,
) -> Result[Int, @diagnostics.FrameworkError] {
  if epoch <= 0 {
    return Err(error(@diagnostics.InvalidInput, "update_text_session"))
  }
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "update_text_session") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  let bytes = match
    text_session_payload(
      document, caret_rect, owner_revision, external_edit, acknowledged_sequence,
      "update_text_session",
    ) {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match
    status(
      call(20, token, epoch.to_double(), 0.0, bytes, bytes.length()),
      "update_text_session",
    ) {
    Err(value) => Err(value)
    Ok(_) => {
      let next_epoch = integer(0).to_int()
      if next_epoch > 0 {
        Ok(next_epoch)
      } else {
        Err(error(@diagnostics.NativeFailure, "update_text_session"))
      }
    }
  }
}

///|
pub fn Host::cancel_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
) -> Result[Int, @diagnostics.FrameworkError] {
  if epoch <= 0 {
    return Err(error(@diagnostics.InvalidInput, "cancel_text_session"))
  }
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "cancel_text_session") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match
    status(
      call(21, token, epoch.to_double(), 0.0, b"", 0),
      "cancel_text_session",
    ) {
    Err(value) => Err(value)
    Ok(_) => {
      let next_epoch = integer(0).to_int()
      if next_epoch > 0 {
        Ok(next_epoch)
      } else {
        Err(error(@diagnostics.NativeFailure, "cancel_text_session"))
      }
    }
  }
}

///|
pub fn Host::end_text_session(
  self : Host,
  window : @platform.WindowId,
  epoch : Int,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if epoch <= 0 {
    return Err(error(@diagnostics.InvalidInput, "end_text_session"))
  }
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "end_text_session") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  status(call(22, token, epoch.to_double(), 0.0, b"", 0), "end_text_session")
}

///|
/// Drain one ordered native event. While an editor session is active this is
/// the only event source; the native side blocks the next input until batch ACK.
pub fn Host::next_editor_event(
  self : Host,
  timeout_ms? : Int = 16,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  if timeout_ms < 0 || timeout_ms > 250 {
    return Err(error(@diagnostics.InvalidInput, "next_editor_event"))
  }
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  match
    status(
      call(23, 0, timeout_ms.to_double(), 0.0, b"", 0),
      "next_editor_event",
    ) {
    Err(value) => Err(value)
    Ok(_) => {
      let tag = integer(1).to_int()
      if tag == 0 {
        Ok(None)
      } else if tag == 18 {
        decode_editor_batch()
      } else {
        match decode_platform_event() {
          Ok(Some(value)) => Ok(Some(Platform(value)))
          Ok(None) => Ok(None)
          Err(value) => Err(value)
        }
      }
    }
  }
}

///|
/// @test_only
/// Post one deterministic NSEvent through this app's own NSApp event queue.
/// It is scoped to the current key window and never synthesizes global input.
pub fn Host::testing_post_key(
  self : Host,
  window : @platform.WindowId,
  key_code : Int,
  characters : String,
  characters_ignoring_modifiers : String,
  modifiers : @primitives.Modifiers,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if key_code < 0 || key_code > 65535 {
    return Err(error(@diagnostics.InvalidInput, "testing_post_key"))
  }
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_post_key") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  let modifier_bits = (if modifiers.shift() { 1 } else { 0 }) |
    (if modifiers.control() { 2 } else { 0 }) |
    (if modifiers.alt() { 4 } else { 0 }) |
    (if modifiers.meta() { 8 } else { 0 })
  let payload : Json = {
    "characters": characters.to_json(),
    "ignoring": characters_ignoring_modifiers.to_json(),
  }
  let bytes = @utf8.encode(payload.stringify())
  status(
    call(
      24,
      token,
      key_code.to_double(),
      modifier_bits.to_double(),
      bytes,
      bytes.length(),
    ),
    "testing_post_key",
  )
}

///|
/// @test_only
/// Current input source selected in this window's NSTextInputContext.
pub fn Host::testing_selected_input_source(
  self : Host,
  window : @platform.WindowId,
) -> Result[String, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_selected_input_source") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match
    status(call(25, token, 0.0, 0.0, b"", 0), "testing_selected_input_source") {
    Err(value) => Err(value)
    Ok(_) => read_text()
  }
}

///|
/// @test_only
/// Select the already-enabled Kotoeri Romaji source for this view's input
/// context, preserving that context's previous source for restoration.
pub fn Host::testing_select_kotoeri_source(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_select_kotoeri_source") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  status(call(31, token, 0.0, 0.0, b"", 0), "testing_select_kotoeri_source")
}

///|
/// @test_only
/// Restore this view's input context to the source saved by the select hook.
pub fn Host::testing_restore_input_source(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_restore_input_source") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  status(call(32, token, 0.0, 0.0, b"", 0), "testing_restore_input_source")
}

///|
/// @test_only
/// Inspect window key/focus and text-session state when native input setup fails.
pub fn Host::testing_text_window_state(
  self : Host,
  window : @platform.WindowId,
) -> Result[String, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_text_window_state") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match status(call(33, token, 0.0, 0.0, b"", 0), "testing_text_window_state") {
    Err(value) => Err(value)
    Ok(_) => read_text()
  }
}

///|
/// @test_only
/// Completed Metal readback identity. The native build must be compiled with
/// GPUI_TESTING; a regular dylib returns UnsupportedCapability.
pub fn Host::testing_frame_identity(
  self : Host,
  window : @platform.WindowId,
) -> Result[String, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_frame_identity") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match status(call(26, token, 0.0, 0.0, b"", 0), "testing_frame_identity") {
    Err(value) => Err(value)
    Ok(_) => read_text()
  }
}

///|
/// @test_only
/// Query firstRectForCharacterRange and copy its screen-coordinate result.
pub fn Host::testing_candidate_rect(
  self : Host,
  window : @platform.WindowId,
) -> Result[@primitives.Rect, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_candidate_rect") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match status(call(27, token, 0.0, 0.0, b"", 0), "testing_candidate_rect") {
    Err(value) => Err(value)
    Ok(_) =>
      match @primitives.Rect::new(number(1), number(2), number(3), number(4)) {
        Ok(value) => Ok(value)
        Err(_) =>
          Err(error(@diagnostics.ConversionFailed, "testing_candidate_rect"))
      }
  }
}

///|
/// @test_only
/// Return the receipt for the latest app-owned synthetic key pair. It proves
/// NSEvent reached this window's GPView and is not an editor callback.
pub fn Host::testing_key_dispatch_receipt(
  self : Host,
  window : @platform.WindowId,
) -> Result[String, @diagnostics.FrameworkError] {
  match self.check() {
    Err(value) => return Err(value)
    Ok(_) => ()
  }
  let token = match self.window_token(window, "testing_key_dispatch_receipt") {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  match
    status(call(29, token, 0.0, 0.0, b"", 0), "testing_key_dispatch_receipt") {
    Err(value) => Err(value)
    Ok(_) => read_text()
  }
}

///|
fn decode_editor_batch() -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  let source = match read_text() {
    Ok(value) => value
    Err(value) => return Err(value)
  }
  decode_editor_batch_json(source)
}

///|
/// Validate copied native JSON through the same strict decoder. Kept private
/// to the package so package tests can fuzz untrusted native payloads.
fn decode_editor_batch_json(
  source : String,
) -> Result[EditorEvent?, @diagnostics.FrameworkError] {
  let parsed = @json.parse(source) catch {
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let object = match parsed {
    Object(value) => value
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let int64_field = (key : String) => {
    match object.get(key) {
      Some(Number(value, ..)) if value >= 0.0 &&
        value <= 9007199254740991.0 &&
        value.to_int64().to_double() == value => Some(value.to_int64())
      _ => None
    }
  }
  let window = match int64_field("window") {
    Some(value) if value > 0L => @platform.WindowId::new(value)
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let host_epoch = match int64_field("host_epoch") {
    Some(value) if value > 0L => value
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let epoch = match int64_field("epoch") {
    Some(value) if value > 0L && value <= 2147483647L => value.to_int()
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let sequence = match int64_field("sequence") {
    Some(value) if value > 0L => value
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let owner_revision = match int64_field("owner_revision") {
    Some(value) => value
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let batch_events = match object.get("events") {
    Some(Array(value)) if value.length() > 0 && value.length() <= 64 => value
    _ => return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
  }
  let events : Array[TextSessionEvent] = []
  for item in batch_events {
    let event = match item {
      Object(value) => decode_text_session_event(value)
      _ => None
    }
    match event {
      Some(value) => events.push(value)
      None =>
        return Err(error(@diagnostics.ConversionFailed, "next_editor_event"))
    }
  }
  Ok(
    Some(
      TextSession({
        target: { window, host_epoch, epoch, sequence, owner_revision, },
        events,
      }),
    ),
  )
}

///|
fn decode_text_session_event(object : Map[String, Json]) -> TextSessionEvent? {
  let string_field = (key : String) => {
    match object.get(key) {
      Some(String(value)) => Some(value)
      _ => None
    }
  }
  let int_field = (key : String) => {
    match object.get(key) {
      Some(Number(value, ..)) if value >= 0.0 &&
        value <= 2147483647.0 &&
        value.to_int().to_double() == value => Some(value.to_int())
      _ => None
    }
  }
  let range_field = (key : String) => {
    match object.get(key) {
      Some(Null) => Ok(None)
      Some(Array([Number(start, ..), Number(end, ..)])) if start >= 0.0 &&
        end >= start &&
        end <= 16384.0 &&
        start.to_int().to_double() == start &&
        end.to_int().to_double() == end =>
        match @text.TextRange::new(start.to_int(), end.to_int()) {
          Ok(value) => Ok(Some(value))
          Err(_) => Err(())
        }
      _ => Err(())
    }
  }
  match object.get("kind") {
    Some(String("entered")) => Some(Entered)
    Some(String("left")) => Some(Left)
    Some(String("cancelled")) => Some(Cancelled)
    Some(String("preedit")) => {
      let text = match string_field("text") {
        Some(value) => value
        None => return None
      }
      if !valid_session_text(text) {
        return None
      }
      let fallback = match string_field("fallback") {
        Some(value) => value
        None => return None
      }
      if !valid_session_text(fallback) {
        return None
      }
      let cursor = match object.get("cursor_utf16") {
        Some(Null) => None
        Some(Number(value, ..)) if value >= 0.0 &&
          value <= text.length().to_double() &&
          value.to_int().to_double() == value &&
          valid_utf16_boundary(text, value.to_int()) => Some(value.to_int())
        _ => return None
      }
      let replacement = match range_field("replacement_range") {
        Ok(value) => value
        Err(_) => return None
      }
      let style_json = match object.get("styles") {
        Some(Array(value)) if value.length() <= 64 => value
        _ => return None
      }
      let styles : Array[TextSessionStyle] = []
      for item in style_json {
        let record = match item {
          Object(value) => value
          _ => return None
        }
        let start = match record.get("start") {
          Some(Number(value, ..)) if value >= 0.0 &&
            value <= text.length().to_double() &&
            value.to_int().to_double() == value &&
            valid_utf16_boundary(text, value.to_int()) => value.to_int()
          _ => return None
        }
        let end = match record.get("end") {
          Some(Number(value, ..)) if value >= start.to_double() &&
            value <= text.length().to_double() &&
            value.to_int().to_double() == value &&
            valid_utf16_boundary(text, value.to_int()) => value.to_int()
          _ => return None
        }
        let style = match record.get("style") {
          Some(Number(value, ..)) if value >= 0.0 &&
            value <= 2147483647.0 &&
            value.to_int().to_double() == value => value.to_int()
          _ => return None
        }
        let range = match @text.TextRange::new(start, end) {
          Ok(value) => value
          Err(_) => return None
        }
        styles.push({ range, style, })
      }
      Some(
        Preedit(
          text~,
          fallback~,
          cursor_utf16=cursor,
          styles~,
          replacement_range=replacement,
        ),
      )
    }
    Some(String("commit")) => {
      let text = match string_field("text") {
        Some(value) => value
        None => return None
      }
      if !valid_session_text(text) {
        return None
      }
      let replacement = match range_field("replacement_range") {
        Ok(value) => value
        Err(_) => return None
      }
      Some(Commit(text~, replacement_range=replacement))
    }
    Some(String("forwarded_pressed")) | Some(String("forwarded_released")) => {
      let key_code = match int_field("key_code") {
        Some(value) if value <= 65535 => value
        None => return None
        _ => return None
      }
      let modifiers = match object.get("modifiers") {
        Some(Number(value, ..)) if value >= 0.0 &&
          value <= 15.0 &&
          value.to_int().to_double() == value =>
          decode_modifiers(value.to_int())
        _ => return None
      }
      let key = match object.get("key") {
        Some(Null) => None
        Some(String(value)) => decode_key_name(value)
        _ => return None
      }
      let pressed = match object.get("kind") {
        Some(String(kind)) => kind == "forwarded_pressed"
        _ => false
      }
      if pressed {
        Some(ForwardedPressed(key_code~, key~, modifiers~))
      } else {
        Some(ForwardedReleased(key_code~, key~, modifiers~))
      }
    }
    _ => None
  }
}

///|
fn decode_key_name(value : String) -> @primitives.Key? {
  match value {
    "enter" => Some(@primitives.Enter)
    "escape" => Some(@primitives.Escape)
    "backspace" => Some(@primitives.Backspace)
    "delete" => Some(@primitives.Delete)
    "tab" => Some(@primitives.Tab)
    "space" => Some(@primitives.Space)
    "left" => Some(@primitives.ArrowLeft)
    "right" => Some(@primitives.ArrowRight)
    "up" => Some(@primitives.ArrowUp)
    "down" => Some(@primitives.ArrowDown)
    "home" => Some(@primitives.Home)
    "end" => Some(@primitives.End)
    "page_up" => Some(@primitives.PageUp)
    "page_down" => Some(@primitives.PageDown)
    text if text.length() > 0 && text.length() <= 8 =>
      Some(@primitives.Character(text))
    _ => None
  }
}

///|
/// Limit the ABI-copied text before it reaches the field owner. Provider
/// restrictions such as bidi/color remain typed owner errors, not parse errors.
fn valid_session_text(text : String) -> Bool {
  if text.length() > 16384 {
    return false
  }
  match @text.TextDocument::new(text) {
    Err(_) => return false
    Ok(_) => ()
  }
  let bytes = @utf8.encode(text)
  if bytes.length() > 16384 {
    return false
  }
  for byte in bytes {
    if byte == b'\x00' {
      return false
    }
  }
  true
}

///|
/// Reject a cursor/style endpoint in the middle of a UTF-16 surrogate pair.
fn valid_utf16_boundary(text : String, offset : Int) -> Bool {
  if offset < 0 || offset > text.length() {
    return false
  }
  if offset == 0 || offset == text.length() {
    return true
  }
  let units = text.code_units()
  match (units.get(offset - 1), units.get(offset)) {
    (Some(previous), Some(next)) =>
      !(previous.to_int() >= 0xD800 &&
      previous.to_int() <= 0xDBFF &&
      next.to_int() >= 0xDC00 &&
      next.to_int() <= 0xDFFF)
    _ => false
  }
}

///|
fn decode_modifiers(value : Int) -> @primitives.Modifiers {
  @primitives.Modifiers::new(
    shift=(value & 1) != 0,
    control=(value & 2) != 0,
    alt=(value & 4) != 0,
    meta=(value & 8) != 0,
  )
}

///|
fn decode_platform_event() -> Result[
  @platform.Event?,
  @diagnostics.FrameworkError,
] {
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
        Err(_) =>
          return Err(error(@diagnostics.InvalidInput, "next_editor_event"))
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
        Ok(value) => value
        Err(value) => return Err(value)
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
    16 => {
      let text = match read_text() {
        Ok(value) => value
        Err(value) => return Err(value)
      }
      @platform.Input(@primitives.TextInput(text~))
    }
    12 => @platform.CloseRequested
    13 => @platform.Destroyed
    14 => @platform.Wake
    15 => @platform.ExitRequested
    17 => {
      let position = match @primitives.Point::new(number(1), number(2)) {
        Ok(value) => value
        Err(_) =>
          return Err(error(@diagnostics.InvalidInput, "next_editor_event"))
      }
      let delta = match @primitives.Point::new(number(3), number(4)) {
        Ok(value) => value
        Err(_) =>
          return Err(error(@diagnostics.InvalidInput, "next_editor_event"))
      }
      @platform.Input(@primitives.Scroll(position~, delta~, modifiers~))
    }
    _ => return Err(error(@diagnostics.NativeFailure, "next_editor_event"))
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
