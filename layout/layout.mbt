///|
/// Errors produced by the platform-neutral M2 flex-line layout foundation.
pub enum LayoutError {
  NonFiniteValue
  NegativeValue
  InvalidMinMax
  IndefinitePercentage
  DuplicateId
  GeometryFailure
} derive(Eq)

///|
pub extend LayoutError with Eq::{not_equal, equal}

///|
/// Main-axis flow for a one-dimensional flex container.
pub enum FlowDirection {
  Row
  Column
} derive(Eq)

///|
pub extend FlowDirection with Eq::{not_equal, equal}

///|
/// Main-axis placement of unused positive space.
pub enum JustifyContent {
  Start
  Center
  End
} derive(Eq)

///|
pub extend JustifyContent with Eq::{not_equal, equal}

///|
/// Cross-axis placement for all items in this first bounded subset.
pub enum AlignItems {
  Start
  Center
  End
  Stretch
} derive(Eq)

///|
pub extend AlignItems with Eq::{not_equal, equal}

///|
/// A logical dimension. Percent values use 1.0 == 100%.
pub enum Dimension {
  Auto
  Points(Double)
  Percent(Double)
} derive(Eq)

///|
pub extend Dimension with Eq::{not_equal, equal}

///|
pub fn Dimension::auto() -> Dimension {
  Auto
}

///|
pub fn Dimension::points(value : Double) -> Result[Dimension, LayoutError] {
  if !finite(value) {
    Err(NonFiniteValue)
  } else if value < 0.0 {
    Err(NegativeValue)
  } else {
    Ok(Points(value))
  }
}

///|
pub fn Dimension::percent(value : Double) -> Result[Dimension, LayoutError] {
  if !finite(value) {
    Err(NonFiniteValue)
  } else if value < 0.0 {
    Err(NegativeValue)
  } else {
    Ok(Percent(value))
  }
}

///|
/// Resolve a logical dimension. Auto remains unresolved; percentages require
/// a definite containing extent.
pub fn resolve_dimension(
  dimension : Dimension,
  containing : Double?,
) -> Result[Double?, LayoutError] {
  match dimension {
    Auto => Ok(None)
    Points(value) =>
      if !finite(value) {
        Err(NonFiniteValue)
      } else if value < 0.0 {
        Err(NegativeValue)
      } else {
        Ok(Some(value))
      }
    Percent(ratio) =>
      if !finite(ratio) {
        Err(NonFiniteValue)
      } else if ratio < 0.0 {
        Err(NegativeValue)
      } else {
        match containing {
          None => Err(IndefinitePercentage)
          Some(base) =>
            if !finite(base) {
              Err(NonFiniteValue)
            } else if base < 0.0 {
              Err(NegativeValue)
            } else {
              let value = base * ratio
              if finite(value) {
                Ok(Some(value))
              } else {
                Err(NonFiniteValue)
              }
            }
        }
      }
  }
}

///|
/// Logical padding/border insets.
pub struct Insets {
  top : Double
  right : Double
  bottom : Double
  left : Double
} derive(Eq)

///|
pub extend Insets with Eq::{not_equal, equal}

///|
pub fn Insets::zero() -> Insets {
  { top: 0.0, right: 0.0, bottom: 0.0, left: 0.0 }
}

///|
pub fn Insets::all(value : Double) -> Result[Insets, LayoutError] {
  Insets::new(value, value, value, value)
}

///|
pub fn Insets::new(
  top : Double,
  right : Double,
  bottom : Double,
  left : Double,
) -> Result[Insets, LayoutError] {
  if !finite(top) || !finite(right) || !finite(bottom) || !finite(left) {
    Err(NonFiniteValue)
  } else if top < 0.0 || right < 0.0 || bottom < 0.0 || left < 0.0 {
    Err(NegativeValue)
  } else {
    Ok({ top, right, bottom, left })
  }
}

///|
pub fn Insets::top(self : Insets) -> Double {
  self.top
}

///|
pub fn Insets::right(self : Insets) -> Double {
  self.right
}

///|
pub fn Insets::bottom(self : Insets) -> Double {
  self.bottom
}

///|
pub fn Insets::left(self : Insets) -> Double {
  self.left
}

