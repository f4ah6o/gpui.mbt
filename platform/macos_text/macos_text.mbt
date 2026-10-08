///|
/// Errors from the bounded CoreText measurement and grayscale scene raster
/// adapter. Text display uses the system sans face to match native rendering.
pub enum MacosTextError {
  InvalidFontFamily
  InvalidFontSize
  InvalidCoordinates
  UnsupportedInput
  UnsupportedBidi
  UnsupportedMultiline
  UnsupportedColor
  UnsupportedGlyph
  UnsupportedRaster
  UnsupportedPlatform
  ResourceLimit
  InputTooLarge
  BufferTooSmall
  NativeFailure
  InvalidNativeOutput
} derive(Eq)

///|
pub extend MacosTextError with Eq::{not_equal, equal}

///|
pub let max_text_bytes : Int = 16384

///|
pub let max_font_family_bytes : Int = 256

///|
pub let max_font_size_px : Double = 512.0

///|
const ABI_VERSION : Int = 1

///|
const HEADER_DOUBLES : Int = 12

///|
const CARET_DOUBLES : Int = 10

///|
const CANARY : Double = 123456789.125

///|
extern "C" fn native_require_raster(abi : Int) -> Int = "gpui_macos_text_require_raster_v1"

///|
#borrow(text, family, output)
extern "C" fn native_measure(
  abi : Int,
  text : Bytes,
  text_length : Int,
  family : Bytes,
  family_length : Int,
  font_size_px : Double,
  output : FixedArray[Double],
  output_capacity : Int,
) -> Int = "gpui_macos_text_measure_v1"

///|
priv struct TextBoundary {
  byte_offset : Int
  utf16_offset : Int
}

