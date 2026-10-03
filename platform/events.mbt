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
  VisibilityChanged(Bool)
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
/// Events produced by callbacks enter the framework through this push/drain
/// boundary. Hosts enqueue framework-owned values; dispatch happens only after
/// the application explicitly drains the queue.
pub(open) trait EventSource {
  fn enqueue(Self, EventKind, Double) -> Result[Event, EventIngressError]
  fn enqueue_wake(Self, Double) -> Result[Bool, EventIngressError]
  fn drain(Self) -> Array[Event]
  fn close(Self) -> Unit
}

///|
/// A rejected push into the common host-to-framework event ingress.
pub(all) enum EventIngressError {
  Closed
  InvalidScale
  SequenceExhausted
} derive(Eq)

///|
pub extend EventIngressError with Eq::{not_equal, equal}

///|
/// Deterministic callback/push event queue shared by host backends. Sequence
/// numbers are assigned at acceptance time and preserved by `drain`. Wake
/// events may coalesce; regular input and lifecycle events never do.
pub struct EventIngress {
  window : WindowId
  events : Array[Event]
  mut next_sequence : Int64
  mut closed : Bool
  mut wake_pending : Bool
}

///|
pub fn EventIngress::new(window : WindowId) -> EventIngress {
  { window, events: [], next_sequence: 1, closed: false, wake_pending: false, }
}

///|
pub fn EventIngress::enqueue(
  self : EventIngress,
  kind : EventKind,
  scale : Double,
) -> Result[Event, EventIngressError] {
  if self.closed {
    Err(Closed)
  } else if scale.is_nan() || scale.is_inf() || scale <= 0.0 {
    Err(InvalidScale)
  } else if self.next_sequence == 0x7fff_ffff_ffff_ffff {
    Err(SequenceExhausted)
  } else {
    let event = Event::new(self.window, self.next_sequence, scale, kind)
    self.next_sequence += 1
    self.events.push(event)
    if kind is Wake {
      self.wake_pending = true
    }
    Ok(event)
  }
}

///|
/// Enqueue one wake request. Repeated wake requests before a drain collapse to
/// one event, while the work that caused them remains in the event queue.
pub fn EventIngress::enqueue_wake(
  self : EventIngress,
  scale : Double,
) -> Result[Bool, EventIngressError] {
  if self.closed {
    Err(Closed)
  } else if scale.is_nan() || scale.is_inf() || scale <= 0.0 {
    Err(InvalidScale)
  } else if self.wake_pending {
    Ok(false)
  } else {
    match self.enqueue(Wake, scale) {
      Err(error) => Err(error)
      Ok(_) => Ok(true)
    }
  }
}

///|
/// Drain all accepted events in deterministic acceptance order.
pub fn EventIngress::drain(self : EventIngress) -> Array[Event] {
  let drained : Array[Event] = []
  for event in self.events {
    drained.push(event)
  }
  self.events.clear()
  self.wake_pending = false
  drained
}

///|
/// Close the ingress and release queued events. Later pushes return `Closed`.
pub fn EventIngress::close(self : EventIngress) -> Unit {
  self.closed = true
  self.events.clear()
  self.wake_pending = false
}

///|
pub fn EventIngress::pending_count(self : EventIngress) -> Int {
  self.events.length()
}

///|
pub fn EventIngress::is_closed(self : EventIngress) -> Bool {
  self.closed
}

///|
pub impl EventSource for EventIngress with fn enqueue(self, kind, scale) {
  self.enqueue(kind, scale)
}

///|
pub impl EventSource for EventIngress with fn enqueue_wake(self, scale) {
  self.enqueue_wake(scale)
}

///|
pub impl EventSource for EventIngress with fn drain(self) {
  self.drain()
}

///|
pub impl EventSource for EventIngress with fn close(self) {
  self.close()
}

///|
pub extend WindowId with Eq::{not_equal, equal}

///|
pub(all) enum Cursor {
  Arrow
  PointingHand
  Text
}
