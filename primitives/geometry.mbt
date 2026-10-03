///|
/// Finite, platform-independent logical coordinates and bounds.
///
/// Values are validated at construction. Rectangle containment uses closed
/// edges; a zero-width or zero-height rectangle is valid.
pub enum GeometryError {
  NonFiniteValue
  NegativeExtent
  BoundsOverflow
  BoundsNotRepresentable
} derive(Eq)

///|
pub extend GeometryError with Eq::{not_equal, equal}

///|
/// A location in logical coordinates.
pub struct Point {
  x : Double
  y : Double
} derive(Eq)

///|
pub extend Point with Eq::{not_equal, equal}

///|
/// Non-negative logical width and height.
pub struct Size {
  width : Double
  height : Double
} derive(Eq)

///|
pub extend Size with Eq::{not_equal, equal}

///|
/// An axis-aligned rectangle described by its top-left point and extent.
pub struct Rect {
  origin : Point
  size : Size
} derive(Eq)

///|
pub extend Rect with Eq::{not_equal, equal}

///|
fn finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
/// Construct a point, rejecting NaN and either infinity.
pub fn Point::new(x : Double, y : Double) -> Result[Point, GeometryError] {
  if !finite(x) || !finite(y) {
    Err(NonFiniteValue)
  } else {
    Ok({ x, y, })
  }
}

///|
pub fn Point::x(self : Point) -> Double {
  self.x
}

///|
pub fn Point::y(self : Point) -> Double {
  self.y
}

///|
/// Add a logical offset and revalidate the resulting point.
pub fn Point::translated(
  self : Point,
  offset : Point,
) -> Result[Point, GeometryError] {
  Point::new(self.x + offset.x, self.y + offset.y)
}

///|
/// Scale a point about the logical origin.
pub fn Point::scaled(
  self : Point,
  factor : Double,
) -> Result[Point, GeometryError] {
  if !finite(factor) {
    Err(NonFiniteValue)
  } else {
    Point::new(self.x * factor, self.y * factor)
  }
}

///|
/// Construct a finite size whose dimensions are both non-negative.
pub fn Size::new(
  width : Double,
  height : Double,
) -> Result[Size, GeometryError] {
  if !finite(width) || !finite(height) {
    Err(NonFiniteValue)
  } else if width < 0.0 || height < 0.0 {
    Err(NegativeExtent)
  } else {
    Ok({ width, height, })
  }
}

///|
pub fn Size::width(self : Size) -> Double {
  self.width
}

///|
pub fn Size::height(self : Size) -> Double {
  self.height
}

