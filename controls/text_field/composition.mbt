///|
/// The composition owns an immutable original editing snapshot. Its original
/// geometry was admitted under this field's immutable font style; bounds
/// changes must validate both the preview and this saved geometry. Ordinary
/// editing is rejected until the owner explicitly commits or cancels.
priv struct FieldComposition {
  transaction : @text.TextComposition
  original : @text.TextDocument
  measurement : @text_layout.TextMeasurement
  history : FieldHistory
  scroll_offset : Double
  preview_visible : Bool
}

///|
fn field_composition_error(error : @text.CompositionError) -> TextFieldError {
  match error {
    @text.NotActive => NoComposition
    @text.InvalidText(@text.MalformedUtf16) => MalformedText
    @text.InvalidText(@text.LengthOverflow) => TextTooLarge
    @text.InvalidText(_) => InvalidSelection
  }
}

///|
fn begin_field_composition(
  field : TextField,
) -> Result[FieldComposition, TextFieldError] {
  let transaction = match
    @text.TextComposition::begin(
      field.document,
      field.document.selection().normalized_range(),
    ) {
    Ok(value) => value
    Err(error) => return Err(field_composition_error(error))
  }
  Ok({
    transaction,
    original: field.document,
    measurement: field.measurement,
    history: field.history,
    scroll_offset: field.scroll_offset,
    preview_visible: false,
  })
}

///|
/// Validate a whole document before asking a provider to allocate its layout.
/// Selection must remain an exact reported cursor stop; composition never
/// snaps an IME endpoint to another position.
fn prepare_composition_document(
  field : TextField,
  document : @text.TextDocument,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  match validate_field_text(document) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let measurement = match measure(document) {
    Ok(value) => value
    Err(_) => return Err(MeasurementFailed)
  }
  prepare_field_document(field, document, measurement, admit)
}

///|
/// Whether this value owns an unfinished composition, including a hidden
/// preview after an empty preedit. Hosts still own native event epochs.
pub fn TextField::is_composing(self : TextField) -> Bool {
  self.composition is Some(_)
}

///|
/// The visible preedit span in document-relative UTF-16 code units. A cleared
/// preedit has no marked span, while its original replacement remains owned.
pub fn TextField::marked_range(self : TextField) -> @text.TextRange? {
  match self.composition {
    Some(state) if state.preview_visible => state.transaction.marked_range()
    _ => None
  }
}

///|
/// Start on the first nonempty preedit over the current normalized selection,
/// or update the same original replacement range. The relative directional
/// selection is in UTF-16 code units. Every preview is measured and raster
/// admitted as a complete candidate, without recording history. Empty preedit
/// restores the original display and selection but retains the transaction;
/// it never commits a deletion. Unfocused fields ignore composition input.
pub fn TextField::update_composition(
  self : TextField,
  preedit : String,
  selection : @text.TextSelection,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  if !self.focused {
    return Ok(self)
  }
  let preedit_document = match @text.TextDocument::new(preedit) {
    Ok(value) => value
    Err(_) => return Err(MalformedText)
  }
  match preedit_document.with_selection(selection) {
    Ok(_) => ()
    Err(_) => return Err(InvalidSelection)
  }
  match validate_field_text(preedit_document) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state = match self.composition {
    Some(value) => value
    None if preedit.length() == 0 => return Ok(self)
    None =>
      match begin_field_composition(self) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  if preedit.length() == 0 {
    let candidate = match
      prepare_composition_document(self, state.original, measure, admit) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    // Reset the value-model preview as well, without dropping its original
    // selected range. A later nonempty update or commit uses that same range.
    let transaction = match
      @text.TextComposition::begin(
        state.original,
        state.original.selection().normalized_range(),
      ) {
      Ok(value) => value
      Err(error) => return Err(field_composition_error(error))
    }
    let candidate = {
      ..candidate,
      history: state.history,
      composition: Some({ ..state, transaction, preview_visible: false, }),
      scroll_offset: state.scroll_offset,
    }
    return Ok({
      ..candidate,
      scroll_offset: field_scroll_for_head(
        candidate,
        state.original.selection().head(),
      ),
    })
  }
  let transaction = match state.transaction.update(preedit, selection) {
    Ok(value) => value
    Err(error) => return Err(field_composition_error(error))
  }
  let candidate = match
    prepare_composition_document(self, transaction.document(), measure, admit) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..candidate,
    history: state.history,
    composition: Some({ ..state, transaction, preview_visible: true, }),
  })
}

