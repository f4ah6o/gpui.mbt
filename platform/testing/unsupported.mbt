///|
/// Native frame evidence is unavailable on non-native targets.
pub fn FrameCapture::write_ppm(
  self : FrameCapture,
  path : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let _path_bytes = @utf8.encode(path)
  ignore(self)
  Err(error(@diagnostics.UnsupportedCapability, "write_ppm"))
}
