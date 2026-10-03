///|
/// Backend-neutral logical window identity. Tokens are never reused.
pub struct WindowId {
  value : Int64
} derive(Eq)

///|
pub fn WindowId::new(value : Int64) -> WindowId {
  { value, }
}

///|
pub fn WindowId::value(self : WindowId) -> Int64 {
  self.value
}

///|
pub(all) enum EventKind {
  Created
  Resized(width~ : Double, height~ : Double)
  Moved(x~ : Double, y~ : Double)
  ScaleChanged
  FocusChanged(Bool)
  Input(@primitives.InputEvent)
  CloseRequested
  Destroyed
  FrameCompleted
  Wake
  ExitRequested
}

///|
/// Sequence is monotonic per window; scale is captured before input delivery.
pub(all) struct Event {
  window : WindowId
  sequence : Int64
  scale : Double
  kind : EventKind
}

///|
pub fn Event::new(
  window : WindowId,
  sequence : Int64,
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
pub fn Event::sequence(self : Event) -> Int64 {
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
pub extend WindowId with Eq::{not_equal, equal}

///|
pub(all) enum Cursor {
  Arrow
  PointingHand
  Text
}
