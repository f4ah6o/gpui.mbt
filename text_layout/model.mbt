///|
/// Errors from constructing portable text-measurement and hit-test values.
pub enum TextLayoutError {
  InvalidMetrics
  InvalidBaseline
  InvalidLineCount
  InvalidUnknownGlyphCount
  InvalidCaretOffset
  MissingCaret
  ExtraCaret
  DuplicateCaret
  InvalidHitOffset
  InvalidTrailingScalarCount
  HitOffsetMismatch
} derive(Eq)

///|
pub extend TextLayoutError with Eq::{not_equal, equal}

///|
/// Copied strong and weak caret geometry at a scalar boundary in UTF-16 units.
/// A scalar boundary may be inside a grapheme and then `is_cursor_position`
/// is false. Bidi text may give strong/weak rectangles at different x values.
pub struct CaretGeometry {
  priv utf16_offset : Int
  priv is_cursor_position : Bool
  priv strong : @primitives.Rect
  priv weak : @primitives.Rect
}

///|
pub fn CaretGeometry::new(
  utf16_offset : Int,
  is_cursor_position : Bool,
  strong : @primitives.Rect,
  weak : @primitives.Rect,
) -> Result[CaretGeometry, TextLayoutError] {
  if utf16_offset < 0 {
    Err(InvalidCaretOffset)
  } else {
    Ok({ utf16_offset, is_cursor_position, strong, weak, })
  }
}

///|
pub fn CaretGeometry::utf16_offset(self : CaretGeometry) -> Int {
  self.utf16_offset
}

///|
pub fn CaretGeometry::is_cursor_position(self : CaretGeometry) -> Bool {
  self.is_cursor_position
}

///|
pub fn CaretGeometry::strong(self : CaretGeometry) -> @primitives.Rect {
  self.strong
}

///|
pub fn CaretGeometry::weak(self : CaretGeometry) -> @primitives.Rect {
  self.weak
}

///|
/// An immutable snapshot of one synchronous text measurement. The caret array
/// is copied on construction and on access; it contains every Unicode scalar
/// boundary in the document, including the end boundary.
pub struct TextMeasurement {
  priv document : @text.TextDocument
  priv logical_rect : @primitives.Rect
  priv ink_rect : @primitives.Rect
  priv first_line_baseline : Double
  priv line_count : Int
  priv unknown_glyph_count : Int
  priv carets : Array[CaretGeometry]
}

