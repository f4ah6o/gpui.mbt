///|
/// Shared bounded list painter. The application supplies its trusted native
/// label renderer; selection, row geometry and visible bounds are reusable.
/// The search field is painted with its existing TextField.paint_items.
pub fn Picker::paint_items(
  self : Picker,
  base_id : UInt64,
  clip_id : Int,
  bounds : @primitives.Rect,
  row_height : Double,
  label : (UInt64, CommandMetadata, @primitives.Point, Int) -> Result[
    @scene.SceneItem,
    PaletteError,
  ],
) -> Result[(@scene.ClipChain, Array[@scene.SceneItem]), PaletteError] {
  if base_id == 0UL ||
    base_id > 0xffffffffffffffffUL - 16UL ||
    clip_id <= 0 ||
    row_height.is_nan() ||
    row_height.is_inf() ||
    row_height <= 0.0 ||
    row_height * VISIBLE_ROWS.to_double() > bounds.size().height() {
    return Err(InvalidField)
  }
  let clip = @scene.ClipChain::new(clip_id, [bounds])
  let items : Array[@scene.SceneItem] = []
  let visible = self.visible_commands()
  for offset = 0; offset < visible.length(); offset = offset + 1 {
    let y = bounds.top() + offset.to_double() * row_height
    let row = match
      @primitives.Rect::new(bounds.left(), y, bounds.size().width(), row_height) {
      Ok(value) => value
      Err(_) => return Err(InvalidField)
    }
    let selected = self.active == Some(self.visible_start() + offset)
    let color = @primitives.Color::rgba(
      if selected {
        48
      } else {
        30
      },
      if selected {
        74
      } else {
        34
      },
      if selected {
        114
      } else {
        44
      },
      255,
    ).unwrap()
    let id = base_id + (offset * 2).to_uint64()
    let quad = match
      @scene.SceneItem::quad(
        id,
        row,
        color,
        @scene.AffineTransform::identity(),
        1.0,
        Some(clip_id),
      ) {
      Ok(value) => value
      Err(_) => return Err(InvalidField)
    }
    let position = match
      @primitives.Point::new(row.left() + 8.0, row.top() + 6.0) {
      Ok(value) => value
      Err(_) => return Err(InvalidField)
    }
    let text = match label(id + 1UL, visible[offset], position, clip_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if text.id() != id + 1UL || text.clip_chain_id() != Some(clip_id) {
      return Err(InvalidField)
    }
    items.push(quad)
    items.push(text)
  }
  Ok((clip, items))
}
