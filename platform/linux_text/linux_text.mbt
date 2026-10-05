///|
/// Portable error values returned by the synchronous Linux PangoFT2 adapter.
pub enum LinuxTextError {
  InvalidFontFamily
  InvalidFontSize
  InvalidCoordinates
  UnsupportedInput
  UnsupportedColor
  UnsupportedRaster
  ResourceLimit
  InputTooLarge
  BufferTooSmall
  NativeFailure
  InvalidNativeOutput
} derive(Eq)

///|
pub extend LinuxTextError with Eq::{not_equal, equal}

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
extern "C" fn native_require_raster(abi : Int) -> Int = "gpui_linux_text_require_raster_v1"

///|
#borrow(text)
extern "C" fn native_admit_scene_text_run(
  abi : Int,
  text : Bytes,
  text_length : Int,
  font_size_px : Double,
  bounds_width : Double,
  bounds_height : Double,
) -> Int = "gpui_linux_text_admit_scene_text_run_v1"

///|
/// Admit the linked grayscale raster adapter only with its expected private
/// ABI and Pango >=1.50 glyph-color metadata. This does not promise color text,
/// input, IME, a window, or a font match across machines.
pub fn require_grayscale_raster() -> Result[Unit, LinuxTextError] {
  if native_require_raster(ABI_VERSION) == 0 {
    Ok(())
  } else {
    Err(UnsupportedRaster)
  }
}

///|
const HEADER_DOUBLES : Int = 12

///|
const CARET_DOUBLES : Int = 10

///|
const CANARY : Double = 123456789.125

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
) -> Int = "gpui_linux_text_measure_v1"

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
) -> Int = "gpui_linux_text_hit_test_v1"

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
fn prepare_text(document : @text.TextDocument) -> Result[Bytes, LinuxTextError] {
  if document.utf16_length() > max_text_bytes {
    return Err(InputTooLarge)
  }
  let byte_length = match document.utf8_length() {
    Ok(length) => length
    Err(_) => return Err(InputTooLarge)
  }
  if byte_length > max_text_bytes {
    return Err(InputTooLarge)
  }
  let bytes = @utf8.encode(document.text())
  if contains_nul(bytes) {
    return Err(UnsupportedInput)
  }
  Ok(bytes)
}

