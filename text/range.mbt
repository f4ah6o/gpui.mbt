///|
/// Errors from the portable UTF-16 text model.
pub enum TextError {
  NegativeOffset
  ReversedRange
  OutOfBounds
  SplitSurrogate
  MalformedUtf16
  LengthOverflow
} derive(Eq)

///|
pub extend TextError with Eq::{not_equal, equal}

///|
/// A half-open range measured in UTF-16 code units.
pub struct TextRange {
  start : Int
  end : Int
} derive(Eq)

///|
pub extend TextRange with Eq::{not_equal, equal}

///|
/// Construct a non-negative, ordered UTF-16 range.
pub fn TextRange::new(start : Int, end : Int) -> Result[TextRange, TextError] {
  if start < 0 || end < 0 {
    Err(NegativeOffset)
  } else if start > end {
    Err(ReversedRange)
  } else {
    Ok({ start, end, })
  }
}

///|
pub fn TextRange::start(self : TextRange) -> Int {
  self.start
}

///|
pub fn TextRange::end(self : TextRange) -> Int {
  self.end
}

///|
pub fn TextRange::length(self : TextRange) -> Int {
  self.end - self.start
}

///|
/// A directional selection stored as anchor and head UTF-16 offsets.
/// The endpoints retain their direction; `normalized_range` is for operations
/// that work with the selected extent.
pub struct TextSelection {
  anchor : Int
  head : Int
} derive(Eq)

///|
pub extend TextSelection with Eq::{not_equal, equal}

///|
/// Construct a directional selection with non-negative endpoints.
pub fn TextSelection::new(
  anchor : Int,
  head : Int,
) -> Result[TextSelection, TextError] {
  if anchor < 0 || head < 0 {
    Err(NegativeOffset)
  } else {
    Ok({ anchor, head, })
  }
}

///|
pub fn TextSelection::anchor(self : TextSelection) -> Int {
  self.anchor
}

///|
pub fn TextSelection::head(self : TextSelection) -> Int {
  self.head
}

///|
pub fn TextSelection::normalized_range(self : TextSelection) -> TextRange {
  if self.anchor <= self.head {
    { start: self.anchor, end: self.head, }
  } else {
    { start: self.head, end: self.anchor, }
  }
}

///|
pub fn TextSelection::is_collapsed(self : TextSelection) -> Bool {
  self.anchor == self.head
}
