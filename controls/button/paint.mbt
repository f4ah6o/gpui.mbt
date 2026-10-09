///|
/// Errors from assembling a button's bounded scene items.
pub(all) enum ButtonPaintError {
  InvalidItemId
  InvalidBounds
  SceneFailure(@scene.SnapshotError)
} derive(Eq)

///|
pub extend ButtonPaintError with Eq::{not_equal, equal}

///|
fn button_paint_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Result[@primitives.Rect, ButtonPaintError] {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidBounds)
  }
}

///|
fn button_paint_quad(
  id : UInt64,
  bounds : @primitives.Rect,
  color : @primitives.Color,
) -> Result[@scene.SceneItem, ButtonPaintError] {
  match
    @scene.SceneItem::quad(
      id,
      bounds,
      color,
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(value) => Ok(value)
    Err(error) => Err(SceneFailure(error))
  }
}

///|
fn button_paint_color(r : Int, g : Int, b : Int) -> @primitives.Color {
  @primitives.Color::rgba(r, g, b, 255).unwrap()
}

///|
/// Emit a compact frame contribution: border, fill and a real host-font text
/// item. The owner reserves three adjacent item IDs and merges the copied items
/// into its SceneSnapshot. This carries no native accessibility semantics.
pub fn Button::paint_items(
  self : Button,
  item_id_base : UInt64,
) -> Result[Array[@scene.SceneItem], ButtonPaintError] {
  let maximum_base : UInt64 = 18446744073709551612
  if item_id_base == 0UL || item_id_base > maximum_base {
    return Err(InvalidItemId)
  }
  if !button_bounds_valid(self.bounds) {
    return Err(InvalidBounds)
  }
  let border = if !self.enabled {
    button_paint_color(100, 106, 114)
  } else if self.focused {
    button_paint_color(98, 170, 255)
  } else {
    button_paint_color(102, 126, 150)
  }
  let fill = if !self.enabled {
    button_paint_color(47, 52, 60)
  } else if self.loading {
    button_paint_color(55, 70, 88)
  } else if self.is_pressed() {
    button_paint_color(35, 77, 119)
  } else if self.hovered {
    button_paint_color(48, 91, 137)
  } else {
    button_paint_color(42, 71, 101)
  }
  let foreground = if !self.enabled {
    button_paint_color(166, 171, 178)
  } else {
    button_paint_color(242, 246, 250)
  }
  let bounds = self.bounds
  let border_item = match button_paint_quad(item_id_base, bounds, border) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let inset = if self.focused { 2.0 } else { 1.0 }
  let fill_bounds = match
    button_paint_rect(
      bounds.left() + inset,
      bounds.top() + inset,
      bounds.size().width() - inset * 2.0,
      bounds.size().height() - inset * 2.0,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let fill_item = match
    button_paint_quad(item_id_base + 1UL, fill_bounds, fill) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let text_bounds = match
    button_paint_rect(
      fill_bounds.left() + 8.0,
      fill_bounds.top() + 2.0,
      fill_bounds.size().width() - 16.0,
      fill_bounds.size().height() - 4.0,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let label_item = match
    @scene.SceneItem::text(
      item_id_base + 2UL,
      text_bounds,
      self.label,
      16.0,
      foreground,
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(SceneFailure(error))
  }
  Ok([border_item, fill_item, label_item])
}