///|
/// One child participating in a flex line. Auto main/cross dimensions use the
/// intrinsic size unless container alignment stretches an auto cross dimension.
pub struct FlexItem {
  id : UInt64
  main : Dimension
  cross : Dimension
  intrinsic : @primitives.Size
  grow : Double
  shrink : Double
  min_main : Double
  max_main : Double?
  min_cross : Double
  max_cross : Double?
}

///|
pub fn FlexItem::new(
  id : UInt64,
  main : Dimension,
  cross : Dimension,
  intrinsic : @primitives.Size,
) -> FlexItem {
  {
    id,
    main,
    cross,
    intrinsic,
    grow: 0.0,
    shrink: 1.0,
    min_main: 0.0,
    max_main: None,
    min_cross: 0.0,
    max_cross: None,
  }
}

///|
pub fn FlexItem::id(self : FlexItem) -> UInt64 {
  self.id
}

///|
pub fn FlexItem::with_flex(
  self : FlexItem,
  grow : Double,
  shrink : Double,
) -> Result[FlexItem, LayoutError] {
  if !finite(grow) || !finite(shrink) {
    Err(NonFiniteValue)
  } else if grow < 0.0 || shrink < 0.0 {
    Err(NegativeValue)
  } else {
    Ok({
      id: self.id,
      main: self.main,
      cross: self.cross,
      intrinsic: self.intrinsic,
      grow,
      shrink,
      min_main: self.min_main,
      max_main: self.max_main,
      min_cross: self.min_cross,
      max_cross: self.max_cross,
    })
  }
}

///|
pub fn FlexItem::with_main_limits(
  self : FlexItem,
  min : Double,
  max : Double?,
) -> Result[FlexItem, LayoutError] {
  if !valid_limits(min, max) {
    Err(InvalidMinMax)
  } else {
    Ok({
      id: self.id,
      main: self.main,
      cross: self.cross,
      intrinsic: self.intrinsic,
      grow: self.grow,
      shrink: self.shrink,
      min_main: min,
      max_main: max,
      min_cross: self.min_cross,
      max_cross: self.max_cross,
    })
  }
}

///|
pub fn FlexItem::with_cross_limits(
  self : FlexItem,
  min : Double,
  max : Double?,
) -> Result[FlexItem, LayoutError] {
  if !valid_limits(min, max) {
    Err(InvalidMinMax)
  } else {
    Ok({
      id: self.id,
      main: self.main,
      cross: self.cross,
      intrinsic: self.intrinsic,
      grow: self.grow,
      shrink: self.shrink,
      min_main: self.min_main,
      max_main: self.max_main,
      min_cross: min,
      max_cross: max,
    })
  }
}

///|
/// A definite flex container. Auto container sizing is deliberately left for
/// the later recursive tree layer; percent child dimensions are resolvable here.
pub struct FlexContainer {
  direction : FlowDirection
  size : @primitives.Size
  gap : Double
  padding : Insets
  border : Insets
  justify : JustifyContent
  align : AlignItems
}

///|
pub fn FlexContainer::new(
  direction : FlowDirection,
  size : @primitives.Size,
) -> FlexContainer {
  {
    direction,
    size,
    gap: 0.0,
    padding: Insets::zero(),
    border: Insets::zero(),
    justify: Start,
    align: AlignItems::Start,
  }
}

///|
pub fn FlexContainer::with_gap(
  self : FlexContainer,
  gap : Double,
) -> Result[FlexContainer, LayoutError] {
  if !finite(gap) {
    Err(NonFiniteValue)
  } else if gap < 0.0 {
    Err(NegativeValue)
  } else {
    Ok({
      direction: self.direction,
      size: self.size,
      gap,
      padding: self.padding,
      border: self.border,
      justify: self.justify,
      align: self.align,
    })
  }
}

///|
pub fn FlexContainer::with_insets(
  self : FlexContainer,
  padding : Insets,
  border : Insets,
) -> FlexContainer {
  {
    direction: self.direction,
    size: self.size,
    gap: self.gap,
    padding,
    border,
    justify: self.justify,
    align: self.align,
  }
}

///|
pub fn FlexContainer::with_justify(
  self : FlexContainer,
  justify : JustifyContent,
) -> FlexContainer {
  {
    direction: self.direction,
    size: self.size,
    gap: self.gap,
    padding: self.padding,
    border: self.border,
    justify,
    align: self.align,
  }
}

///|
pub fn FlexContainer::with_align(
  self : FlexContainer,
  align : AlignItems,
) -> FlexContainer {
  {
    direction: self.direction,
    size: self.size,
    gap: self.gap,
    padding: self.padding,
    border: self.border,
    justify: self.justify,
    align,
  }
}

