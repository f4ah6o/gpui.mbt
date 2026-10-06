///|
/// Errors from assembling the bounded field's existing scene primitives.
pub enum TextFieldPaintError {
  InvalidItemId
  GeometryFailure
  SceneFailure(@scene.SnapshotError)
} derive(Eq)

///|
pub extend TextFieldPaintError with Eq::{not_equal, equal}

///|
/// Build a hit-test/focus node; the owner keeps ElementTree focus in sync with
/// field focus and arms native input before accepting a new logical target.
pub fn TextField::element_node(
  self : TextField,
  parent : UInt64?,
) -> @element.ElementNode {
  @element.ElementNode::new(self.id(), parent, self.bounds()).with_focusable(
    true,
  )
}

///|
fn paint_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Result[@primitives.Rect, TextFieldPaintError] {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(rect) => Ok(rect)
    Err(_) => Err(GeometryFailure)
  }
}

///|
fn field_quad(
  id : UInt64,
  bounds : @primitives.Rect,
  color : @primitives.Color,
  clip : Int?,
) -> Result[@scene.SceneItem, TextFieldPaintError] {
  match
    @scene.SceneItem::quad(
      id,
      bounds,
      color,
      @scene.AffineTransform::identity(),
      1.0,
      clip,
    ) {
    Ok(item) => Ok(item)
    Err(error) => Err(SceneFailure(error))
  }
}

///|
pub fn scene_text_bounds(
  measurement : @text_layout.TextMeasurement,
) -> Result[@primitives.Rect, TextFieldPaintError] {
  let mut width = measurement.logical_rect().right()
  let mut height = measurement.logical_rect().bottom()
  if measurement.ink_rect().right() > width {
    width = measurement.ink_rect().right()
  }
  if measurement.ink_rect().bottom() > height {
    height = measurement.ink_rect().bottom()
  }
  for caret in measurement.carets() {
    if caret.is_cursor_position() && caret.strong().left() > width {
      width = caret.strong().left()
    }
  }
  // A separate caret quad supplies its1px width; do not enlarge the text mask
  // beyond the2048px text extent merely to make that caret visible.
  paint_rect(
    0.0,
    0.0,
    if width < 1.0 {
      1.0
    } else {
      width
    },
    if height < 1.0 {
      1.0
    } else {
      height
    },
  )
}

///|
/// Return the bounded run-local origin and clip rectangle used by field
/// admission and paint. The legacy `scene_text_bounds` API above intentionally
/// keeps its original logical-origin behavior for existing callers.
pub fn scene_text_run_geometry(
  measurement : @text_layout.TextMeasurement,
) -> Result[(@primitives.Point, @primitives.Rect), TextFieldPaintError] {
  match field_run_geometry(measurement) {
    Ok(value) => Ok(value)
    Err(_) => Err(GeometryFailure)
  }
}

///|
/// Emit a reusable field component in paint order. The caller reserves eight
/// item IDs from item_id_base and a unique clip-chain ID, then merges the
/// returned copied values into its SceneSnapshot. Fonts stay system-sans.
pub fn TextField::paint_items(
  self : TextField,
  item_id_base : UInt64,
  clip_chain_id : Int,
) -> Result[(@scene.ClipChain, Array[@scene.SceneItem]), TextFieldPaintError] {
  let maximum_base : UInt64 = 18446744073709551608
  if item_id_base > maximum_base {
    return Err(InvalidItemId)
  }
  let bounds = self.bounds()
  let content = self.content_bounds()
  let clip = @scene.ClipChain::new(clip_chain_id, [content])
  let items : Array[@scene.SceneItem] = []
  let white = @primitives.Color::rgba(255, 255, 255, 255).unwrap()
  let black = @primitives.Color::rgba(20, 24, 30, 255).unwrap()
  let border = if self.is_focused() {
    @primitives.Color::rgba(55, 105, 220, 255).unwrap()
  } else {
    @primitives.Color::rgba(130, 140, 150, 255).unwrap()
  }
  match field_quad(item_id_base, bounds, white, None) {
    Ok(item) => items.push(item)
    Err(error) => return Err(error)
  }
  let edges = [
    (bounds.left(), bounds.top(), bounds.size().width(), 1.0),
    (bounds.left(), bounds.bottom() - 1.0, bounds.size().width(), 1.0),
    (bounds.left(), bounds.top(), 1.0, bounds.size().height()),
    (bounds.right() - 1.0, bounds.top(), 1.0, bounds.size().height()),
  ]
  let mut edge_index = 0
  for edge in edges {
    let (x, y, width, height) = edge
    let rect = match paint_rect(x, y, width, height) {
      Ok(rect) => rect
      Err(error) => return Err(error)
    }
    match
      field_quad(item_id_base + edge_index.to_uint64() + 1, rect, border, None) {
      Ok(item) => items.push(item)
      Err(error) => return Err(error)
    }
    edge_index += 1
  }
  let selection = self.selection()
  let anchor = self.measurement().caret_at(selection.anchor()).unwrap().strong()
  let head = self.measurement().caret_at(selection.head()).unwrap().strong()
  let origin_x = content.left() - self.scroll_offset()
  let (text_origin, text_bounds) = match
    scene_text_run_geometry(self.measurement()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !selection.is_collapsed() {
    let left = if anchor.left() < head.left() {
      anchor.left()
    } else {
      head.left()
    }
    let right = if anchor.left() > head.left() {
      anchor.left()
    } else {
      head.left()
    }
    let rect = match
      paint_rect(
        origin_x + text_origin.x() + left,
        content.top() +
        text_origin.y() +
        self.measurement().logical_rect().top(),
        right - left,
        self.measurement().logical_rect().size().height(),
      ) {
      Ok(rect) => rect
      Err(error) => return Err(error)
    }
    let color = if self.is_focused() {
      @primitives.Color::rgba(65, 105, 225, 80).unwrap()
    } else {
      @primitives.Color::rgba(140, 150, 160, 64).unwrap()
    }
    match field_quad(item_id_base + 5, rect, color, Some(clip_chain_id)) {
      Ok(item) => items.push(item)
      Err(error) => return Err(error)
    }
  }
  let transform = match
    @scene.AffineTransform::new(1.0, 0.0, 0.0, 1.0, origin_x, content.top()) {
    Ok(value) => value
    Err(error) => return Err(SceneFailure(error))
  }
  match
    @scene.SceneItem::text_run(
      item_id_base + 6,
      text_bounds,
      text_origin,
      self.document().text(),
      self.font_size(),
      black,
      transform,
      1.0,
      Some(clip_chain_id),
    ) {
    Ok(item) => items.push(item)
    Err(error) => return Err(SceneFailure(error))
  }
  if self.is_focused() {
    let rect = match
      paint_rect(
        origin_x + text_origin.x() + head.left(),
        content.top() + text_origin.y() + head.top(),
        1.0,
        head.size().height(),
      ) {
      Ok(rect) => rect
      Err(error) => return Err(error)
    }
    match field_quad(item_id_base + 7, rect, black, Some(clip_chain_id)) {
      Ok(item) => items.push(item)
      Err(error) => return Err(error)
    }
  }
  Ok((clip, items))
}
