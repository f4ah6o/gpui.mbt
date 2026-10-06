///|
/// Errors from the bounded CoreText/AppKit text adapter. The public text
/// capability remains unsupported; this provider is an explicit experimental
/// dependency of the native single-line field.
pub enum MacTextError {
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
pub extend MacTextError with Eq::{not_equal, equal}

///|
pub let max_text_bytes : Int = 16384

///|
pub let max_font_family_bytes : Int = 256

///|
pub let max_font_size_px : Double = 512.0

///|
const MAX_SCENE_TEXT_BYTES : Int = 4096

///|
const MAX_SCENE_FONT_SIZE_PX : Double = 32.0

///|
const MAX_SCENE_BOUNDS_WIDTH : Double = 2048.0

///|
const MAX_SCENE_BOUNDS_HEIGHT : Double = 128.0

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
#borrow(text, family, output)
extern "C" fn native_hit_test(
  abi : Int,
  text : Bytes,
  text_length : Int,
  family : Bytes,
  family_length : Int,
  font_size_px : Double,
  x_px : Double,
  y_px : Double,
  output : FixedArray[Double],
  output_capacity : Int,
) -> Int = "gpui_macos_text_hit_test_v1"

///|
#borrow(text)
extern "C" fn native_admit(
  abi : Int,
  text : Bytes,
  text_length : Int,
  font_size_px : Double,
  origin_x : Double,
  origin_y : Double,
  clip_x : Double,
  clip_y : Double,
  clip_width : Double,
  clip_height : Double,
) -> Int = "gpui_macos_text_admit_v1"

///|
#borrow(text, family, output)
extern "C" fn native_fonts_json(
  text : Bytes,
  text_length : Int,
  family : Bytes,
  family_length : Int,
  font_size_px : Double,
  output : FixedArray[Byte],
  output_capacity : Int,
) -> Int = "gpui_macos_text_fonts_json_v1"

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
fn prepare_text(document : @text.TextDocument) -> Result[Bytes, MacTextError] {
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
fn prepare_family(family : String) -> Result[Bytes, MacTextError] {
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
  if bytes.length() == 0 || bytes.length() > max_font_family_bytes {
    return Err(InputTooLarge)
  }
  if contains_nul(bytes) {
    return Err(InvalidFontFamily)
  }
  Ok(bytes)
}

///|
fn valid_font_size(size : Double) -> Bool {
  !size.is_nan() && !size.is_inf() && size > 0.0 && size <= max_font_size_px
}

///|
fn status_error(status : Int) -> MacTextError {
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
/// Admit CoreText's grayscale CoreGraphics bitmap path on this native target.
/// It does not advertise the backend's global TextInput capability.
pub fn require_grayscale_raster() -> Result[Unit, MacTextError] {
  let status = native_require_raster(ABI_VERSION)
  if status == 0 {
    Ok(())
  } else {
    Err(status_error(status))
  }
}

///|
fn valid_coordinates(values : Array[Double]) -> Bool {
  for value in values {
    if value.is_nan() ||
      value.is_inf() ||
      value < -100000000000000000000.0 ||
      value > 100000000000000000000.0 {
      return false
    }
  }
  true
}

///|
fn valid_scene_coordinates(values : Array[Double]) -> Bool {
  for value in values {
    if value.is_nan() ||
      value.is_inf() ||
      value < -1000000000.0 ||
      value > 1000000000.0 {
      return false
    }
  }
  true
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
fn output_rect(
  output : FixedArray[Double],
  start : Int,
) -> Result[@primitives.Rect, MacTextError] {
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
/// Shape, measure, and copy CoreText geometry. Offsets are UTF-16; every
/// scalar boundary appears in the copied caret table, while extended grapheme
/// boundaries are marked as valid cursor positions.
pub fn measure(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
) -> Result[@text_layout.TextMeasurement, MacTextError] {
  if !valid_font_size(font_size_px) {
    return Err(InvalidFontSize)
  }
  let text = match prepare_text(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let family = match prepare_family(font_family) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let boundaries = text_boundaries(document)
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
  let count = match exact_nonnegative_int(output[11], boundaries.length()) {
    Some(value) if value == boundaries.length() => value
    _ => return Err(InvalidNativeOutput)
  }
  let logical = match output_rect(output, 0) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let ink = match output_rect(output, 4) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let baseline = output[8]
  if baseline.is_nan() || baseline.is_inf() {
    return Err(InvalidNativeOutput)
  }
  let line_count = match exact_nonnegative_int(output[9], boundaries.length()) {
    Some(value) if value >= 1 => value
    _ => return Err(InvalidNativeOutput)
  }
  let unknown = match exact_nonnegative_int(output[10], 2147483647) {
    Some(value) => value
    None => return Err(InvalidNativeOutput)
  }
  let placeholder = match
    @text_layout.CaretGeometry::new(0, true, logical, logical) {
    Ok(value) => value
    Err(_) => return Err(InvalidNativeOutput)
  }
  let carets = Array::make(count, placeholder)
  for i = 0; i < count; i = i + 1 {
    let slot = HEADER_DOUBLES + i * CARET_DOUBLES
    match exact_nonnegative_int(output[slot], text.length()) {
      Some(value) if value == boundaries[i].byte_offset => ()
      _ => return Err(InvalidNativeOutput)
    }
    if output[slot + 1] != 0.0 && output[slot + 1] != 1.0 {
      return Err(InvalidNativeOutput)
    }
    let strong = match output_rect(output, slot + 2) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let weak = match output_rect(output, slot + 6) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    carets[i] = match
      @text_layout.CaretGeometry::new(
        boundaries[i].utf16_offset,
        output[slot + 1] == 1.0,
        strong,
        weak,
      ) {
      Ok(value) => value
      Err(_) => return Err(InvalidNativeOutput)
    }
  }
  match
    @text_layout.TextMeasurement::new(
      document, logical, ink, baseline, line_count, unknown, carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidNativeOutput)
  }
}

///|
/// Resolve a logical hit to the nearest valid grapheme caret. CoreText text
/// indices never escape native memory; returned indices are copied UTF-16
/// boundaries validated against the supplied document.
pub fn hit_test(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, MacTextError] {
  if !valid_font_size(font_size_px) {
    return Err(InvalidFontSize)
  }
  if !valid_coordinates([point.x(), point.y()]) {
    return Err(InvalidCoordinates)
  }
  let text = match prepare_text(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let family = match prepare_family(font_family) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let boundaries = text_boundaries(document)
  let output = FixedArray::make(6, 0.0)
  output[5] = CANARY
  let status = native_hit_test(
    ABI_VERSION,
    text,
    text.length(),
    family,
    family.length(),
    font_size_px,
    point.x(),
    point.y(),
    output,
    5,
  )
  if status != 0 {
    return Err(status_error(status))
  }
  if output[5] != CANARY {
    return Err(InvalidNativeOutput)
  }
  let start = match exact_nonnegative_int(output[0], text.length()) {
    Some(value) => value
    None => return Err(InvalidNativeOutput)
  }
  let trailing = match
    exact_nonnegative_int(output[1], boundaries.length() - 1) {
    Some(value) => value
    None => return Err(InvalidNativeOutput)
  }
  let resolved = match exact_nonnegative_int(output[2], text.length()) {
    Some(value) => value
    None => return Err(InvalidNativeOutput)
  }
  if (output[3] != 0.0 && output[3] != 1.0) ||
    (output[4] != 0.0 && output[4] != 1.0) {
    return Err(InvalidNativeOutput)
  }
  let start_utf16 = match document.utf16_offset(start) {
    Ok(value) => value
    Err(_) => return Err(InvalidNativeOutput)
  }
  let resolved_utf16 = match document.utf16_offset(resolved) {
    Ok(value) => value
    Err(_) => return Err(InvalidNativeOutput)
  }
  match
    @text_layout.TextHit::new(
      document,
      start_utf16,
      trailing,
      resolved_utf16,
      output[3] == 1.0,
      output[4] == 1.0,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidNativeOutput)
  }
}

///|
/// Preflight the exact system-sans raster profile used by the macOS Metal
/// renderer. Geometry is in logical points; no backing-scale conversion is
/// applied here. Color glyphs, bidi, multiline, and oversized runs are typed
/// rejects rather than silently rasterized differently.
pub fn admit_scene_text_run_at(
  document : @text.TextDocument,
  font_size_px : Double,
  text_origin : @primitives.Point,
  bounds : @primitives.Rect,
) -> Result[Unit, MacTextError] {
  if !valid_font_size(font_size_px) {
    return Err(InvalidFontSize)
  }
  if font_size_px > MAX_SCENE_FONT_SIZE_PX {
    return Err(ResourceLimit)
  }
  if !valid_scene_coordinates([
      text_origin.x(),
      text_origin.y(),
      bounds.left(),
      bounds.top(),
      bounds.left() + bounds.size().width(),
      bounds.top() + bounds.size().height(),
    ]) ||
    bounds.size().width() < 0.0 ||
    bounds.size().height() < 0.0 {
    return Err(InvalidCoordinates)
  }
  if bounds.size().width() > MAX_SCENE_BOUNDS_WIDTH ||
    bounds.size().height() > MAX_SCENE_BOUNDS_HEIGHT {
    return Err(ResourceLimit)
  }
  let text = match prepare_text(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if text.length() > MAX_SCENE_TEXT_BYTES {
    return Err(ResourceLimit)
  }
  let status = native_admit(
    ABI_VERSION,
    text,
    text.length(),
    font_size_px,
    text_origin.x(),
    text_origin.y(),
    bounds.left(),
    bounds.top(),
    bounds.size().width(),
    bounds.size().height(),
  )
  if status == 0 {
    Ok(())
  } else {
    Err(status_error(status))
  }
}

///|
/// Return the resolved CoreText run fonts as JSON with their filesystem URLs.
/// The native hotpath harness hashes those files so measurements are bound to
/// the actual Latin/Japanese fallback set used on that host.
pub fn font_resolution_json(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
) -> Result[String, MacTextError] {
  if !valid_font_size(font_size_px) {
    return Err(InvalidFontSize)
  }
  let text = match prepare_text(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let family = match prepare_family(font_family) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let buffer = FixedArray::make(131072, (0).to_byte())
  let status = native_fonts_json(
    text,
    text.length(),
    family,
    family.length(),
    font_size_px,
    buffer,
    buffer.length(),
  )
  if status < 0 {
    return Err(status_error(-status))
  }
  if status > buffer.length() {
    return Err(InvalidNativeOutput)
  }
  let bytes = Bytes::makei(status, i => buffer[i])
  try @utf8.decode(bytes) catch {
    _ => Err(InvalidNativeOutput)
  } noraise {
    value => Ok(value)
  }
}
