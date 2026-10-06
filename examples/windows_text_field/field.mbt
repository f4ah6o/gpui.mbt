///|
const FIELD_FONT_FAMILY : String = "Segoe UI"

///|
const FIELD_FONT_SIZE : Double = 18.0

///|
fn measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, @text_field.TextFieldError] {
  match @windows_text.measure(document, FIELD_FONT_FAMILY, FIELD_FONT_SIZE) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.MeasurementFailed)
  }
}

///|
fn admit(
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @text_field.TextFieldError] {
  let (origin, clip_rect) = match
    @text_field.scene_text_run_geometry(measurement) {
    Ok(value) => value
    Err(_) => return Err(@text_field.UnsupportedLayout)
  }
  match
    @windows_text.admit_scene_text_run_at(
      document,
      FIELD_FONT_SIZE,
      origin,
      clip_rect,
    ) {
    Ok(_) => Ok(())
    Err(_) => Err(@text_field.AdmissionFailed)
  }
}

///|
fn hit(
  document : @text.TextDocument,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, @text_field.TextFieldError] {
  match
    @windows_text.hit_test(document, FIELD_FONT_FAMILY, FIELD_FONT_SIZE, point) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.HitTestFailed)
  }
}

///|
fn make_field(
  value : String,
  bounds : @primitives.Rect,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let document = match @text.TextDocument::new(value) {
    Ok(value) => value
    Err(_) => return Err(@text_field.MalformedText)
  }
  @text_field.TextField::new(
    2,
    bounds,
    FIELD_FONT_SIZE,
    document,
    measure,
    admit,
  )
}

///|
fn field_scene(
  field : @text_field.TextField,
  width : Double,
  height : Double,
  scale : Double,
) -> Result[@scene.SceneSnapshot, @text_field.TextFieldError] {
  let viewport = match @primitives.Rect::new(0.0, 0.0, width, height) {
    Ok(value) => value
    Err(_) => return Err(@text_field.InvalidBounds)
  }
  let background = match
    @scene.SceneItem::quad(
      1,
      viewport,
      @primitives.Color::rgba(24, 28, 36, 255).unwrap(),
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(value) => value
    Err(_) => return Err(@text_field.UnsupportedLayout)
  }
  let (clip, painted) = match field.paint_items(100, 7) {
    Ok(value) => value
    Err(_) => return Err(@text_field.UnsupportedLayout)
  }
  let items = [background]
  for item in painted {
    items.push(item)
  }
  if field.marked_range() is Some(marked) {
    let measurement = field.measurement()
    let start = match measurement.caret_at(marked.start()) {
      Ok(value) if value.is_cursor_position() => value.strong()
      _ => return Err(@text_field.InvalidSelection)
    }
    let end = match measurement.caret_at(marked.end()) {
      Ok(value) if value.is_cursor_position() => value.strong()
      _ => return Err(@text_field.InvalidSelection)
    }
    if end.left() < start.left() {
      return Err(@text_field.UnsupportedLayout)
    }
    let (origin, _) = @text_field.scene_text_run_geometry(measurement).unwrap()
    let underline = @primitives.Rect::new(
      field.content_bounds().left() -
      field.scroll_offset() +
      origin.x() +
      start.left(),
      field.content_bounds().top() + origin.y() + start.bottom() - 1.0,
      end.left() - start.left(),
      1.0,
    ).unwrap()
    items.push(
      @scene.SceneItem::quad(
        108,
        underline,
        @primitives.Color::rgba(20, 24, 30, 255).unwrap(),
        @scene.AffineTransform::identity(),
        1.0,
        Some(7),
      ).unwrap(),
    )
  }
  match @scene.SceneSnapshot::new(viewport, scale, [], [clip], items) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.UnsupportedLayout)
  }
}

///|
fn field_tree(
  field : @text_field.TextField,
  width : Double,
  height : Double,
) -> @element.ElementTree {
  let viewport = @primitives.Rect::new(0.0, 0.0, width, height).unwrap()
  let root = @element.ElementNode::new(1, None, viewport)
  let tree = @element.ElementTree::new([root, field.element_node(Some(1))]).unwrap()
  if field.is_focused() {
    tree.with_focus(field.id()).unwrap()
  } else {
    tree
  }
}

///|
fn route_input(
  field : @text_field.TextField,
  event : @primitives.InputEvent,
  width : Double,
  height : Double,
) -> Result[
  (@text_field.TextField, @text_field.TextFieldAction?),
  @text_field.TextFieldError,
] {
  let tree = field_tree(field, width, height)
  let delivered : Ref[
    Result[
      (@text_field.TextField, @text_field.TextFieldAction?),
      @text_field.TextFieldError,
    ]?,
  ] = Ref(None)
  ignore(
    tree.dispatch_input_with(event, (context, event) => {
      if context.phase() == @element.Bubble &&
        context.current_target() == field.id() {
        delivered.val = Some(field.handle_input(event, measure, admit, hit))
      }
      Ok(())
    }),
  )
  match delivered.val {
    Some(value) => value
    None => Ok((field, None))
  }
}

///|
fn native_field_bounds(
  width : Double,
  height : Double,
) -> Result[@primitives.Rect, @text_field.TextFieldError] {
  let field_width = if width > 560.0 { 512.0 } else { width - 48.0 }
  if field_width < 16.0 || height < 88.0 {
    return Err(@text_field.InvalidBounds)
  }
  match @primitives.Rect::new(24.0, 28.0, field_width, 44.0) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.InvalidBounds)
  }
}
