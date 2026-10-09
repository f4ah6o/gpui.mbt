///|
pub extend Host with @testing.FrameReadback::{copy_frame, frame_metrics}

///|
/// Post a test-only left click to this host-owned window through AppKit's
/// normal event route. Requires GPUI_NATIVE_E2E=1 and a test-hooks dylib.
pub fn Host::post_test_click(
  self : Host,
  window : @platform.WindowId,
  point : @primitives.Point,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(failure) => return Err(failure)
    Ok(_) => ()
  }
  status(
    test_post_click(window.value(), point.x(), point.y()),
    "post_test_click",
  )
}

///|
/// Post an Escape key down/up pair to this host-owned window through AppKit's
/// normal event route. Requires GPUI_NATIVE_E2E=1 and a test-hooks dylib.
pub fn Host::post_test_escape(
  self : Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(failure) => return Err(failure)
    Ok(_) => ()
  }
  status(test_post_escape(window.value()), "post_test_escape")
}

///|
pub impl @testing.FrameReadback for Host with fn frame_metrics(
  self,
  window : @platform.WindowId,
) -> Result[(Int, Int, Double), @diagnostics.FrameworkError] {
  match self.check() {
    Err(failure) => return Err(failure)
    Ok(_) => ()
  }
  let metrics : FixedArray[Double] = FixedArray::make(3, 0.0)
  match status(frame_metrics(window.value(), metrics), "frame_metrics") {
    Err(failure) => Err(failure)
    Ok(_) => {
      let width = metrics[0].to_int()
      let height = metrics[1].to_int()
      if metrics[0].is_nan() ||
        metrics[0].is_inf() ||
        metrics[1].is_nan() ||
        metrics[1].is_inf() ||
        width.to_double() != metrics[0] ||
        height.to_double() != metrics[1] {
        Err(error(@diagnostics.ConversionFailed, "frame_metrics"))
      } else {
        Ok((width, height, metrics[2]))
      }
    }
  }
}

///|
pub impl @testing.FrameReadback for Host with fn copy_frame(
  self,
  window : @platform.WindowId,
  output : FixedArray[Byte],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(failure) => return Err(failure)
    Ok(_) => ()
  }
  status(frame_copy(window.value(), output, output.length()), "copy_frame")
}
