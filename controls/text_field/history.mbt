///|
/// One admitted content edit. The documents retain their directional
/// selections, while layout and presentation state stay with the field.
priv struct FieldHistoryEntry {
  before : @text.TextDocument
  after : @text.TextDocument
}

///|
/// Immutable bounded history. These arrays are never returned, and every
/// transition that changes a stack first makes detached copies.
priv struct FieldHistory {
  undo : Array[FieldHistoryEntry]
  redo : Array[FieldHistoryEntry]
  payload_bytes : Int
}

///|
const MAX_FIELD_HISTORY_ENTRIES : Int = 64

///|
const MAX_FIELD_HISTORY_PAYLOAD_BYTES : Int = 65536

///|
fn FieldHistory::empty() -> FieldHistory {
  { undo: [], redo: [], payload_bytes: 0, }
}

///|
fn FieldHistory::can_undo(self : FieldHistory) -> Bool {
  self.undo.length() > 0
}

///|
fn FieldHistory::can_redo(self : FieldHistory) -> Bool {
  self.redo.length() > 0
}

///|
fn FieldHistory::undo_entry(self : FieldHistory) -> FieldHistoryEntry? {
  if self.undo.length() == 0 {
    None
  } else {
    Some(self.undo[self.undo.length() - 1])
  }
}

///|
fn FieldHistory::redo_entry(self : FieldHistory) -> FieldHistoryEntry? {
  if self.redo.length() == 0 {
    None
  } else {
    Some(self.redo[self.redo.length() - 1])
  }
}

///|
fn field_history_entry_payload_bytes(
  entry : FieldHistoryEntry,
) -> Result[Int, TextFieldError] {
  let before_bytes = match entry.before.utf8_length() {
    Ok(value) if value <= MAX_FIELD_UTF8_BYTES => value
    _ => return Err(TextTooLarge)
  }
  let after_bytes = match entry.after.utf8_length() {
    Ok(value) if value <= MAX_FIELD_UTF8_BYTES => value
    _ => return Err(TextTooLarge)
  }
  // The document limit keeps each operand small, but still check before
  // adding so this remains safe if either limit changes later.
  if after_bytes > MAX_FIELD_HISTORY_PAYLOAD_BYTES - before_bytes {
    return Err(TextTooLarge)
  }
  Ok(before_bytes + after_bytes)
}

///|
fn field_history_undo_payload_bytes(
  entries : Array[FieldHistoryEntry],
) -> Result[Int, TextFieldError] {
  let mut total = 0
  for entry in entries {
    let entry_bytes = match field_history_entry_payload_bytes(entry) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if total > MAX_FIELD_HISTORY_PAYLOAD_BYTES ||
      entry_bytes > MAX_FIELD_HISTORY_PAYLOAD_BYTES - total {
      return Err(TextTooLarge)
    }
    total += entry_bytes
  }
  Ok(total)
}

///|
fn FieldHistory::move_undo(self : FieldHistory) -> FieldHistory {
  let undo_count = self.undo.length()
  let redo_count = self.redo.length()
  if undo_count == 0 ||
    undo_count > MAX_FIELD_HISTORY_ENTRIES ||
    redo_count > MAX_FIELD_HISTORY_ENTRIES ||
    undo_count > MAX_FIELD_HISTORY_ENTRIES - redo_count ||
    redo_count >= MAX_FIELD_HISTORY_ENTRIES {
    return self
  }
  let undo = self.undo.copy()
  let redo = self.redo.copy()
  let entry = undo.remove(undo.length() - 1)
  redo.push(entry)
  { undo, redo, payload_bytes: self.payload_bytes, }
}

///|
fn FieldHistory::move_redo(self : FieldHistory) -> FieldHistory {
  let undo_count = self.undo.length()
  let redo_count = self.redo.length()
  if redo_count == 0 ||
    undo_count > MAX_FIELD_HISTORY_ENTRIES ||
    redo_count > MAX_FIELD_HISTORY_ENTRIES ||
    undo_count > MAX_FIELD_HISTORY_ENTRIES - redo_count ||
    undo_count >= MAX_FIELD_HISTORY_ENTRIES {
    return self
  }
  let undo = self.undo.copy()
  let redo = self.redo.copy()
  let entry = redo.remove(redo.length() - 1)
  undo.push(entry)
  { undo, redo, payload_bytes: self.payload_bytes, }
}

///|
/// Record a successful content change. Equal text is a selection-only
/// transition, so it intentionally retains both stacks and their snapshots.
fn FieldHistory::record(
  self : FieldHistory,
  before : @text.TextDocument,
  after : @text.TextDocument,
) -> Result[FieldHistory, TextFieldError] {
  match validate_field_text(before) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_field_text(after) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if before.text() == after.text() {
    return Ok(self)
  }
  let entry = { before, after, }
  let entry_bytes = match field_history_entry_payload_bytes(entry) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if entry_bytes > MAX_FIELD_HISTORY_PAYLOAD_BYTES {
    return Err(TextTooLarge)
  }

  // A new edit invalidates redo. Recompute retained undo charge before
  // deciding the exact number of whole oldest entries to evict.
  let retained_bytes = match field_history_undo_payload_bytes(self.undo) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut kept_count = self.undo.length()
  let mut kept_bytes = retained_bytes
  let mut first_kept = 0
  while kept_count > 0 &&
        (
          kept_count >= MAX_FIELD_HISTORY_ENTRIES ||
          entry_bytes > MAX_FIELD_HISTORY_PAYLOAD_BYTES - kept_bytes
        ) {
    let oldest_bytes = match
      field_history_entry_payload_bytes(self.undo[first_kept]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if oldest_bytes > kept_bytes {
      return Err(TextTooLarge)
    }
    kept_bytes -= oldest_bytes
    kept_count -= 1
    first_kept += 1
  }
  if kept_count >= MAX_FIELD_HISTORY_ENTRIES ||
    entry_bytes > MAX_FIELD_HISTORY_PAYLOAD_BYTES - kept_bytes {
    return Err(TextTooLarge)
  }

  // All count and byte checks precede array growth. Build an independent
  // stack so previously returned snapshots remain unchanged.
  let undo = []
  for index in first_kept..<self.undo.length() {
    undo.push(self.undo[index])
  }
  undo.push(entry)
  Ok({ undo, redo: [], payload_bytes: kept_bytes + entry_bytes, })
}
