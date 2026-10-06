///|
enum FieldFrameDecision {
  Accepted
  BusyPending
  RecoverPending
  RejectPending
} derive(Eq)

///|
fn classify_field_frame(
  result : Result[Unit, @diagnostics.FrameworkError],
) -> FieldFrameDecision {
  match result {
    Ok(_) => Accepted
    Err(error) =>
      match error.code() {
        @diagnostics.Busy => BusyPending
        @diagnostics.SurfaceLost | @diagnostics.DeviceLost => RecoverPending
        _ => RejectPending
      }
  }
}

///|
fn restore_submitted_field(
  submitted : @text_field.TextField,
  pending : @text_field.TextField,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  // Reuse current geometry/focus while restoring the submitted immutable
  // snapshot, including both bounded history stacks and its composition.
  match submitted.with_bounds(pending.bounds()) {
    Ok(value) => value.with_focus(pending.is_focused())
    Err(error) => Err(error)
  }
}

///|
fn cut_after_write(
  previous : @text_field.TextField,
  candidate : @text_field.TextField,
  epoch_before : Int?,
  epoch_after : Int?,
  focus_before : Bool,
  focus_after : Bool,
  write : Result[Unit, @diagnostics.FrameworkError],
) -> @text_field.TextField {
  let epoch_current = match (epoch_before, epoch_after) {
    (Some(before), Some(after)) => before == after
    (None, None) => true
    _ => false
  }
  match write {
    Ok(_) if epoch_current &&
      focus_before &&
      focus_after &&
      previous.is_focused() &&
      previous.revision() == candidate.revision() - 1 => candidate
    _ => previous
  }
}

///|
fn paste_if_current(
  field : @text_field.TextField,
  revision : Int,
  epoch_before : Int?,
  epoch_after : Int?,
  focus_before : Bool,
  focus_after : Bool,
  text : String,
  measure_fn : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    @text_field.TextFieldError,
  ],
  admit_fn : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    @text_field.TextFieldError,
  ],
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let epoch_current = match (epoch_before, epoch_after) {
    (Some(before), Some(after)) => before == after
    (None, None) => true
    _ => false
  }
  if epoch_current &&
    focus_before &&
    focus_after &&
    field.revision() == revision &&
    field.is_focused() {
    field.replace_selection(text, measure_fn, admit_fn)
  } else {
    Ok(field)
  }
}

///|
fn replacement_target_matches(
  field : @text_field.TextField,
  replacement : @text.TextRange,
) -> Bool {
  let selection = if field.is_composing() {
    field.committed_document().selection().normalized_range()
  } else {
    field.selection().normalized_range()
  }
  replacement == selection
}

///|
struct NativeFieldComposition {
  original : @text_field.TextField
  replacement_range : @text.TextRange
}

///|
struct WindowsTextOwner {
  owner_generation : Int
  epoch : Int
  sequence : Int64
  composition : NativeFieldComposition?
}

///|
fn windows_text_owner(owner_generation : Int, epoch : Int) -> WindowsTextOwner {
  { owner_generation, epoch, sequence: 0L, composition: None, }
}

///|
fn windows_text_session_requested(
  experimental_ime : Bool,
  field_focused : Bool,
  native_focused : Bool,
) -> Bool {
  experimental_ime && field_focused && native_focused
}

///|
/// An active IMM preedit is resolved before explicit app edits, but native
/// candidate navigation and conversion keys remain owned by IMM.
fn windows_resolves_preedit(
  composition_active : Bool,
  input : @primitives.InputEvent,
) -> Bool {
  if !composition_active {
    false
  } else {
    match input {
      @primitives.PointerButtonPressed(..) | @primitives.TextInput(..) => true
      @primitives.KeyPressed(key=@primitives.Escape, ..) => true
      @primitives.KeyPressed(modifiers~, ..) =>
        (modifiers.control() || modifiers.meta()) && !modifiers.alt()
      _ => false
    }
  }
}

///|
fn windows_text_owner_after_update(
  owner : WindowsTextOwner,
  epoch : Int,
) -> WindowsTextOwner {
  if owner.epoch == epoch {
    owner
  } else {
    windows_text_owner(owner.owner_generation, epoch)
  }
}

///|
fn windows_session_target_current(
  owner : WindowsTextOwner,
  window : @platform.WindowId,
  target : @native.TextSessionTarget,
) -> Bool {
  owner.owner_generation > 0 &&
  owner.epoch > 0 &&
  target.window == window &&
  target.owner_generation == owner.owner_generation &&
  target.epoch == owner.epoch &&
  target.sequence > owner.sequence
}

///|
fn windows_text_owner_accept_event(
  owner : WindowsTextOwner,
  target : @native.TextSessionTarget,
) -> WindowsTextOwner {
  { ..owner, sequence: target.sequence, }
}

///|
fn windows_start_composition(
  owner : WindowsTextOwner,
  field : @text_field.TextField,
  replacement : @text.TextRange,
) -> WindowsTextOwner? {
  if !field.is_focused() ||
    field.is_composing() ||
    !replacement_target_matches(field, replacement) {
    None
  } else {
    Some({
      ..owner,
      composition: Some({ original: field, replacement_range: replacement, }),
    })
  }
}

