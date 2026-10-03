///|
pub impl @platform.Backend for Host with fn stop(self) -> Result[
  Unit,
  @diagnostics.FrameworkError,
] {
  self.stop()
}

///|
pub impl @platform.Backend for Host with fn create_window(
  self,
  title : String,
  width : Double,
  height : Double,
) -> Result[@platform.WindowId, @diagnostics.FrameworkError] {
  self.create_window(title, width, height)
}

///|
pub impl @platform.Backend for Host with fn set_title(
  self,
  window : @platform.WindowId,
  title : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.set_title(window, title)
}

///|
pub impl @platform.Backend for Host with fn set_size(
  self,
  window : @platform.WindowId,
  width : Double,
  height : Double,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.set_size(window, width, height)
}

///|
pub impl @platform.Backend for Host with fn window_metrics(
  self,
  window : @platform.WindowId,
) -> Result[(Double, Double, Double), @diagnostics.FrameworkError] {
  self.window_metrics(window)
}

///|
pub impl @platform.Backend for Host with fn next_event(
  self,
  timeout_ms? : Int = 16,
) -> Result[@platform.Event?, @diagnostics.FrameworkError] {
  self.next_event(timeout_ms~)
}

///|
pub impl @platform.Backend for Host with fn present(
  self,
  window : @platform.WindowId,
  snapshot : @scene.SceneSnapshot,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.present(window, snapshot)
}

///|
pub impl @platform.Backend for Host with fn request_close(
  self,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.request_close(window)
}

///|
pub impl @platform.Backend for Host with fn destroy_window(
  self,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.destroy_window(window)
}

///|
pub impl @platform.Backend for Host with fn wake(self) -> Result[
  Unit,
  @diagnostics.FrameworkError,
] {
  self.wake()
}

///|
pub impl @platform.Backend for Host with fn request_exit(self) -> Result[
  Unit,
  @diagnostics.FrameworkError,
] {
  self.request_exit()
}

///|
pub impl @platform.Backend for Host with fn require_capability(
  self,
  capability : @platform.Capability,
) -> Result[Unit, @diagnostics.FrameworkError] {
  self.require_capability(capability)
}