///|
fn scalar_utf8_width(scalar : Char) -> Int {
  let value = scalar.to_int()
  if value <= 0x7F {
    1
  } else if value <= 0x7FF {
    2
  } else if value <= 0xFFFF {
    3
  } else {
    4
  }
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
fn text_boundaries(document : @text.TextDocument) -> Array[TextBoundary] {
  let boundaries = [{ byte_offset: 0, utf16_offset: 0, }]
  let mut byte_offset = 0
  let mut utf16_offset = 0
  for scalar in document.text().iter() {
    byte_offset += scalar_utf8_width(scalar)
    utf16_offset += scalar_utf16_width(scalar)
    boundaries.push({ byte_offset, utf16_offset, })
  }
  boundaries
}

///|
fn contains_nul(bytes : Bytes) -> Bool {
  for byte in bytes {
    if byte == b'\x00' {
      return true
    }
  }
  false
}

///|
fn prepare_text(document : @text.TextDocument) -> Result[Bytes, MacosTextError] {
  let byte_length = match document.utf8_length() {
    Ok(value) => value
    Err(_) => return Err(InputTooLarge)
  }
  if byte_length > max_text_bytes || document.utf16_length() > max_text_bytes {
    return Err(InputTooLarge)
  }
  let bytes = @utf8.encode(document.text())
  if bytes.length() != byte_length {
    return Err(InvalidNativeOutput)
  }
  if contains_nul(bytes) {
    return Err(UnsupportedInput)
  }
  Ok(bytes)
}

///|
fn prepare_family(family : String) -> Result[Bytes, MacosTextError] {
  if family.length() == 0 {
    return Err(InvalidFontFamily)
  }
  if family.length() > max_font_family_bytes {
    return Err(InputTooLarge)
  }
  match @text.TextDocument::new(family) {
    Ok(_) => ()
    Err(_) => return Err(InvalidFontFamily)
  }
  let bytes = @utf8.encode(family)
  if bytes.length() == 0 ||
    bytes.length() > max_font_family_bytes ||
    contains_nul(bytes) {
    return Err(InvalidFontFamily)
  }
  Ok(bytes)
}

///|
fn status_error(status : Int) -> MacosTextError {
  match status {
    2 => UnsupportedInput
    3 => InputTooLarge
    4 => BufferTooSmall
    6 => InvalidNativeOutput
    7 => InvalidCoordinates
    8 => UnsupportedColor
    9 => UnsupportedPlatform
    10 => UnsupportedRaster
    11 => InvalidFontFamily
    12 => InvalidFontSize
    14 => UnsupportedBidi
    15 => UnsupportedMultiline
    16 => UnsupportedGlyph
    17 => ResourceLimit
    _ => NativeFailure
  }
}

///|
/// Confirm the linked CoreGraphics grayscale raster path is available. This
/// does not claim that a native window or text-input session is available.
pub fn require_grayscale_raster() -> Result[Unit, MacosTextError] {
  match native_require_raster(ABI_VERSION) {
    0 => Ok(())
    status => Err(status_error(status))
  }
}

///|
fn exact_nonnegative_int(value : Double, maximum : Int) -> Int? {
  if value.is_nan() ||
    value.is_inf() ||
    value < 0.0 ||
    value > maximum.to_double() {
    return None
  }
  let converted = value.to_int()
  if converted.to_double() == value {
    Some(converted)
  } else {
    None
  }
}

///|
fn native_rect(
  output : FixedArray[Double],
  start : Int,
) -> Result[@primitives.Rect, MacosTextError] {
  match
    @primitives.Rect::new(
      output[start],
      output[start + 1],
      output[start + 2],
      output[start + 3],
    ) {
    Ok(rect) => Ok(rect)
    Err(_) => Err(InvalidNativeOutput)
  }
}

///|
/// Shape a bounded single-line document with CoreText, copying metrics and
/// caret geometry before releasing the native objects. `sans` resolves to
/// macOS's system sans face used by the scene rasterizer.
pub fn measure(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
) -> Result[@text_layout.TextMeasurement, MacosTextError] {
  if font_size_px.is_nan() ||
    font_size_px.is_inf() ||
    font_size_px <= 0.0 ||
    font_size_px > max_font_size_px {
    return Err(InvalidFontSize)
  }
  let family = match prepare_family(font_family) {
    Ok(bytes) => bytes
    Err(error) => return Err(error)
  }
  let text = match prepare_text(document) {
    Ok(bytes) => bytes
    Err(error) => return Err(error)
  }
  let boundaries = text_boundaries(document)
  if text.length() != boundaries[boundaries.length() - 1].byte_offset {
    return Err(InvalidNativeOutput)
  }
  let capacity = HEADER_DOUBLES + CARET_DOUBLES * boundaries.length()
  let output = FixedArray::make(capacity + 1, 0.0)
  output[capacity] = CANARY
  let status = native_measure(
    ABI_VERSION,
    text,
    text.length(),
    family,
    family.length(),
    font_size_px,
    output,
    capacity,
  )
  if status != 0 {
    return Err(status_error(status))
  }
  if output[capacity] != CANARY {
    return Err(InvalidNativeOutput)
  }
  let caret_count = match
    exact_nonnegative_int(output[11], boundaries.length()) {
    Some(count) if count == boundaries.length() => count
    _ => return Err(InvalidNativeOutput)
  }
  let logical_rect = match native_rect(output, 0) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  let ink_rect = match native_rect(output, 4) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  let line_count = match exact_nonnegative_int(output[9], 1) {
    Some(count) if count == 1 => count
    _ => return Err(InvalidNativeOutput)
  }
  let unknown_count = match exact_nonnegative_int(output[10], @int.MAX_VALUE) {
    Some(count) => count
    None => return Err(InvalidNativeOutput)
  }
  let placeholder = match
    @text_layout.CaretGeometry::new(0, true, logical_rect, logical_rect) {
    Ok(caret) => caret
    Err(_) => return Err(InvalidNativeOutput)
  }
  let carets = Array::make(caret_count, placeholder)
  for i = 0; i < caret_count; i = i + 1 {
    let start = HEADER_DOUBLES + i * CARET_DOUBLES
    let boundary = boundaries[i]
    match exact_nonnegative_int(output[start], text.length()) {
      Some(offset) if offset == boundary.byte_offset => ()
      _ => return Err(InvalidNativeOutput)
    }
    let cursor_flag = output[start + 1]
    if cursor_flag != 0.0 && cursor_flag != 1.0 {
      return Err(InvalidNativeOutput)
    }
    let strong = match native_rect(output, start + 2) {
      Ok(rect) => rect
      Err(error) => return Err(error)
    }
    let weak = match native_rect(output, start + 6) {
      Ok(rect) => rect
      Err(error) => return Err(error)
    }
    carets[i] = match
      @text_layout.CaretGeometry::new(
        boundary.utf16_offset,
        cursor_flag == 1.0,
        strong,
        weak,
      ) {
      Ok(caret) => caret
      Err(_) => return Err(InvalidNativeOutput)
    }
  }
  match
    @text_layout.TextMeasurement::new(
      document,
      logical_rect,
      ink_rect,
      output[8],
      line_count,
      unknown_count,
      carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidNativeOutput)
  }
}
