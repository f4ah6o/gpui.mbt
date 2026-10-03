///|
/// Repository-owned identities, never native handles. IDs are never reused.
pub struct WindowId {
  value : Int
} derive(Eq)

///|
pub fn WindowId::new(value : Int) -> WindowId {
  { value, }
}

///|
pub fn WindowId::value(self : WindowId) -> Int {
  self.value
}

///|
pub(all) enum HostState {
  Running
  Quiescing
  Stopped
} derive(Eq)

///|
/// Events are copied after native dispatch returns. Sequence is monotonic for
/// each window; scale is the value observed when the event was queued.
pub struct Event {
  window : WindowId
  sequence : Int
  scale : Double
  kind : EventKind
}

///|
pub(all) enum EventKind {
  Configured(width~ : Int, height~ : Int)
  ScaleChanged
  CloseRequested
  Destroyed
  FrameCompleted
  FocusChanged(focused~ : Bool)
  Input(@primitives.InputEvent)
}

///|
pub fn Event::new(
  window : WindowId,
  sequence : Int,
  scale : Double,
  kind : EventKind,
) -> Event {
  { window, sequence, scale, kind, }
}

///|
pub fn Event::window(self : Event) -> WindowId {
  self.window
}

///|
pub fn Event::sequence(self : Event) -> Int {
  self.sequence
}

///|
pub fn Event::scale(self : Event) -> Double {
  self.scale
}

///|
pub fn Event::kind(self : Event) -> EventKind {
  self.kind
}

///|
/// Minimal shared host/window/renderer contract for the first native slice.
/// A dispatch turn returns queued events after callbacks have unwound. It may
/// block for at most timeout_ms; 0 only dispatches immediately available work.
pub(open) trait Backend {
  fn state(Self) -> HostState
  fn wake(Self) -> Result[Unit, @diagnostics.FrameworkError]
  fn request_exit(Self) -> Result[Unit, @diagnostics.FrameworkError]
  fn stop(Self) -> Result[Unit, @diagnostics.FrameworkError]
  fn create_window(Self, Int, Int, String) -> Result[
    WindowId,
    @diagnostics.FrameworkError,
  ]
  fn destroy_window(Self, WindowId) -> Result[Unit, @diagnostics.FrameworkError]
  fn dispatch(Self, Int) -> Result[Array[Event], @diagnostics.FrameworkError]
  fn present(Self, WindowId, @scene.SceneSnapshot) -> Result[
    Unit,
    @diagnostics.FrameworkError,
  ]
}

///|
pub extend WindowId with Eq::{not_equal, equal}

///|
pub extend HostState with Eq::{not_equal, equal}
