///|
pub extend Host with @testing.FrameReadback::{copy_frame, frame_metrics}

///|
pub impl @testing.FrameReadback for Host with fn frame_metrics(
  self,
  window : @platform.WindowId,
) -> Result[(Int, Int, Double), @diagnostics.FrameworkError] {
  let metrics : FixedArray[Double] = FixedArray::make(3, 0.0)
  match
    outcome(
      native_frame_metrics(self.token, window.value().to_int(), metrics),
      "frame_metrics",
    ) {
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
        Err(backend_error(11, "frame_metrics"))
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
  outcome(
    native_frame_copy(
      self.token,
      window.value().to_int(),
      output,
      output.length(),
    ),
    "copy_frame",
  )
}