///|
fn windows_append_result(
  owner : WindowsTextOwner,
  field : @text_field.TextField,
  text : String,
  replacement : @text.TextRange,
  measure_fn : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    @text_field.TextFieldError,
  ],
  admit_fn : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    @text_field.TextFieldError,
  ],
) -> Result[
  (WindowsTextOwner, @text_field.TextField),
  @text_field.TextFieldError,
] {
  match owner.composition {
    None =>
      if !replacement_target_matches(field, replacement) {
        Err(@text_field.InvalidSelection)
      } else {
        match field.replace_selection(text, measure_fn, admit_fn) {
          Ok(value) => Ok((owner, value))
          Err(error) => Err(error)
        }
      }
    Some(transaction) => {
      if transaction.replacement_range != replacement {
        return Err(@text_field.InvalidSelection)
      }
      match transaction.original.replace_selection(text, measure_fn, admit_fn) {
        Err(error) => Err(error)
        Ok(value) => Ok(({ ..owner, composition: None, }, value))
      }
    }
  }
}

///|
fn windows_update_mark(
  owner : WindowsTextOwner,
  text : String,
  cursor_utf16 : Int?,
  attributes : Array[Int],
  replacement : @text.TextRange,
  measure_fn : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    @text_field.TextFieldError,
  ],
  admit_fn : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    @text_field.TextFieldError,
  ],
) -> Result[
  (@text_field.TextField, WindowsTextOwner),
  @text_field.TextFieldError,
] {
  let transaction = match owner.composition {
    Some(value) if value.replacement_range == replacement => value
    _ => return Err(@text_field.InvalidSelection)
  }
  // IMM32 reports one attribute byte per UTF-16 unit when attributes are
  // available. This sample draws one full-span underline, so reject malformed
  // or unknown attribute maps rather than claiming clause fidelity.
  let mark_document = match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => return Err(@text_field.MalformedText)
  }
  if attributes.length() != 0 &&
    attributes.length() != mark_document.utf16_length() {
    return Err(@text_field.InvalidSelection)
  }
  for attribute in attributes {
    if attribute < 0 || attribute > 5 {
      return Err(@text_field.InvalidSelection)
    }
  }
  let cursor = match cursor_utf16 {
    Some(value) => value
    None if mark_document.utf16_length() == 0 => 0
    None => return Err(@text_field.InvalidSelection)
  }
  if cursor < 0 || cursor > mark_document.utf16_length() {
    return Err(@text_field.InvalidSelection)
  }
  let selection = match @text.TextSelection::new(cursor, cursor) {
    Ok(value) => value
    Err(_) => return Err(@text_field.InvalidSelection)
  }
  // Validate the complete preview and caret as UTF-16 document positions.
  match mark_document.with_selection(selection) {
    Err(_) => return Err(@text_field.InvalidSelection)
    Ok(_) => ()
  }
  match
    windows_preview_transaction(
      transaction.original,
      text,
      cursor,
      measure_fn,
      admit_fn,
    ) {
    Err(error) => Err(error)
    Ok(field) => Ok((field, owner))
  }
}

///|
fn windows_preview_transaction(
  original : @text_field.TextField,
  text : String,
  cursor_utf16 : Int,
  measure_fn : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    @text_field.TextFieldError,
  ],
  admit_fn : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    @text_field.TextFieldError,
  ],
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let selection = match @text.TextSelection::new(cursor_utf16, cursor_utf16) {
    Ok(value) => value
    Err(_) => return Err(@text_field.InvalidSelection)
  }
  original.update_composition(text, selection, measure_fn, admit_fn)
}

///|
fn windows_end_composition(
  owner : WindowsTextOwner,
) -> Result[
  (@text_field.TextField?, WindowsTextOwner),
  @text_field.TextFieldError,
] {
  match owner.composition {
    None => Ok((None, owner))
    Some(transaction) =>
      // Inserted results are accepted before a later preedit is started. End
      // therefore only discards this unconfirmed preview transaction.
      Ok((Some(transaction.original), { ..owner, composition: None, }))
  }
}

///|
fn windows_cancel_composition(
  owner : WindowsTextOwner,
) -> Result[
  (@text_field.TextField?, WindowsTextOwner),
  @text_field.TextFieldError,
] {
  match owner.composition {
    None => Ok((None, owner))
    Some(transaction) =>
      Ok((Some(transaction.original), { ..owner, composition: None, }))
  }
}

///|
fn windows_restore_owner_snapshot(
  owner : WindowsTextOwner?,
  field : @text_field.TextField,
  measure_fn : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    @text_field.TextFieldError,
  ],
  admit_fn : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    @text_field.TextFieldError,
  ],
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let snapshot = match owner {
    Some(active) =>
      match active.composition {
        Some(transaction) => transaction.original
        None => field
      }
    None => field
  }
  let resolved = if owner is None && field.is_composing() {
    match field.cancel_composition(measure_fn, admit_fn) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    snapshot
  }
  match resolved.with_bounds(field.bounds()) {
    Ok(value) => value.with_focus(field.is_focused())
    Err(error) => Err(error)
  }
}

///|
