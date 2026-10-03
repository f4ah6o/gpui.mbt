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
pub extend WindowId with Eq::{not_equal, equal}

///|
pub(all) enum Cursor {
  Arrow
  PointingHand
  Text
}
