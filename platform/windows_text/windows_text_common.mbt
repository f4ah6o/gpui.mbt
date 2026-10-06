///|
/// Errors from the bounded DirectWrite geometry and grayscale raster adapter.
pub(all) enum WindowsTextError {
  InvalidFontSize
  InvalidCoordinates
  InvalidFontFamily
  InvalidScale
  UnsupportedInput
  UnsupportedColor
  UnsupportedGlyph
  UnsupportedRaster
  ResourceLimit
  InputTooLarge
  BufferTooSmall
  NativeFailure
  InvalidNativeOutput
  UnsupportedPlatform
} derive(Eq)

///|
pub extend WindowsTextError with Eq::{not_equal, equal}

///|
pub let max_text_bytes : Int = 16384

///|
pub let max_font_size_px : Double = 512.0

///|
pub let max_scene_text_bytes : Int = 4096

///|
pub let max_scene_font_size_px : Double = 32.0

///|
pub let max_scene_text_runs : Int = 64

///|
pub let max_frame_text_bytes : Int = 262144

///|
const HEADER_DOUBLES : Int = 12

///|
const CARET_DOUBLES : Int = 10

///|
const CANARY : Double = 123456789.125

///|
priv struct WindowsTextBoundary {
  byte_offset : Int
  utf16_offset : Int
}

///|
fn windows_text_status_error(status : Int) -> WindowsTextError {
  match status {
    1 => UnsupportedInput
    2 => InvalidFontSize
    3 => InvalidCoordinates
    4 => UnsupportedInput
    5 => UnsupportedColor
    6 => UnsupportedRaster
    7 => ResourceLimit
    8 => InputTooLarge
    9 => BufferTooSmall
    10 => NativeFailure
    12 => UnsupportedGlyph
    13 => InvalidFontFamily
    14 => UnsupportedPlatform
    15 => InvalidScale
    _ => InvalidNativeOutput
  }
}

///|
fn windows_text_exact_nonnegative_int(value : Double, maximum : Int) -> Int? {
  if value.is_nan() ||
    value.is_inf() ||
    value < 0.0 ||
    value > maximum.to_double() {
    return None
  }
  let integer = value.to_int()
  if integer.to_double() == value {
    Some(integer)
  } else {
    None
  }
}

///|
fn windows_text_boundaries(
  document : @text.TextDocument,
) -> Result[(Bytes, Array[WindowsTextBoundary]), WindowsTextError] {
  if document.utf16_length() > max_text_bytes {
    return Err(InputTooLarge)
  }
  let byte_length = match document.utf8_length() {
    Ok(length) if length <= max_text_bytes => length
    _ => return Err(InputTooLarge)
  }
  let bytes = @utf8.encode(document.text())
  if bytes.length() != byte_length {
    return Err(InvalidNativeOutput)
  }
  let boundaries = [{ byte_offset: 0, utf16_offset: 0, }]
  let mut byte_offset = 0
  let mut utf16_offset = 0
  for scalar in document.text().iter() {
    let value = scalar.to_int()
    if value == 0 ||
      value == 0x0A ||
      value == 0x0D ||
      value == 0x2028 ||
      value == 0x2029 {
      return Err(UnsupportedInput)
    }
    byte_offset += if value <= 0x7F {
      1
    } else if value <= 0x7FF {
      2
    } else if value <= 0xFFFF {
      3
    } else {
      4
    }
    utf16_offset += if value > 0xFFFF { 2 } else { 1 }
    boundaries.push({ byte_offset, utf16_offset, })
  }
  if byte_offset != bytes.length() || utf16_offset != document.utf16_length() {
    return Err(InvalidNativeOutput)
  }
  Ok((bytes, boundaries))
}

///|
fn windows_text_family(family : String) -> Result[Bytes, WindowsTextError] {
  if family.length() == 0 {
    return Err(InvalidFontFamily)
  }
  let bytes = @utf8.encode(family)
  if bytes.length() == 0 || bytes.length() > 256 {
    return Err(
      if bytes.length() > 256 {
        InputTooLarge
      } else {
        InvalidFontFamily
      },
    )
  }
  let mut has_non_space = false
  for scalar in family.iter() {
    let value = scalar.to_int()
    if value != 0x20 &&
      value != 0x09 &&
      value != 0x0A &&
      value != 0x0D &&
      value != 0xA0 &&
      value != 0x1680 &&
      !(value >= 0x2000 && value <= 0x200A) &&
      value != 0x2028 &&
      value != 0x2029 &&
      value != 0x202F &&
      value != 0x205F &&
      value != 0x3000 {
      has_non_space = true
    }
    if value == 0 {
      return Err(InvalidFontFamily)
    }
  }
  if has_non_space {
    Ok(bytes)
  } else {
    Err(InvalidFontFamily)
  }
}

///|
fn windows_text_rect(
  output : FixedArray[Double],
  start : Int,
) -> Result[@primitives.Rect, WindowsTextError] {
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
