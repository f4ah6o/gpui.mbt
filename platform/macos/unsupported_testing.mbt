///|
pub extend Host with @testing.FrameReadback::{copy_frame, frame_metrics}

///|
fn test_hook_unavailable(operation : String) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.UnsupportedCapability,
    operation,
    subsystem="native-testing",
    backend="macos-metal",
  )
}

///|
pub fn Host::post_test_click(
  _self : Host,
  _window : @platform.WindowId,
  _point : @primitives.Point,
) -> Result[Unit, @diagnostics.FrameworkError] {
  Err(test_hook_unavailable("post_test_click"))
}

///|
pub fn Host::post_test_escape(
  _self : Host,
  _window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  Err(test_hook_unavailable("post_test_escape"))
}

///|
pub impl @testing.FrameReadback for Host with fn frame_metrics(
  _self,
  _window : @platform.WindowId,
) -> Result[(Int, Int, Double), @diagnostics.FrameworkError] {
  Err(test_hook_unavailable("frame_metrics"))
}

///|
pub impl @testing.FrameReadback for Host with fn copy_frame(
  _self,
  _window : @platform.WindowId,
  _output : FixedArray[Byte],
) -> Result[Unit, @diagnostics.FrameworkError] {
  Err(test_hook_unavailable("copy_frame"))
}