///|
pub struct LayoutBox {
  id : UInt64
  bounds : @primitives.Rect
  overflow : Bool
}

///|
pub fn LayoutBox::id(self : LayoutBox) -> UInt64 {
  self.id
}

///|
pub fn LayoutBox::bounds(self : LayoutBox) -> @primitives.Rect {
  self.bounds
}

///|
pub fn LayoutBox::overflow(self : LayoutBox) -> Bool {
  self.overflow
}

///|
pub struct FlexLayout {
  content_bounds : @primitives.Rect
  items : Array[LayoutBox]
  overflow : Bool
}

///|
pub fn FlexLayout::content_bounds(self : FlexLayout) -> @primitives.Rect {
  self.content_bounds
}

///|
pub fn FlexLayout::items(self : FlexLayout) -> Array[LayoutBox] {
  self.items
}

///|
pub fn FlexLayout::overflow(self : FlexLayout) -> Bool {
  self.overflow
}

///|
priv struct PreparedItem {
  item : FlexItem
  basis : Double
  cross : Double
  weight : Double
}

///|
/// Lay out one deterministic row/column flex line. Positive free space is
/// distributed by grow factors; negative free space by shrink*basis. Each
/// result is clamped once to min/max, matching the documented first subset.
pub fn layout_flex(
  container : FlexContainer,
  items : Array[FlexItem],
) -> Result[FlexLayout, LayoutError] {
  if has_duplicate_ids(items) {
    Err(DuplicateId)
  } else {
    let horizontal = container.padding.left + container.padding.right +
      container.border.left + container.border.right
    let vertical = container.padding.top + container.padding.bottom +
      container.border.top + container.border.bottom
    if !finite(horizontal) || !finite(vertical) {
      Err(NonFiniteValue)
    } else {
      let inner_width = non_negative(container.size.width() - horizontal)
      let inner_height = non_negative(container.size.height() - vertical)
      let inner_x = container.border.left + container.padding.left
      let inner_y = container.border.top + container.padding.top
      match @primitives.Rect::new(inner_x, inner_y, inner_width, inner_height) {
        Err(_) => Err(GeometryFailure)
        Ok(content_bounds) => {
          let main_extent = if container.direction is Row {
            inner_width
          } else {
            inner_height
          }
          let cross_extent = if container.direction is Row {
            inner_height
          } else {
            inner_width
          }
          match prepare_items(container, items, main_extent, cross_extent) {
            Err(error) => Err(error)
            Ok(prepared) =>
              place_items(
                container,
                prepared,
                content_bounds,
                main_extent,
                cross_extent,
              )
          }
        }
      }
    }
  }
}

///|
fn prepare_items(
  container : FlexContainer,
  items : Array[FlexItem],
  main_extent : Double,
  cross_extent : Double,
) -> Result[Array[PreparedItem], LayoutError] {
  let prepared : Array[PreparedItem] = []
  let mut error : LayoutError? = None
  let mut index = 0
  while index < items.length() {
    let item = items[index]
    match error {
      Some(_) => ()
      None =>
        if !valid_limits(item.min_main, item.max_main) ||
          !valid_limits(item.min_cross, item.max_cross) ||
          !finite(item.grow) ||
          !finite(item.shrink) {
          error = Some(InvalidMinMax)
        } else if item.grow < 0.0 || item.shrink < 0.0 {
          error = Some(NegativeValue)
        } else {
          match (
            resolve_dimension(item.main, Some(main_extent)),
            resolve_dimension(item.cross, Some(cross_extent)),
          ) {
            (Err(value), _) => error = Some(value)
            (_, Err(value)) => error = Some(value)
            (Ok(main_value), Ok(cross_value)) => {
              let intrinsic_main = if container.direction is Row {
                item.intrinsic.width()
              } else {
                item.intrinsic.height()
              }
              let intrinsic_cross = if container.direction is Row {
                item.intrinsic.height()
              } else {
                item.intrinsic.width()
              }
              let basis = match main_value {
                Some(value) => value
                None => intrinsic_main
              }
              let cross = match cross_value {
                Some(value) => value
                None =>
                  if container.align is Stretch {
                    cross_extent
                  } else {
                    intrinsic_cross
                  }
              }
              prepared.push({
                item,
                basis,
                cross: clamp_once(cross, item.min_cross, item.max_cross),
                weight: item.shrink * basis,
              })
            }
          }
        }
    }
    index += 1
  }
  match error {
    Some(value) => Err(value)
    None => Ok(prepared)
  }
}

