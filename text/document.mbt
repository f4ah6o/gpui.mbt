///|
/// Immutable text and its directional selection. Offsets are UTF-16 code
/// units. This foundation does not implement grapheme navigation, composition,
/// shaping, rendering, clipboard, undo, or platform input.
pub struct TextDocument {
  text : String
  selection : TextSelection
} derive(Eq)

///|
pub extend TextDocument with Eq::{not_equal, equal}

///|
/// Check UTF-16 code units for well-formed surrogate pairing.
fn validate_utf16_units(units : ArrayView[UInt16]) -> Result[Unit, TextError] {
  let mut expects_low_surrogate = false
  for unit in units {
    let value = unit.to_int()
    if expects_low_surrogate {
      if is_low_surrogate(value) {
        expects_low_surrogate = false
      } else {
        return Err(MalformedUtf16)
      }
    } else if is_high_surrogate(value) {
      expects_low_surrogate = true
    } else if is_low_surrogate(value) {
      return Err(MalformedUtf16)
    }
  }
  if expects_low_surrogate {
    Err(MalformedUtf16)
  } else {
    Ok(())
  }
}

///|
fn is_high_surrogate(value : Int) -> Bool {
  value >= 0xD800 && value <= 0xDBFF
}

///|
fn is_low_surrogate(value : Int) -> Bool {
  value >= 0xDC00 && value <= 0xDFFF
}

///|
fn validate_well_formed_string(text : String) -> Result[Unit, TextError] {
  validate_utf16_units(text.code_units())
}

///|
fn splits_surrogate_pair(units : ArrayView[UInt16], offset : Int) -> Bool {
  if offset <= 0 || offset >= units.length() {
    return false
  }
  match (units.get(offset - 1), units.get(offset)) {
    (Some(previous), Some(next)) =>
      is_high_surrogate(previous.to_int()) && is_low_surrogate(next.to_int())
    _ => false
  }
}

///|
fn validate_document_range(
  text : String,
  range : TextRange,
) -> Result[Unit, TextError] {
  if range.start < 0 || range.end < 0 {
    return Err(NegativeOffset)
  }
  if range.start > range.end {
    return Err(ReversedRange)
  }
  let length = text.length()
  if range.start > length || range.end > length {
    return Err(OutOfBounds)
  }
  let units = text.code_units()
  if splits_surrogate_pair(units, range.start) ||
    splits_surrogate_pair(units, range.end) {
    Err(SplitSurrogate)
  } else {
    Ok(())
  }
}

///|
fn validate_document_selection(
  text : String,
  selection : TextSelection,
) -> Result[Unit, TextError] {
  if selection.anchor < 0 || selection.head < 0 {
    return Err(NegativeOffset)
  }
  let length = text.length()
  if selection.anchor > length || selection.head > length {
    return Err(OutOfBounds)
  }
  let units = text.code_units()
  if splits_surrogate_pair(units, selection.anchor) ||
    splits_surrogate_pair(units, selection.head) {
    Err(SplitSurrogate)
  } else {
    Ok(())
  }
}

///|
fn checked_resulting_length(
  old_length : Int,
  removed_length : Int,
  inserted_length : Int,
) -> Result[Int, TextError] {
  if old_length < 0 || removed_length < 0 || inserted_length < 0 {
    return Err(LengthOverflow)
  }
  if removed_length > old_length {
    return Err(OutOfBounds)
  }
  let retained_length = old_length - removed_length
  if inserted_length > @int.MAX_VALUE - retained_length {
    Err(LengthOverflow)
  } else {
    Ok(retained_length + inserted_length)
  }
}

///|
fn validated_view_to_string(text : String, start : Int, end : Int) -> String {
  match text.get_view(start~, end~) {
    Some(view) => view.to_owned()
    None => abort("validated text range lost its UTF-16 boundary")
  }
}

///|
/// Construct a well-formed immutable document with a collapsed selection at
/// the start.
pub fn TextDocument::new(text : String) -> Result[TextDocument, TextError] {
  match validate_well_formed_string(text) {
    Err(error) => Err(error)
    Ok(_) =>
      match TextSelection::new(0, 0) {
        Ok(selection) => Ok({ text, selection, })
        Err(error) => Err(error)
      }
  }
}

///|
/// Return the immutable string value held by this document.
pub fn TextDocument::text(self : TextDocument) -> String {
  self.text
}

///|
pub fn TextDocument::utf16_length(self : TextDocument) -> Int {
  self.text.length()
}

///|
pub fn TextDocument::selection(self : TextDocument) -> TextSelection {
  self.selection
}

///|
/// Return a document with the same text and the validated directional
/// selection.
pub fn TextDocument::with_selection(
  self : TextDocument,
  selection : TextSelection,
) -> Result[TextDocument, TextError] {
  match validate_document_selection(self.text, selection) {
    Err(error) => Err(error)
    Ok(_) => Ok({ text: self.text, selection, })
  }
}

///|
/// Copy the exact half-open UTF-16 range after validating its bounds and
/// surrogate boundaries.
pub fn TextDocument::slice(
  self : TextDocument,
  range : TextRange,
) -> Result[String, TextError] {
  match validate_document_range(self.text, range) {
    Err(error) => Err(error)
    Ok(_) => Ok(validated_view_to_string(self.text, range.start, range.end))
  }
}

///|
/// Return the text in the normalized selected range.
pub fn TextDocument::selected_text(self : TextDocument) -> String {
  let range = self.selection.normalized_range()
  validated_view_to_string(self.text, range.start, range.end)
}

///|
/// Return a new document with a validated range replaced by well-formed text.
/// The old document remains unchanged and the new selection collapses after
/// the inserted UTF-16 code units.
pub fn TextDocument::replace(
  self : TextDocument,
  range : TextRange,
  replacement : String,
) -> Result[TextDocument, TextError] {
  match validate_document_range(self.text, range) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_well_formed_string(replacement) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let replacement_length = replacement.length()
  match
    checked_resulting_length(
      self.text.length(),
      range.length(),
      replacement_length,
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let builder = StringBuilder()
  match self.text.get_view(start=0, end=range.start) {
    Some(prefix) => builder.write_stringview(prefix)
    None => abort("validated text prefix lost its UTF-16 boundary")
  }
  builder.write_string(replacement)
  match self.text.get_view(start=range.end, end=self.text.length()) {
    Some(suffix) => builder.write_stringview(suffix)
    None => abort("validated text suffix lost its UTF-16 boundary")
  }
  let text = builder.to_string()
  let caret = range.start + replacement_length
  match TextSelection::new(caret, caret) {
    Ok(selection) => Ok({ text, selection, })
    Err(error) => Err(error)
  }
}

///|
/// Replace the current normalized selection and collapse the new selection
/// after the inserted text.
pub fn TextDocument::replace_selection(
  self : TextDocument,
  replacement : String,
) -> Result[TextDocument, TextError] {
  self.replace(self.selection.normalized_range(), replacement)
}
