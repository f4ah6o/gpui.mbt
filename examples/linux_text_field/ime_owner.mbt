///|
// Bounded example owner. Native ingress validates issued serials; the owner
// adds the focused field's epoch, seat/proxy and strictly ordered FIFO target.
struct ImeOwner {
  epoch : Int
  entered : Bool
  seat : Int64
  proxy_generation : Int
  sequence : Int64
}

///|
enum ImeOwnerError {
  UnsupportedDeletion
  UnsupportedPosition
  UnsupportedStyle
  HiddenCursor
  Field(@text_field.TextFieldError)
} derive(Eq)

///|
fn ime_owner(epoch : Int) -> ImeOwner {
  { epoch, entered: false, seat: 0L, proxy_generation: 0, sequence: 0L, }
}

///|
fn ime_target_current(
  owner : ImeOwner,
  window : @platform.WindowId,
  target : @native.TextSessionTarget,
  lifecycle? : Bool = false,
) -> Bool {
  target.window == window &&
  target.epoch == owner.epoch &&
  target.sequence > owner.sequence &&
  (
    lifecycle ||
    (
      owner.entered &&
      target.seat == owner.seat &&
      target.proxy_generation == owner.proxy_generation &&
      target.serial > 0
    )
  )
}

///|
fn ime_preedit(
  field : @text_field.TextField,
  text : String,
  cursor : Int?,
  styles : Array[@native.TextSessionStyle],
) -> Result[@text_field.TextField, ImeOwnerError] {
  // The bounded Mozc profile uses a full-span underline. Other shapes are
  // explicitly rejected; fallback text is never inserted by this owner.
  for style in styles {
    if style.style != 5 ||
      style.range.start() != 0 ||
      style.range.end() != text.length() {
      return Err(UnsupportedStyle)
    }
  }
  if text.length() == 0 {
    // An empty preedit restores the original selection/history, never deletes
    // it. A following commit still replaces that restored selection atomically.
    return match field.cancel_composition(measure, admit) {
      Ok(value) => Ok(value)
      Err(error) => Err(Field(error))
    }
  }
  let cursor = match cursor {
    Some(value) => value
    None => return Err(HiddenCursor)
  }
  let selection = match @text.TextSelection::new(cursor, cursor) {
    Ok(value) => value
    Err(_) => return Err(Field(@text_field.InvalidSelection))
  }
  match field.update_composition(text, selection, measure, admit) {
    Ok(value) => {
      let range = value.marked_range().unwrap()
      let start = match value.measurement().caret_at(range.start()) {
        Ok(value) => value
        Err(_) => return Err(Field(@text_field.InvalidSelection))
      }
      let end = match value.measurement().caret_at(range.end()) {
        Ok(value) => value
        Err(_) => return Err(Field(@text_field.InvalidSelection))
      }
      if !start.is_cursor_position() ||
        !end.is_cursor_position() ||
        end.strong().left() < start.strong().left() {
        return Err(Field(@text_field.InvalidSelection))
      }
      Ok(value)
    }
    Err(error) => Err(Field(error))
  }
}

///|
fn ime_commit(
  field : @text_field.TextField,
  text : String,
  deletion : @native.TextSessionDeletion?,
  position : @native.TextSessionPosition?,
) -> Result[@text_field.TextField, ImeOwnerError] {
  // Metadata is never silently ignored, including on an empty commit. This
  // first Japanese profile does not qualify reconversion/surrounding deletion
  // or signed postinsert cursor semantics.
  if deletion is Some(_) {
    return Err(UnsupportedDeletion)
  }
  if position is Some(_) {
    return Err(UnsupportedPosition)
  }
  let result = if field.is_composing() {
    field.commit_composition(text, measure, admit)
  } else {
    field.replace_selection(text, measure, admit)
  }
  match result {
    Ok(value) => Ok(value)
    Err(error) => Err(Field(error))
  }
}

///|
// This function maps only named commands and an explicit shortcut allowlist.
// It never derives direct text from a keysym. Actual releases remain releases.
fn ime_command_key(
  keysym : Int,
  key : @primitives.Key?,
  modifiers : @primitives.Modifiers,
) -> @primitives.Key? {
  if modifiers.control() || modifiers.meta() {
    match keysym {
      0x61 | 0x41 => return Some(@primitives.Character("a"))
      0x63 | 0x43 => return Some(@primitives.Character("c"))
      0x78 | 0x58 => return Some(@primitives.Character("x"))
      0x76 | 0x56 => return Some(@primitives.Character("v"))
      0x7a | 0x5a => return Some(@primitives.Character("z"))
      0x79 | 0x59 => return Some(@primitives.Character("y"))
      _ => ()
    }
  }
  match key {
    Some(@primitives.Character(_)) | Some(@primitives.Space) => None
    value => value
  }
}