///|
fn prepare_family(family : String) -> Result[Bytes, LinuxTextError] {
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
fn valid_font_size(font_size_px : Double) -> Bool {
  !font_size_px.is_nan() &&
  !font_size_px.is_inf() &&
  font_size_px > 0.0 &&
  font_size_px <= max_font_size_px
}

///|
fn status_error(status : Int) -> LinuxTextError {
  match status {
    2 => UnsupportedInput
    3 => InputTooLarge
    4 => BufferTooSmall
    6 => InvalidNativeOutput
    7 => InvalidCoordinates
    8 => UnsupportedColor
    10 => UnsupportedRaster
    9 => ResourceLimit
    _ => NativeFailure
  }
}

///|
/// Qualify a candidate single-line field run against the same generic sans
/// PangoFT2 grayscale raster path used by Ubuntu scene presentation. This is
/// only native run admission: it does not validate GPU upload, texture limits,
/// or surface readiness. The temporary native mask is released synchronously.
pub fn admit_scene_text_run(
  document : @text.TextDocument,
  font_size_px : Double,
  bounds_width : Double,
  bounds_height : Double,
) -> Result[Unit, LinuxTextError] {
  if !valid_font_size(font_size_px) {
    return Err(InvalidFontSize)
  }
  if font_size_px > MAX_SCENE_FONT_SIZE_PX {
    return Err(ResourceLimit)
  }
  if bounds_width.is_nan() ||
    bounds_width.is_inf() ||
    bounds_width < 0.0 ||
    bounds_height.is_nan() ||
    bounds_height.is_inf() ||
    bounds_height < 0.0 {
    return Err(InvalidCoordinates)
  }
  if bounds_width > MAX_SCENE_BOUNDS_WIDTH ||
    bounds_height > MAX_SCENE_BOUNDS_HEIGHT {
    return Err(ResourceLimit)
  }
  let byte_length = match document.utf8_length() {
    Ok(length) => length
    Err(_) => return Err(InputTooLarge)
  }
  if byte_length > MAX_SCENE_TEXT_BYTES {
    return Err(ResourceLimit)
  }
  let text = match prepare_text(document) {
    Ok(bytes) => bytes
    Err(error) => return Err(error)
  }
  if text.length() != byte_length {
    return Err(InvalidNativeOutput)
  }
  let status = native_admit_scene_text_run(
    ABI_VERSION,
    text,
    text.length(),
    font_size_px,
    bounds_width,
    bounds_height,
  )
  if status == 0 {
    Ok(())
  } else {
    Err(status_error(status))
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
fn pango_rect(
  output : FixedArray[Double],
  start : Int,
) -> Result[@primitives.Rect, LinuxTextError] {
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
fn caret_record(
  output : FixedArray[Double],
  boundaries : Array[TextBoundary],
  index : Int,
) -> Result[@text_layout.CaretGeometry, LinuxTextError] {
  let start = HEADER_DOUBLES + index * CARET_DOUBLES
  let boundary = boundaries[index]
  match exact_nonnegative_int(output[start], max_text_bytes) {
    Some(byte_offset) if byte_offset == boundary.byte_offset => ()
    _ => return Err(InvalidNativeOutput)
  }
  let cursor_flag = output[start + 1]
  if cursor_flag != 0.0 && cursor_flag != 1.0 {
    return Err(InvalidNativeOutput)
  }
  let strong = match pango_rect(output, start + 2) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  let weak = match pango_rect(output, start + 6) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  match
    @text_layout.CaretGeometry::new(
      boundary.utf16_offset,
      cursor_flag == 1.0,
      strong,
      weak,
    ) {
    Ok(caret) => Ok(caret)
    Err(_) => Err(InvalidNativeOutput)
  }
}

///|
/// Shape and measure text synchronously with PangoFT2 and copy all results.
/// Every call constructs and releases its own layout; no display server,
/// renderer, or persistent native handle is involved.
pub fn measure(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
) -> Result[@text_layout.TextMeasurement, LinuxTextError] {
  if !valid_font_size(font_size_px) {
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
  let logical_rect = match pango_rect(output, 0) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  let ink_rect = match pango_rect(output, 4) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  let baseline = output[8]
  let line_count = match exact_nonnegative_int(output[9], boundaries.length()) {
    Some(count) if count >= 1 => count
    _ => return Err(InvalidNativeOutput)
  }
  let unknown_count = match exact_nonnegative_int(output[10], @int.MAX_VALUE) {
    Some(count) => count
    _ => return Err(InvalidNativeOutput)
  }
  let placeholder = match
    @text_layout.CaretGeometry::new(0, true, logical_rect, logical_rect) {
    Ok(caret) => caret
    Err(_) => return Err(InvalidNativeOutput)
  }
  let carets = Array::make(caret_count, placeholder)
  for i = 0; i < caret_count; i = i + 1 {
    carets[i] = match caret_record(output, boundaries, i) {
      Ok(caret) => caret
      Err(error) => return Err(error)
    }
  }
  match
    @text_layout.TextMeasurement::new(
      document, logical_rect, ink_rect, baseline, line_count, unknown_count, carets,
    ) {
    Ok(measurement) => Ok(measurement)
    Err(_) => Err(InvalidNativeOutput)
  }
}

///|
/// Hit test using Pango's native XY routine. Coordinates are logical px and are
/// rounded to the nearest 1/1024 px, with ties away from zero. Out-of-layout
/// points may still return Pango's nearest valid text position (`inside=false`).
pub fn hit_test(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, LinuxTextError] {
  if !valid_font_size(font_size_px) {
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
  let start_byte = match exact_nonnegative_int(output[0], text.length()) {
    Some(offset) => offset
    None => return Err(InvalidNativeOutput)
  }
  let trailing = match
    exact_nonnegative_int(output[1], boundaries.length() - 1) {
    Some(count) => count
    None => return Err(InvalidNativeOutput)
  }
  let resolved_byte = match exact_nonnegative_int(output[2], text.length()) {
    Some(offset) => offset
    None => return Err(InvalidNativeOutput)
  }
  let inside_flag = output[3]
  let cursor_flag = output[4]
  if (inside_flag != 0.0 && inside_flag != 1.0) ||
    (cursor_flag != 0.0 && cursor_flag != 1.0) {
    return Err(InvalidNativeOutput)
  }
  let start_utf16 = match document.utf16_offset(start_byte) {
    Ok(offset) => offset
    Err(_) => return Err(InvalidNativeOutput)
  }
  let resolved_utf16 = match document.utf16_offset(resolved_byte) {
    Ok(offset) => offset
    Err(_) => return Err(InvalidNativeOutput)
  }
  match
    @text_layout.TextHit::new(
      document,
      start_utf16,
      trailing,
      resolved_utf16,
      inside_flag == 1.0,
      cursor_flag == 1.0,
    ) {
    Ok(hit) => Ok(hit)
    Err(_) => Err(InvalidNativeOutput)
  }
}