///|
fn place_items(
  container : FlexContainer,
  prepared : Array[PreparedItem],
  content_bounds : @primitives.Rect,
  main_extent : Double,
  cross_extent : Double,
) -> Result[FlexLayout, LayoutError] {
  let count = prepared.length()
  let gaps = if count > 1 {
    (count - 1).to_double() * container.gap
  } else {
    0.0
  }
  if !finite(gaps) {
    Err(NonFiniteValue)
  } else {
    let mut basis_total = 0.0
    let mut grow_total = 0.0
    let mut shrink_total = 0.0
    for entry in prepared {
      basis_total += entry.basis
      grow_total += entry.item.grow
      shrink_total += entry.weight
    }
    let free = main_extent - gaps - basis_total
    let resolved : Array[Double] = []
    let mut used = gaps
    for entry in prepared {
      let proposed = if free > 0.0 && grow_total > 0.0 {
        entry.basis + free * entry.item.grow / grow_total
      } else if free < 0.0 && shrink_total > 0.0 {
        entry.basis + free * entry.weight / shrink_total
      } else {
        entry.basis
      }
      let final_main = clamp_once(
        non_negative(proposed),
        entry.item.min_main,
        entry.item.max_main,
      )
      resolved.push(final_main)
      used += final_main
    }
    if !finite(used) {
      Err(NonFiniteValue)
    } else {
      let positive_leftover = if main_extent > used {
        main_extent - used
      } else {
        0.0
      }
      let mut cursor = match container.justify {
        JustifyContent::Start => 0.0
        Center => positive_leftover / 2.0
        End => positive_leftover
      }
      let output : Array[LayoutBox] = []
      let mut any_overflow = used > main_extent
      let mut error : LayoutError? = None
      let mut index = 0
      while index < prepared.length() {
        let entry = prepared[index]
        let main_size = resolved[index]
        let cross_size = entry.cross
        let cross_offset = if cross_size >= cross_extent {
          0.0
        } else {
          match container.align {
            AlignItems::Start | Stretch => 0.0
            AlignItems::Center => (cross_extent - cross_size) / 2.0
            AlignItems::End => cross_extent - cross_size
          }
        }
        let x = if container.direction is Row {
          content_bounds.left() + cursor
        } else {
          content_bounds.left() + cross_offset
        }
        let y = if container.direction is Row {
          content_bounds.top() + cross_offset
        } else {
          content_bounds.top() + cursor
        }
        let width = if container.direction is Row {
          main_size
        } else {
          cross_size
        }
        let height = if container.direction is Row {
          cross_size
        } else {
          main_size
        }
        match @primitives.Rect::new(x, y, width, height) {
          Err(_) => error = Some(GeometryFailure)
          Ok(bounds) => {
            let overflow = cursor + main_size > main_extent ||
              cross_size > cross_extent
            if overflow {
              any_overflow = true
            }
            output.push({ id: entry.item.id, bounds, overflow })
          }
        }
        cursor += main_size + container.gap
        index += 1
      }
      match error {
        Some(value) => Err(value)
        None =>
          Ok({
            content_bounds,
            items: output,
            overflow: any_overflow,
          })
      }
    }
  }
}

///|
fn finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn non_negative(value : Double) -> Double {
  if value > 0.0 {
    value
  } else {
    0.0
  }
}

///|
fn valid_limits(min : Double, max : Double?) -> Bool {
  if !finite(min) || min < 0.0 {
    false
  } else {
    match max {
      None => true
      Some(value) => finite(value) && value >= min
    }
  }
}

///|
fn clamp_once(value : Double, min : Double, max : Double?) -> Double {
  let lower = if value < min {
    min
  } else {
    value
  }
  match max {
    Some(limit) if lower > limit => limit
    _ => lower
  }
}

///|
fn has_duplicate_ids(items : Array[FlexItem]) -> Bool {
  let mut outer = 0
  let mut duplicate = false
  while outer < items.length() && !duplicate {
    let mut inner = outer + 1
    while inner < items.length() && !duplicate {
      if items[outer].id == items[inner].id {
        duplicate = true
      }
      inner += 1
    }
    outer += 1
  }
  duplicate
}
