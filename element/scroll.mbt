///|
/// Errors from a portable scroll viewport update.
pub enum ScrollError {
  NonFiniteValue
} derive(Eq)

///|
pub extend ScrollError with Eq::{not_equal, equal}

///|
/// Immutable scroll position in logical content coordinates. Positive offsets
/// move the viewport right/down; painting translates content by their negation.
/// Each axis stays in `0..max(content - viewport, 0)` independently.
pub struct ScrollState {
  viewport : @primitives.Size
  content : @primitives.Size
  position : @primitives.Point
}

///|
/// Start at the content origin. Sizes are already finite and non-negative by
/// the primitives package's construction contract. Zero extents are supported.
pub fn ScrollState::new(
  viewport : @primitives.Size,
  content : @primitives.Size,
) -> ScrollState {
  { viewport, content, position: scroll_point(0.0, 0.0), }
}

///|
/// Retain the current position after a layout/content change, clamping each
/// axis to its new limit instead of resetting an unaffected axis.
pub fn ScrollState::with_sizes(
  self : ScrollState,
  viewport : @primitives.Size,
  content : @primitives.Size,
) -> ScrollState {
  {
    viewport,
    content,
    position: scroll_point(
      scroll_clamp(
        self.position.x(),
        scroll_limit(viewport.width(), content.width()),
      ),
      scroll_clamp(
        self.position.y(),
        scroll_limit(viewport.height(), content.height()),
      ),
    ),
  }
}

///|
pub fn ScrollState::offset(self : ScrollState) -> @primitives.Point {
  self.position
}

///|
pub fn ScrollState::max_offset(self : ScrollState) -> @primitives.Point {
  scroll_point(
    scroll_limit(self.viewport.width(), self.content.width()),
    scroll_limit(self.viewport.height(), self.content.height()),
  )
}

///|
/// Scroll relatively. Non-finite input rejects the whole update. Finite
/// deltas, including ones whose unchecked addition would overflow, saturate
/// at the relevant edge; neither axis can overscroll.
pub fn ScrollState::scroll_by(
  self : ScrollState,
  delta_x : Double,
  delta_y : Double,
) -> Result[ScrollState, ScrollError] {
  if !scroll_finite(delta_x) || !scroll_finite(delta_y) {
    Err(NonFiniteValue)
  } else {
    let maximum = self.max_offset()
    Ok({
      viewport: self.viewport,
      content: self.content,
      position: scroll_point(
        scroll_advance(self.position.x(), delta_x, maximum.x()),
        scroll_advance(self.position.y(), delta_y, maximum.y()),
      ),
    })
  }
}

///|
/// Scroll to an absolute content offset, clamping finite coordinates to the
/// available range. Non-finite input rejects the whole update.
pub fn ScrollState::scroll_to(
  self : ScrollState,
  x : Double,
  y : Double,
) -> Result[ScrollState, ScrollError] {
  if !scroll_finite(x) || !scroll_finite(y) {
    Err(NonFiniteValue)
  } else {
    let maximum = self.max_offset()
    Ok({
      viewport: self.viewport,
      content: self.content,
      position: scroll_point(
        scroll_clamp(x, maximum.x()),
        scroll_clamp(y, maximum.y()),
      ),
    })
  }
}

///|
/// Reveal content-space bounds with the smallest movement on each axis.
/// A fully visible target leaves that axis unchanged. If a target is larger
/// than the viewport, always align its leading (left/top) edge, even when the
/// viewport already intersects it. This deterministic policy also handles
/// zero-sized viewports. Bounds outside the content are clamped to the nearest
/// available offset; revealing them completely may be impossible.
pub fn ScrollState::ensure_visible(
  self : ScrollState,
  bounds : @primitives.Rect,
) -> ScrollState {
  let maximum = self.max_offset()
  {
    viewport: self.viewport,
    content: self.content,
    position: scroll_point(
      scroll_reveal_axis(
        self.position.x(),
        self.viewport.width(),
        maximum.x(),
        bounds.left(),
        bounds.right(),
        bounds.size().width(),
      ),
      scroll_reveal_axis(
        self.position.y(),
        self.viewport.height(),
        maximum.y(),
        bounds.top(),
        bounds.bottom(),
        bounds.size().height(),
      ),
    ),
  }
}

///|
fn scroll_finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn scroll_limit(viewport : Double, content : Double) -> Double {
  if content > viewport {
    content - viewport
  } else {
    0.0
  }
}

///|
fn scroll_clamp(value : Double, maximum : Double) -> Double {
  if value <= 0.0 {
    0.0
  } else if value >= maximum {
    maximum
  } else {
    value
  }
}

///|
fn scroll_advance(current : Double, delta : Double, maximum : Double) -> Double {
  if delta <= -current {
    0.0
  } else if delta >= maximum - current {
    maximum
  } else {
    // Opposite signs cannot overflow; a positive delta only reaches this
    // branch when it fits in the remaining non-negative range.
    scroll_clamp(current + delta, maximum)
  }
}

///|
fn scroll_reveal_axis(
  current : Double,
  viewport : Double,
  maximum : Double,
  leading : Double,
  trailing : Double,
  extent : Double,
) -> Double {
  if extent > viewport || leading < current {
    scroll_clamp(leading, maximum)
  } else if trailing - current > viewport {
    // Here trailing >= leading >= current >= 0. Compare by subtraction so
    // even a huge viewport does not require adding its size to the offset.
    scroll_clamp(trailing - viewport, maximum)
  } else {
    current
  }
}

///|
fn scroll_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("scroll offset invariant violated")
  }
}