///|
fn finite_metric(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn scalar_utf16_width(scalar : Char) -> Int {
  if scalar.to_int() > 0xFFFF {
    2
  } else {
    1
  }
}

///|
fn expected_scalar_boundaries(document : @text.TextDocument) -> Array[Int] {
  let boundaries = [0]
  let mut offset = 0
  for scalar in document.text().iter() {
    offset += scalar_utf16_width(scalar)
    boundaries.push(offset)
  }
  boundaries
}

///|
fn boundary_index(boundaries : Array[Int], target : Int) -> Int? {
  if target < 0 {
    return None
  }
  let mut low = 0
  let mut high = boundaries.length() - 1
  while low <= high {
    let middle = low + (high - low) / 2
    let value = boundaries[middle]
    if value == target {
      return Some(middle)
    }
    if value < target {
      low = middle + 1
    } else {
      high = middle - 1
    }
  }
  None
}

///|
/// Copy and validate layout metrics and a complete, ordered caret table.
/// Rectangles are already finite and may have negative origins, including ink
/// overhangs. No x monotonicity or strong/weak equality is assumed.
pub fn TextMeasurement::new(
  document : @text.TextDocument,
  logical_rect : @primitives.Rect,
  ink_rect : @primitives.Rect,
  first_line_baseline : Double,
  line_count : Int,
  unknown_glyph_count : Int,
  carets : Array[CaretGeometry],
) -> Result[TextMeasurement, TextLayoutError] {
  if !finite_metric(first_line_baseline) {
    return Err(InvalidMetrics)
  }
  if first_line_baseline < 0.0 {
    return Err(InvalidBaseline)
  }
  if line_count < 1 {
    return Err(InvalidLineCount)
  }
  if unknown_glyph_count < 0 {
    return Err(InvalidUnknownGlyphCount)
  }

  let boundaries = expected_scalar_boundaries(document)
  if carets.length() < boundaries.length() {
    return Err(MissingCaret)
  }
  if carets.length() > boundaries.length() {
    return Err(ExtraCaret)
  }
  let copied_carets = carets.copy()
  for i = 0; i < copied_carets.length(); i = i + 1 {
    let caret = copied_carets[i]
    let expected = boundaries[i]
    if caret.utf16_offset != expected {
      if i > 0 && caret.utf16_offset == boundaries[i - 1] {
        return Err(DuplicateCaret)
      }
      match boundary_index(boundaries, caret.utf16_offset) {
        Some(_) => return Err(MissingCaret)
        None => return Err(InvalidCaretOffset)
      }
    }
  }
  Ok({
    document,
    logical_rect,
    ink_rect,
    first_line_baseline,
    line_count,
    unknown_glyph_count,
    carets: copied_carets,
  })
}

///|
pub fn TextMeasurement::document(self : TextMeasurement) -> @text.TextDocument {
  self.document
}

///|
pub fn TextMeasurement::logical_rect(
  self : TextMeasurement,
) -> @primitives.Rect {
  self.logical_rect
}

///|
pub fn TextMeasurement::ink_rect(self : TextMeasurement) -> @primitives.Rect {
  self.ink_rect
}

///|
pub fn TextMeasurement::first_line_baseline(self : TextMeasurement) -> Double {
  self.first_line_baseline
}

///|
pub fn TextMeasurement::line_count(self : TextMeasurement) -> Int {
  self.line_count
}

///|
pub fn TextMeasurement::unknown_glyph_count(self : TextMeasurement) -> Int {
  self.unknown_glyph_count
}

///|
/// Return an independent copy so callers cannot mutate this snapshot.
pub fn TextMeasurement::carets(self : TextMeasurement) -> Array[CaretGeometry] {
  self.carets.copy()
}

///|
/// Look up a scalar-boundary offset without clamping. Split-surrogate and
/// out-of-range UTF-16 offsets are both reported as InvalidHitOffset.
pub fn TextMeasurement::caret_at(
  self : TextMeasurement,
  utf16_offset : Int,
) -> Result[CaretGeometry, TextLayoutError] {
  if utf16_offset < 0 {
    return Err(InvalidHitOffset)
  }
  let mut low = 0
  let mut high = self.carets.length() - 1
  while low <= high {
    let middle = low + (high - low) / 2
    let caret = self.carets[middle]
    if caret.utf16_offset == utf16_offset {
      return Ok(caret)
    }
    if caret.utf16_offset < utf16_offset {
      low = middle + 1
    } else {
      high = middle - 1
    }
  }
  Err(InvalidHitOffset)
}

///|
/// A copied result of Pango-style XY hit testing. `trailing_scalars` counts
/// Unicode scalar values after `cluster_start_utf16`, not bytes or UTF-16
/// code units. Outside hits retain the backend's nearest valid position.
pub struct TextHit {
  priv document : @text.TextDocument
  priv cluster_start_utf16 : Int
  priv trailing_scalars : Int
  priv resolved_utf16_offset : Int
  priv inside : Bool
  priv resolved_is_cursor_position : Bool
}

///|
/// Validate both UTF-16 boundaries and the scalar-trailing relationship. The
/// boundary table is generated in one scalar pass; index lookup is logarithmic.
pub fn TextHit::new(
  document : @text.TextDocument,
  cluster_start_utf16 : Int,
  trailing_scalars : Int,
  resolved_utf16_offset : Int,
  inside : Bool,
  resolved_is_cursor_position : Bool,
) -> Result[TextHit, TextLayoutError] {
  if trailing_scalars < 0 {
    return Err(InvalidTrailingScalarCount)
  }
  let boundaries = expected_scalar_boundaries(document)
  let start_index = match boundary_index(boundaries, cluster_start_utf16) {
    Some(index) => index
    None => return Err(InvalidHitOffset)
  }
  let resolved_index = match boundary_index(boundaries, resolved_utf16_offset) {
    Some(index) => index
    None => return Err(InvalidHitOffset)
  }
  if trailing_scalars > boundaries.length() - 1 - start_index {
    return Err(InvalidTrailingScalarCount)
  }
  if start_index + trailing_scalars != resolved_index {
    return Err(HitOffsetMismatch)
  }
  Ok({
    document,
    cluster_start_utf16,
    trailing_scalars,
    resolved_utf16_offset,
    inside,
    resolved_is_cursor_position,
  })
}

///|
pub fn TextHit::document(self : TextHit) -> @text.TextDocument {
  self.document
}

///|
pub fn TextHit::cluster_start_utf16(self : TextHit) -> Int {
  self.cluster_start_utf16
}

///|
pub fn TextHit::trailing_scalars(self : TextHit) -> Int {
  self.trailing_scalars
}

///|
pub fn TextHit::resolved_utf16_offset(self : TextHit) -> Int {
  self.resolved_utf16_offset
}

///|
pub fn TextHit::inside(self : TextHit) -> Bool {
  self.inside
}

///|
pub fn TextHit::resolved_is_cursor_position(self : TextHit) -> Bool {
  self.resolved_is_cursor_position
}
