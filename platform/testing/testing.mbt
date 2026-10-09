///|
/// A copied RGBA8 image of the most recently completed native presentation.
/// Pixels and coordinates use a top-left origin and logical content is scaled
/// into the physical dimensions reported here.
pub struct FrameCapture {
  priv width : Int
  priv height : Int
  priv scale : Double
  priv rgba8_top_left : Bytes
}

///|
/// Native hosts implement this seam only for opt-in E2E image evidence.
pub(open) trait FrameReadback {
  fn frame_metrics(Self, @platform.WindowId) -> Result[
    (Int, Int, Double),
    @diagnostics.FrameworkError,
  ]
  fn copy_frame(Self, @platform.WindowId, FixedArray[Byte]) -> Result[
    Unit,
    @diagnostics.FrameworkError,
  ]
}

///|
fn error(
  code : @diagnostics.ErrorCode,
  operation : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    code,
    operation,
    subsystem="native-testing",
    backend="platform-readback",
  )
}

///|
fn checked_byte_length(
  width : Int,
  height : Int,
  scale : Double,
) -> Result[Int, @diagnostics.FrameworkError] {
  if width <= 0 ||
    height <= 0 ||
    width > 16384 ||
    height > 16384 ||
    scale.is_nan() ||
    scale.is_inf() ||
    scale <= 0.0 ||
    scale > 8.0 {
    return Err(error(@diagnostics.ConversionFailed, "frame_metrics"))
  }
  let pixel_count = width * height
  if pixel_count > 16 * 1024 * 1024 {
    return Err(error(@diagnostics.ResourceExhausted, "frame_metrics"))
  }
  Ok(pixel_count * 4)
}

///|
/// Read a native frame only when the process opted in with
/// `GPUI_NATIVE_E2E=1`. Host implementations copy the last completed GPU
/// buffer; this function validates all dimensions before allocating pixels.
pub fn[H : FrameReadback] capture_frame(
  host : H,
  window : @platform.WindowId,
) -> Result[FrameCapture, @diagnostics.FrameworkError] {
  if @env.get_env_var("GPUI_NATIVE_E2E") != Some("1") {
    return Err(error(@diagnostics.UnsupportedCapability, "capture_frame"))
  }
  let (width, height, scale) = match host.frame_metrics(window) {
    Ok(metrics) => metrics
    Err(failure) => return Err(failure)
  }
  let length = match checked_byte_length(width, height, scale) {
    Ok(value) => value
    Err(failure) => return Err(failure)
  }
  let output = FixedArray::make(length, b'\x00')
  match host.copy_frame(window, output) {
    Err(failure) => Err(failure)
    Ok(_) =>
      Ok({ width, height, scale, rgba8_top_left: Bytes::from_array(output), })
  }
}

///|
pub fn FrameCapture::width(self : FrameCapture) -> Int {
  self.width
}

///|
pub fn FrameCapture::height(self : FrameCapture) -> Int {
  self.height
}

///|
pub fn FrameCapture::scale(self : FrameCapture) -> Double {
  self.scale
}

///|
pub fn FrameCapture::rgba8_top_left(self : FrameCapture) -> Bytes {
  self.rgba8_top_left
}

///|
pub fn FrameCapture::pixel_rgba8(
  self : FrameCapture,
  x : Int,
  y : Int,
) -> Result[(Int, Int, Int, Int), @diagnostics.FrameworkError] {
  if x < 0 || x >= self.width || y < 0 || y >= self.height {
    return Err(error(@diagnostics.InvalidInput, "pixel_rgba8"))
  }
  let offset = (y * self.width + x) * 4
  Ok(
    (
      self.rgba8_top_left.unsafe_get(offset).to_int(),
      self.rgba8_top_left.unsafe_get(offset + 1).to_int(),
      self.rgba8_top_left.unsafe_get(offset + 2).to_int(),
      self.rgba8_top_left.unsafe_get(offset + 3).to_int(),
    ),
  )
}
