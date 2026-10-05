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
/// Add one scalar's UTF-8 width without overflowing an Int byte count.
fn checked_utf8_length_add(total : Int, width : Int) -> Result[Int, TextError] {
  if total < 0 || width < 1 || width > 4 {
    return Err(LengthOverflow)
  }
  if width > @int.MAX_VALUE - total {
    Err(LengthOverflow)
  } else {
    Ok(total + width)
  }
}

///|
fn utf8_scalar_width(scalar : Int) -> Int {
  if scalar <= 0x7F {
    1
  } else if scalar <= 0x7FF {
    2
  } else if scalar <= 0xFFFF {
    3
  } else {
    4
  }
}

///|
fn utf16_scalar_width(scalar : Int) -> Int {
  if scalar <= 0xFFFF {
    1
  } else {
    2
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
/// Return the UTF-8 byte length, or LengthOverflow when it cannot fit in Int.
/// This scans Unicode scalars in O(n) time and does not allocate a UTF-8 copy.
pub fn TextDocument::utf8_length(self : TextDocument) -> Result[Int, TextError] {
  let mut length = 0
  // Documents contain well-formed UTF-16, so safe string iteration yields
  // Unicode scalar values and these widths are defined for every item.
  for scalar in self.text.iter() {
    length = match
      checked_utf8_length_add(length, utf8_scalar_width(scalar.to_int())) {
      Err(error) => return Err(error)
      Ok(next) => next
    }
  }
  Ok(length)
}

///|
/// Convert a UTF-16 code-unit offset to the equivalent UTF-8 byte offset.
/// A negative offset returns NegativeOffset. An offset past the UTF-16 length
/// returns OutOfBounds before scanning. Scalar interiors return SplitSurrogate,
/// unless the complete UTF-8 length overflows Int, which returns LengthOverflow
/// first. Each call scans the document in O(n) time; no offset table is cached.
pub fn TextDocument::utf8_offset(
  self : TextDocument,
  utf16_offset : Int,
) -> Result[Int, TextError] {
  if utf16_offset < 0 {
    return Err(NegativeOffset)
  }
  if utf16_offset > self.utf16_length() {
    return Err(OutOfBounds)
  }

  let mut current_utf16 = 0
  let mut current_utf8 = 0
  let mut mapped : Int? = None
  let mut splits_surrogate = false
  // Scalar iteration consumes exactly the document's UTF-16 units, so this
  // counter never exceeds the already-representable String::length().
  for scalar in self.text.iter() {
    if utf16_offset == current_utf16 {
      mapped = Some(current_utf8)
    }
    let scalar_value = scalar.to_int()
    let utf16_width = utf16_scalar_width(scalar_value)
    if utf16_width == 2 && utf16_offset == current_utf16 + 1 {
      splits_surrogate = true
    }
    current_utf16 += utf16_width
    current_utf8 = match
      checked_utf8_length_add(current_utf8, utf8_scalar_width(scalar_value)) {
      Err(error) => return Err(error)
      Ok(next) => next
    }
  }
  if utf16_offset == current_utf16 {
    mapped = Some(current_utf8)
  }
  match mapped {
    Some(byte_offset) => Ok(byte_offset)
    None if splits_surrogate => Err(SplitSurrogate)
    None => Err(OutOfBounds)
  }
}

///|
/// Convert a UTF-8 byte offset to the equivalent UTF-16 code-unit offset.
/// A negative offset returns NegativeOffset. Byte positions inside a scalar
/// return SplitUtf8; offsets past the UTF-8 length return OutOfBounds. If the
/// complete UTF-8 length overflows Int, LengthOverflow takes precedence over
/// those two errors. Each call scans the document in O(n) time; no offset table
/// is cached.
pub fn TextDocument::utf16_offset(
  self : TextDocument,
  utf8_offset : Int,
) -> Result[Int, TextError] {
  if utf8_offset < 0 {
    return Err(NegativeOffset)
  }

  let mut current_utf16 = 0
  let mut current_utf8 = 0
  let mut mapped : Int? = None
  let mut splits_scalar = false
  // Scalar iteration consumes exactly the document's UTF-16 units, so this
  // counter never exceeds the already-representable String::length().
  for scalar in self.text.iter() {
    if utf8_offset == current_utf8 {
      mapped = Some(current_utf16)
    }
    let scalar_value = scalar.to_int()
    let utf8_width = utf8_scalar_width(scalar_value)
    let next_utf8 = match checked_utf8_length_add(current_utf8, utf8_width) {
      Err(error) => return Err(error)
      Ok(next) => next
    }
    if utf8_offset > current_utf8 && utf8_offset < next_utf8 {
      splits_scalar = true
    }
    current_utf8 = next_utf8
    current_utf16 += utf16_scalar_width(scalar_value)
  }
  if utf8_offset == current_utf8 {
    mapped = Some(current_utf16)
  }
  if utf8_offset > current_utf8 {
    return Err(OutOfBounds)
  }
  match mapped {
    Some(utf16_value) => Ok(utf16_value)
    None if splits_scalar => Err(SplitUtf8)
    None => Err(OutOfBounds)
  }
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
