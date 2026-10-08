///|
#borrow(path, pixels)
extern "C" fn native_write_ppm(
  path : Bytes,
  path_length : Int,
  pixels : Bytes,
  pixel_length : Int,
  width : Int,
  height : Int,
) -> Int = "gpui_test_write_ppm_v1"

///|
/// Write an RGB P6 PPM evidence file without depending on an application-side
/// filesystem or image library.
pub fn FrameCapture::write_ppm(
  self : FrameCapture,
  path : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let path_bytes = @utf8.encode(path)
  if path_bytes.length() == 0 || path_bytes.length() > 4096 {
    return Err(error(@diagnostics.InvalidInput, "write_ppm"))
  }
  let result = native_write_ppm(
    path_bytes,
    path_bytes.length(),
    self.rgba8_top_left,
    self.rgba8_top_left.length(),
    self.width,
    self.height,
  )
  match result {
    0 => Ok(())
    1 => Err(error(@diagnostics.InvalidInput, "write_ppm"))
    2 => Err(error(@diagnostics.ConversionFailed, "write_ppm"))
    3 => Err(error(@diagnostics.ResourceExhausted, "write_ppm"))
    _ => Err(error(@diagnostics.NativeFailure, "write_ppm"))
  }
}