///|
/// Construct a rectangle, ensuring that its far edges remain finite.
pub fn Rect::new(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Result[Rect, GeometryError] {
  match (Point::new(x, y), Size::new(width, height)) {
    (Ok(origin), Ok(size)) => {
      let right = x + width
      let bottom = y + height
      if !finite(right) || !finite(bottom) {
        Err(BoundsOverflow)
      } else if (width > 0.0 && right <= x) || (height > 0.0 && bottom <= y) {
        Err(BoundsNotRepresentable)
      } else {
        Ok({ origin, size, })
      }
    }
    (Err(error), _) => Err(error)
    (_, Err(error)) => Err(error)
  }
}

///|
pub fn Rect::origin(self : Rect) -> Point {
  self.origin
}

///|
pub fn Rect::size(self : Rect) -> Size {
  self.size
}

///|
pub fn Rect::left(self : Rect) -> Double {
  self.origin.x
}

///|
pub fn Rect::top(self : Rect) -> Double {
  self.origin.y
}

///|
pub fn Rect::right(self : Rect) -> Double {
  self.origin.x + self.size.width
}

///|
pub fn Rect::bottom(self : Rect) -> Double {
  self.origin.y + self.size.height
}

///|
/// The closed rectangle contains points on its edges.
pub fn Rect::contains(self : Rect, point : Point) -> Bool {
  point.x >= self.left() &&
  point.x <= self.right() &&
  point.y >= self.top() &&
  point.y <= self.bottom()
}

///|
pub fn Rect::contains_rect(self : Rect, other : Rect) -> Bool {
  other.left() >= self.left() &&
  other.right() <= self.right() &&
  other.top() >= self.top() &&
  other.bottom() <= self.bottom()
}

///|
/// Return the intersection. Rectangles that touch at an edge have a
/// zero-width or zero-height intersection.
pub fn Rect::intersection(self : Rect, other : Rect) -> Rect? {
  let left = if self.left() > other.left() { self.left() } else { other.left() }
  let top = if self.top() > other.top() { self.top() } else { other.top() }
  let right = if self.right() < other.right() {
    self.right()
  } else {
    other.right()
  }
  let bottom = if self.bottom() < other.bottom() {
    self.bottom()
  } else {
    other.bottom()
  }
  if left > right || top > bottom {
    None
  } else {
    // The intersection is contained by both valid inputs, so its extent and
    // far edges are finite by construction.
    Some({
      origin: { x: left, y: top, },
      size: { width: right - left, height: bottom - top, },
    })
  }
}

///|
/// Return the smallest rectangle containing both inputs. Large spans that
/// cannot be represented as finite logical extents are reported as overflow.
pub fn Rect::union(self : Rect, other : Rect) -> Result[Rect, GeometryError] {
  let left = if self.left() < other.left() { self.left() } else { other.left() }
  let top = if self.top() < other.top() { self.top() } else { other.top() }
  let right = if self.right() > other.right() {
    self.right()
  } else {
    other.right()
  }
  let bottom = if self.bottom() > other.bottom() {
    self.bottom()
  } else {
    other.bottom()
  }
  let width = right - left
  let height = bottom - top
  if !finite(width) || !finite(height) {
    Err(BoundsOverflow)
  } else {
    match Rect::new(left, top, width, height) {
      Ok(result) if result.right() >= right && result.bottom() >= bottom =>
        Ok(result)
      Ok(_) => Err(BoundsNotRepresentable)
      Err(error) => Err(error)
    }
  }
}

///|
/// Scale a rectangle about the logical origin. Negative values mirror the
/// rectangle around the origin while keeping the resulting extents non-negative.
pub fn Rect::scaled(
  self : Rect,
  factor : Double,
) -> Result[Rect, GeometryError] {
  if !finite(factor) {
    Err(NonFiniteValue)
  } else {
    let x1 = self.left() * factor
    let x2 = self.right() * factor
    let y1 = self.top() * factor
    let y2 = self.bottom() * factor
    if !finite(x1) || !finite(x2) || !finite(y1) || !finite(y2) {
      Err(BoundsOverflow)
    } else {
      let left = if x1 < x2 { x1 } else { x2 }
      let right = if x1 > x2 { x1 } else { x2 }
      let top = if y1 < y2 { y1 } else { y2 }
      let bottom = if y1 > y2 { y1 } else { y2 }
      let width = right - left
      let height = bottom - top
      if !finite(width) || !finite(height) {
        Err(BoundsOverflow)
      } else {
        Rect::new(left, top, width, height)
      }
    }
  }
}

///|
pub fn Rect::translated(
  self : Rect,
  offset : Point,
) -> Result[Rect, GeometryError] {
  Rect::new(
    self.left() + offset.x,
    self.top() + offset.y,
    self.size.width,
    self.size.height,
  )
}

///|
/// Clamp a point to the nearest point on or inside this rectangle.
pub fn Rect::clamp_point(self : Rect, point : Point) -> Point {
  let x = if point.x < self.left() {
    self.left()
  } else if point.x > self.right() {
    self.right()
  } else {
    point.x
  }
  let y = if point.y < self.top() {
    self.top()
  } else if point.y > self.bottom() {
    self.bottom()
  } else {
    point.y
  }
  { x, y, }
}
