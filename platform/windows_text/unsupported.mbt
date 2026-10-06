///|
/// The DirectWrite adapter is only available to native Windows callers.
pub fn measure(
  _document : @text.TextDocument,
  _font_family : String,
  _font_size_px : Double,
) -> Result[@text_layout.TextMeasurement, WindowsTextError] {
  Err(UnsupportedPlatform)
}

///|
pub fn hit_test(
  _document : @text.TextDocument,
  _font_family : String,
  _font_size_px : Double,
  _point : @primitives.Point,
) -> Result[@text_layout.TextHit, WindowsTextError] {
  Err(UnsupportedPlatform)
}

///|
pub fn admit_scene_text_run_at(
  _document : @text.TextDocument,
  _font_size_px : Double,
  _text_origin : @primitives.Point,
  _clip_rect : @primitives.Rect,
) -> Result[Unit, WindowsTextError] {
  Err(UnsupportedPlatform)
}

///|
/// The density-aware DirectWrite adapter is only available to native Windows callers.
pub fn admit_scene_text_run_at_scale(
  _document : @text.TextDocument,
  _font_size_px : Double,
  _text_origin : @primitives.Point,
  _clip_rect : @primitives.Rect,
  _pixels_per_dip : Double,
) -> Result[Unit, WindowsTextError] {
  Err(UnsupportedPlatform)
}
