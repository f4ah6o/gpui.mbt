///|
#borrow(text, family, output)
extern "C" fn native_text_measure(
  abi : Int,
  text : Bytes,
  text_length : Int,
  family : Bytes,
  family_length : Int,
  font_size_px : Double,
  output : FixedArray[Double],
  output_capacity : Int,
) -> Int = "gpui_windows_text_measure_v1"

///|
#borrow(text, family, output)
extern "C" fn native_text_hit_test(
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
) -> Int = "gpui_windows_text_hit_test_v1"

///|
#borrow(text, family)
extern "C" fn native_text_admit_scene_run(
  abi : Int,
  text : Bytes,
  text_length : Int,
  family : Bytes,
  family_length : Int,
  font_size_px : Double,
  origin_x : Double,
  origin_y : Double,
  clip_x : Double,
  clip_y : Double,
  clip_width : Double,
  clip_height : Double,
) -> Int = "gpui_windows_text_admit_scene_run_v1"

///|
/// Measure one bounded, single-line DirectWrite layout and copy all scalar
/// caret records before releasing the native layout.
pub fn measure(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
) -> Result[@text_layout.TextMeasurement, WindowsTextError] {
  if font_size_px.is_nan() ||
    font_size_px.is_inf() ||
    font_size_px <= 0.0 ||
    font_size_px > max_font_size_px {
    return Err(InvalidFontSize)
  }
  let (text, boundaries) = match windows_text_boundaries(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let family = match windows_text_family(font_family) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let capacity = HEADER_DOUBLES + CARET_DOUBLES * boundaries.length()
  let output = FixedArray::make(capacity + 1, 0.0)
  output[capacity] = CANARY
  let status = native_text_measure(
    1,
    text,
    text.length(),
    family,
    family.length(),
    font_size_px,
    output,
    capacity,
  )
  if status != 0 {
    return Err(windows_text_status_error(status))
  }
  if output[capacity] != CANARY {
    return Err(InvalidNativeOutput)
  }
  let caret_count = match
    windows_text_exact_nonnegative_int(output[11], boundaries.length()) {
    Some(count) if count == boundaries.length() => count
    _ => return Err(InvalidNativeOutput)
  }
  let logical_rect = match windows_text_rect(output, 0) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  let ink_rect = match windows_text_rect(output, 4) {
    Ok(rect) => rect
    Err(error) => return Err(error)
  }
  let line_count = match windows_text_exact_nonnegative_int(output[9], 1) {
    Some(count) if count == 1 => count
    _ => return Err(InvalidNativeOutput)
  }
  let unknown_count = match
    windows_text_exact_nonnegative_int(output[10], @int.MAX_VALUE) {
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
    match windows_text_exact_nonnegative_int(output[start], text.length()) {
      Some(offset) if offset == boundaries[i].byte_offset => ()
      _ => return Err(InvalidNativeOutput)
    }
    let cursor_flag = output[start + 1]
    if cursor_flag != 0.0 && cursor_flag != 1.0 {
      return Err(InvalidNativeOutput)
    }
    let strong = match windows_text_rect(output, start + 2) {
      Ok(rect) => rect
      Err(error) => return Err(error)
    }
    let weak = match windows_text_rect(output, start + 6) {
      Ok(rect) => rect
      Err(error) => return Err(error)
    }
    carets[i] = match
      @text_layout.CaretGeometry::new(
        boundaries[i].utf16_offset,
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

///|
/// Hit test copied DirectWrite cluster geometry in logical coordinates.
pub fn hit_test(
  document : @text.TextDocument,
  font_family : String,
  font_size_px : Double,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, WindowsTextError] {
  if font_size_px.is_nan() ||
    font_size_px.is_inf() ||
    font_size_px <= 0.0 ||
    font_size_px > max_font_size_px {
    return Err(InvalidFontSize)
  }
  let (text, boundaries) = match windows_text_boundaries(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let family = match windows_text_family(font_family) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output = FixedArray::make(6, 0.0)
  output[5] = CANARY
  let status = native_text_hit_test(
    1,
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
    return Err(windows_text_status_error(status))
  }
  if output[5] != CANARY {
    return Err(InvalidNativeOutput)
  }
  let start_byte = match
    windows_text_exact_nonnegative_int(output[0], text.length()) {
    Some(value) => value
    None => return Err(InvalidNativeOutput)
  }
  let trailing = match
    windows_text_exact_nonnegative_int(output[1], boundaries.length() - 1) {
    Some(value) => value
    None => return Err(InvalidNativeOutput)
  }
  let resolved_byte = match
    windows_text_exact_nonnegative_int(output[2], text.length()) {
    Some(value) => value
    None => return Err(InvalidNativeOutput)
  }
  let inside_flag = output[3]
  let cursor_flag = output[4]
  if (inside_flag != 0.0 && inside_flag != 1.0) ||
    (cursor_flag != 0.0 && cursor_flag != 1.0) {
    return Err(InvalidNativeOutput)
  }
  let start_utf16 = match document.utf16_offset(start_byte) {
    Ok(value) => value
    Err(_) => return Err(InvalidNativeOutput)
  }
  let resolved_utf16 = match document.utf16_offset(resolved_byte) {
    Ok(value) => value
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
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidNativeOutput)
  }
}

///|
/// Qualify the same bounded, plain grayscale text mask used by the D3D11
/// renderer. This synchronously allocates and releases a temporary A8 mask.
pub fn admit_scene_text_run_at(
  document : @text.TextDocument,
  font_size_px : Double,
  text_origin : @primitives.Point,
  clip_rect : @primitives.Rect,
) -> Result[Unit, WindowsTextError] {
  if font_size_px.is_nan() ||
    font_size_px.is_inf() ||
    font_size_px <= 0.0 ||
    font_size_px > 32.0 {
    return Err(InvalidFontSize)
  }
  let (text, _) = match windows_text_boundaries(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if text.length() > 4096 {
    return Err(InputTooLarge)
  }
  // Scene text uses the renderer's fixed family so admission measures the
  // same glyph run that D3D11 will paint.
  let family = match windows_text_family("Segoe UI") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let width = clip_rect.size().width()
  let height = clip_rect.size().height()
  if width > 2048.0 || height > 128.0 {
    return Err(ResourceLimit)
  }
  let status = native_text_admit_scene_run(
    1,
    text,
    text.length(),
    family,
    family.length(),
    font_size_px,
    text_origin.x(),
    text_origin.y(),
    clip_rect.left(),
    clip_rect.top(),
    width,
    height,
  )
  if status == 0 {
    Ok(())
  } else {
    Err(windows_text_status_error(status))
  }
}
