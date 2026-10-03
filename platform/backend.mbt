///|
/// Portable first-native-slice interface. Startup belongs to the target factory;
/// all returned identities, events, snapshots, and errors are framework values.
/// Cross-thread enqueue and production recovery remain future contract work.
pub(open) trait Backend {
  fn require_capability(Self, Capability) -> Result[
    Unit,
    @diagnostics.FrameworkError,
  ]
  fn stop(Self) -> Result[Unit, @diagnostics.FrameworkError]
  fn create_window(Self, String, Double, Double) -> Result[
    WindowId,
    @diagnostics.FrameworkError,
  ]
  fn set_title(Self, WindowId, String) -> Result[
    Unit,
    @diagnostics.FrameworkError,
  ]
  fn set_size(Self, WindowId, Double, Double) -> Result[
    Unit,
    @diagnostics.FrameworkError,
  ]
  fn window_metrics(Self, WindowId) -> Result[
    (Double, Double, Double),
    @diagnostics.FrameworkError,
  ]
  fn next_event(Self, timeout_ms? : Int) -> Result[
    Event?,
    @diagnostics.FrameworkError,
  ]
  fn present(Self, WindowId, @scene.SceneSnapshot) -> Result[
    Unit,
    @diagnostics.FrameworkError,
  ]
  fn request_close(Self, WindowId) -> Result[Unit, @diagnostics.FrameworkError]
  fn destroy_window(Self, WindowId) -> Result[Unit, @diagnostics.FrameworkError]
  fn wake(Self) -> Result[Unit, @diagnostics.FrameworkError]
  fn request_exit(Self) -> Result[Unit, @diagnostics.FrameworkError]
}

///|
/// Explicit capability discovery prevents applications from assuming that the
/// first native frame also provides text, accessibility, or recovery services.
pub(all) enum Capability {
  NativeWindow
  QuadFrames
  PointerKeyboard
  Clipboard
  Cursor
  TextInput
  Accessibility
  Menus
  RendererRecovery
  CrossThreadCommands
}
