///|
/// State of an immutable text-composition value.
pub enum CompositionStatus {
  Active
  Committed
  Cancelled
} derive(Eq)

///|
pub extend CompositionStatus with Eq::{not_equal, equal}

///|
/// Errors returned by the portable composition value model.
pub enum CompositionError {
  NotActive
  InvalidText(TextError)
} derive(Eq)

///|
pub extend CompositionError with Eq::{not_equal, equal}

///|
/// An immutable composition transaction over an original document and range.
/// Hosts own sequencing and must reject stale or cross-owner input events.
pub struct TextComposition {
  priv original : TextDocument
  priv original_range : TextRange
  priv document : TextDocument
  priv status : CompositionStatus
  priv marked_range : TextRange?
}

///|
/// Begin composing over a validated UTF-16 range without changing the
/// document or its directional selection.
pub fn TextComposition::begin(
  document : TextDocument,
  range : TextRange,
) -> Result[TextComposition, CompositionError] {
  match validate_document_range(document.text(), range) {
    Err(error) => Err(InvalidText(error))
    Ok(_) =>
      Ok({
        original: document,
        original_range: range,
        document,
        status: Active,
        marked_range: Some(range),
      })
  }
}

///|
/// Return the current immutable document value.
pub fn TextComposition::document(self : TextComposition) -> TextDocument {
  self.document
}

///|
/// Return the transaction status.
pub fn TextComposition::status(self : TextComposition) -> CompositionStatus {
  self.status
}

///|
/// Return the current marked range, including an empty range while active.
pub fn TextComposition::marked_range(self : TextComposition) -> TextRange? {
  self.marked_range
}

///|
/// Replace the original range with a preview and map its relative UTF-16
/// selection into the resulting document. Earlier snapshots remain values.
pub fn TextComposition::update(
  self : TextComposition,
  preedit : String,
  selection : TextSelection,
) -> Result[TextComposition, CompositionError] {
  match self.status {
    Active => ()
    Committed | Cancelled => return Err(NotActive)
  }
  match validate_well_formed_string(preedit) {
    Err(error) => return Err(InvalidText(error))
    Ok(_) => ()
  }
  match validate_document_selection(preedit, selection) {
    Err(error) => return Err(InvalidText(error))
    Ok(_) => ()
  }

  let preedit_length = preedit.length()
  match
    checked_resulting_length(
      self.original.utf16_length(),
      self.original_range.length(),
      preedit_length,
    ) {
    Err(error) => return Err(InvalidText(error))
    Ok(_) => ()
  }
  let preview = match self.original.replace(self.original_range, preedit) {
    Err(error) => return Err(InvalidText(error))
    Ok(value) => value
  }

  // The replacement length was checked above. Its prefix is exactly
  // original_range.start, and both relative endpoints are at most
  // preedit_length, so each sum below is within the validated result length
  // and cannot overflow Int.
  let absolute_anchor = self.original_range.start() + selection.anchor()
  let absolute_head = self.original_range.start() + selection.head()
  let absolute_selection = match
    TextSelection::new(absolute_anchor, absolute_head) {
    Err(error) => return Err(InvalidText(error))
    Ok(value) => value
  }
  let preview = match preview.with_selection(absolute_selection) {
    Err(error) => return Err(InvalidText(error))
    Ok(value) => value
  }
  let marked_end = self.original_range.start() + preedit_length
  let marked_range = match
    TextRange::new(self.original_range.start(), marked_end) {
    Err(error) => return Err(InvalidText(error))
    Ok(value) => value
  }
  Ok({
    original: self.original,
    original_range: self.original_range,
    document: preview,
    status: Active,
    marked_range: Some(marked_range),
  })
}

///|
/// Replace the original range with final text and collapse the selection
/// after it.
pub fn TextComposition::commit(
  self : TextComposition,
  text : String,
) -> Result[TextComposition, CompositionError] {
  match self.status {
    Active => ()
    Committed | Cancelled => return Err(NotActive)
  }
  let document = match self.original.replace(self.original_range, text) {
    Err(error) => return Err(InvalidText(error))
    Ok(value) => value
  }
  Ok({
    original: self.original,
    original_range: self.original_range,
    document,
    status: Committed,
    marked_range: None,
  })
}

///|
/// Cancel the transaction and restore the exact original text and selection.
pub fn TextComposition::cancel(
  self : TextComposition,
) -> Result[TextComposition, CompositionError] {
  match self.status {
    Active => ()
    Committed | Cancelled => return Err(NotActive)
  }
  Ok({
    original: self.original,
    original_range: self.original_range,
    document: self.original,
    status: Cancelled,
    marked_range: None,
  })
}
