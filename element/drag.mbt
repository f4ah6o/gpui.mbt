///|
/// Invalid configuration for a portable drag gesture.
pub enum DragError {
  InvalidThreshold
} derive(Eq)

///|
pub extend DragError with Eq::{not_equal, equal}

///|
/// Largest accepted drag activation distance, in logical coordinates.
pub const MAX_DRAG_THRESHOLD : Double = 1000000.0

///|
priv enum DragState {
  Idle
  Pending(UInt64, @primitives.Point, @primitives.Point)
  Dragging(UInt64, @primitives.Point, @primitives.Point)
}

///|
/// Immutable, platform-neutral state for one admitted pointer gesture.
///
/// The host selects the pointer and owns any platform capture. It forwards
/// coordinates here, retains each returned state, and calls `cancel` when
/// the gesture is interrupted. Source IDs have no platform-specific meaning.
pub struct DragGesture {
  priv threshold : Double
  priv state : DragState
}

///|
/// Create an idle gesture with a finite activation distance in
/// `0..=MAX_DRAG_THRESHOLD`. A zero threshold activates immediately on begin.
pub fn DragGesture::new(threshold : Double) -> Result[DragGesture, DragError] {
  if threshold.is_nan() ||
    threshold.is_inf() ||
    threshold < 0.0 ||
    threshold > MAX_DRAG_THRESHOLD {
    Err(InvalidThreshold)
  } else {
    Ok({ threshold, state: Idle, })
  }
}

///|
/// Begin only while idle. A repeated begin preserves the existing source,
/// origin, latest position, and activation state without retargeting it.
pub fn DragGesture::begin(
  self : DragGesture,
  source : UInt64,
  position : @primitives.Point,
) -> DragGesture {
  match self.state {
    Idle =>
      {
        threshold: self.threshold,
        state: if self.threshold == 0.0 {
          Dragging(source, position, position)
        } else {
          Pending(source, position, position)
        },
      }
    Pending(_, _, _) | Dragging(_, _, _) => self
  }
}

///|
/// Track the latest position. Reaching the Euclidean activation distance
/// from the origin starts dragging; returning toward the origin does not
/// deactivate it. Updating an idle gesture has no effect.
pub fn DragGesture::update(
  self : DragGesture,
  position : @primitives.Point,
) -> DragGesture {
  match self.state {
    Idle => self
    Pending(source, origin, _) =>
      {
        threshold: self.threshold,
        state: if drag_reached_threshold(origin, position, self.threshold) {
          Dragging(source, origin, position)
        } else {
          Pending(source, origin, position)
        },
      }
    Dragging(source, origin, _) =>
      { threshold: self.threshold, state: Dragging(source, origin, position), }
  }
}

///|
/// Source of either a pending or active gesture; absent while idle.
pub fn DragGesture::source(self : DragGesture) -> UInt64? {
  match self.state {
    Idle => None
    Pending(source, _, _) | Dragging(source, _, _) => Some(source)
  }
}

///|
/// Initial logical position, retained until release or cancellation.
pub fn DragGesture::origin(self : DragGesture) -> @primitives.Point? {
  match self.state {
    Idle => None
    Pending(_, origin, _) | Dragging(_, origin, _) => Some(origin)
  }
}

///|
/// Latest logical position; absent while idle.
pub fn DragGesture::position(self : DragGesture) -> @primitives.Point? {
  match self.state {
    Idle => None
    Pending(_, _, position) | Dragging(_, _, position) => Some(position)
  }
}

///|
pub fn DragGesture::is_dragging(self : DragGesture) -> Bool {
  self.state is Dragging(_, _, _)
}

///|
pub fn DragGesture::is_pending(self : DragGesture) -> Bool {
  self.state is Pending(_, _, _)
}

///|
/// Clear either pending or active state, retaining the configured threshold.
/// Hosts use this for interrupted input, including Escape or loss of capture.
pub fn DragGesture::cancel(self : DragGesture) -> DragGesture {
  { threshold: self.threshold, state: Idle, }
}

///|
/// Evaluate the final position and return an idle state plus the source only
/// if dragging activated. A click below the threshold returns no source.
/// Retain the returned state so another release cannot emit the source again.
pub fn DragGesture::release(
  self : DragGesture,
  position : @primitives.Point,
) -> (DragGesture, UInt64?) {
  let updated = self.update(position)
  let released = if updated.is_dragging() { updated.source() } else { None }
  (updated.cancel(), released)
}

///|
/// Return an axis distance capped at the threshold. Same-sign subtraction
/// cannot overflow. Opposite-sign magnitudes are checked before addition,
/// so even opposite finite extremes never produce infinity internally.
fn drag_axis_distance(a : Double, b : Double, threshold : Double) -> Double {
  let distance = if (a < 0.0 && b >= 0.0) || (a >= 0.0 && b < 0.0) {
    let magnitude_a = if a < 0.0 { -a } else { a }
    let magnitude_b = if b < 0.0 { -b } else { b }
    if magnitude_a >= threshold || magnitude_b >= threshold {
      return threshold
    }
    magnitude_a + magnitude_b
  } else if a >= b {
    a - b
  } else {
    b - a
  }
  if distance >= threshold {
    threshold
  } else {
    distance
  }
}

///|
fn drag_reached_threshold(
  origin : @primitives.Point,
  position : @primitives.Point,
  threshold : Double,
) -> Bool {
  if threshold == 0.0 {
    return true
  }
  let dx = drag_axis_distance(origin.x(), position.x(), threshold)
  let dy = drag_axis_distance(origin.y(), position.y(), threshold)
  if dx >= threshold || dy >= threshold {
    true
  } else {
    // Normalize only bounded distances. Squaring raw world coordinates or
    // a tiny threshold could overflow or underflow and misclassify a drag.
    let x = dx / threshold
    let y = dy / threshold
    x * x + y * y >= 1.0
  }
}