///|
/// Strict UTF-8 byte endpoint adapter for platform preedit. Negative, scalar-
/// interior and out-of-bounds byte offsets are rejected before measurement.
/// The resulting UTF-16 selection must also be an exact layout cursor stop.
pub fn TextField::update_composition_utf8(
  self : TextField,
  preedit : String,
  anchor_bytes : Int,
  head_bytes : Int,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  if !self.focused {
    return Ok(self)
  }
  let document = match @text.TextDocument::new(preedit) {
    Ok(value) => value
    Err(_) => return Err(MalformedText)
  }
  match validate_field_text(document) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let anchor = match document.utf16_offset(anchor_bytes) {
    Ok(value) => value
    Err(@text.LengthOverflow) => return Err(TextTooLarge)
    Err(_) => return Err(InvalidSelection)
  }
  let head = match document.utf16_offset(head_bytes) {
    Ok(value) => value
    Err(@text.LengthOverflow) => return Err(TextTooLarge)
    Err(_) => return Err(InvalidSelection)
  }
  let selection = match @text.TextSelection::new(anchor, head) {
    Ok(value) => value
    Err(_) => return Err(InvalidSelection)
  }
  self.update_composition(preedit, selection, measure, admit)
}

///|
/// Replace the original selected range with final text exactly once. Empty
/// committed text deletes that range. The final caret is checked, never
/// snapped. The admitted original-to-final edit creates one undo entry; a
/// same-text commit remains selection-only and preserves existing redo.
pub fn TextField::commit_composition(
  self : TextField,
  text : String,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  if !self.focused {
    return Ok(self)
  }
  let state = match self.composition {
    Some(value) => value
    None => return Err(NoComposition)
  }
  let inserted = match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => return Err(MalformedText)
  }
  match validate_field_text(inserted) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let transaction = match state.transaction.commit(text) {
    Ok(value) => value
    Err(error) => return Err(field_composition_error(error))
  }
  let document = transaction.document()
  let history = match state.history.record(state.original, document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = match
    prepare_composition_document(self, document, measure, admit) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ ..candidate, history, composition: None, })
}

///|
/// Cancel without recording an edit, restoring the exact original directional
/// selection and both history stacks. Explicit cancellation remeasures and
/// readmits under current bounds; failure retains the complete composition.
pub fn TextField::cancel_composition(
  self : TextField,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  let state = match self.composition {
    Some(value) => value
    None => return Ok(self)
  }
  let candidate = match
    prepare_composition_document(self, state.original, measure, admit) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = {
    ..candidate,
    history: state.history,
    composition: None,
    scroll_offset: state.scroll_offset,
  }
  Ok({
    ..candidate,
    scroll_offset: field_scroll_for_head(
      candidate,
      state.original.selection().head(),
    ),
  })
}

///|
/// Focus loss cannot call a provider. Restore the already-admitted original
/// snapshot under the same immutable style. with_bounds validates this saved
/// geometry before allowing a resize, so blur cannot install stale geometry.
fn blur_field_composition(
  field : TextField,
) -> Result[TextField, TextFieldError] {
  let state = match field.composition {
    Some(value) => value
    None => return field_changed_selection(field, field.document, false)
  }
  match
    validate_field_measurement(
      state.original,
      state.measurement,
      true,
      rect_height(field_content_bounds(field.bounds)),
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let revision = match bump_field_revision(field.revision) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = {
    ..field,
    document: state.original,
    measurement: state.measurement,
    history: state.history,
    scroll_offset: state.scroll_offset,
    composition: None,
    focused: false,
    revision,
  }
  Ok({
    ..candidate,
    scroll_offset: field_scroll_for_head(
      candidate,
      state.original.selection().head(),
    ),
  })
}