///|
fn ime_caret_rect(
  field : @text_field.TextField,
) -> Result[@primitives.Rect, @text_field.TextFieldError] {
  let caret = match field.caret_rect() {
    Ok(value) => value
    Err(_) => return Err(@text_field.UnsupportedLayout)
  }
  let left = caret.left().floor()
  let top = caret.top().floor()
  let right = caret.right().ceil()
  let bottom = caret.bottom().ceil()
  // Bound endpoints before subtraction and conversion. The surface logical
  // mapping already includes field inset, measured run origin and scrolling.
  for value in [left, top, right, bottom] {
    if value.is_nan() ||
      value.is_inf() ||
      value < -2147483648.0 ||
      value > 2147483647.0 {
      return Err(@text_field.InvalidBounds)
    }
  }
  let width = right - left
  let height = bottom - top
  if width < 1.0 ||
    height < 1.0 ||
    width > 2147483647.0 ||
    height > 2147483647.0 {
    return Err(@text_field.InvalidBounds)
  }
  match @primitives.Rect::new(left, top, width, height) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.InvalidBounds)
  }
}

///|
fn ime_sync(
  host : @native.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : ImeOwner?,
  external_edit : Bool,
) -> Result[ImeOwner, @diagnostics.FrameworkError] {
  let caret = match ime_caret_rect(field) {
    Ok(value) => value
    Err(_) =>
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "ime_caret_rect",
        ),
      )
  }
  match owner {
    None => {
      match host.set_direct_keyboard_text(window, false) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match host.begin_text_session(window, field.committed_document(), caret) {
        Ok(epoch) => Ok(ime_owner(epoch))
        Err(error) => Err(error)
      }
    }
    Some(owner) =>
      match
        host.update_text_session(
          window,
          owner.epoch,
          field.committed_document(),
          caret,
          external_edit~,
        ) {
        Ok(epoch) => Ok(ime_owner_after_update(owner, epoch))
        Err(error) => Err(error)
      }
  }
}

///|
fn ime_observer_line(
  presentation : Int,
  field : @text_field.TextField,
  owner : ImeOwner?,
  commits : Int,
) -> String {
  let document = field.document()
  let committed = field.committed_document()
  let selection = field.selection()
  let original = committed.selection()
  let marked : Json = match field.marked_range() {
    Some(value) =>
      { "start": value.start().to_json(), "end": value.end().to_json() }
    None => Json::null()
  }
  let rect : Json = match ime_caret_rect(field) {
    Ok(value) =>
      {
        "x": value.left().to_int().to_json(),
        "y": value.top().to_int().to_json(),
        "width": value.size().width().to_int().to_json(),
        "height": value.size().height().to_int().to_json(),
      }
    Err(_) => Json::null()
  }
  let epoch = match owner {
    Some(value) => value.epoch
    None => 0
  }
  let entered = match owner {
    Some(value) => value.entered
    None => false
  }
  let value : Json = {
    "version": 1,
    "presentation": presentation.to_json(),
    "committed": committed.text().to_json(),
    "preview": document.text().to_json(),
    "selection": {
      "anchor": selection.anchor().to_json(),
      "head": selection.head().to_json(),
    },
    "committed_selection": {
      "anchor": original.anchor().to_json(),
      "head": original.head().to_json(),
    },
    "marked": marked,
    "composing": field.is_composing().to_json(),
    "focused": field.is_focused().to_json(),
    "revision": field.revision().to_json(),
    "epoch": epoch.to_json(),
    "entered": entered.to_json(),
    "commits": commits.to_json(),
    "can_undo": field.can_undo().to_json(),
    "can_redo": field.can_redo().to_json(),
    "caret": rect,
  }
  "GPUI_FIELD_IME_STATE \{value.stringify()}"
}

///|
fn ImeOwnerError::label(self : ImeOwnerError) -> String {
  match self {
    UnsupportedDeletion => "UnsupportedDeletion"
    UnsupportedPosition => "UnsupportedPosition"
    UnsupportedStyle => "UnsupportedStyle"
    HiddenCursor => "HiddenCursor"
    Field(_) => "FieldAdmission"
  }
}

///|
// A replacement native epoch starts unentered with no old proxy/seat/sequence.
// The native successful update contract guarantees a positive returned epoch.
fn ime_owner_after_update(owner : ImeOwner, epoch : Int) -> ImeOwner {
  if epoch == owner.epoch {
    owner
  } else {
    ime_owner(epoch)
  }
}

///|
// Keep restoration and explicit resolution as one failure-atomic value step.
// A reset engine never inherits an old displayed preview transaction.
fn restore_rejected_ime_field(
  submitted : @text_field.TextField,
  pending : @text_field.TextField,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  match restore_submitted_field(submitted, pending) {
    Ok(value) => value.cancel_composition(measure, admit)
    Err(error) => Err(error)
  }
}
