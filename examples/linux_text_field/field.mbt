///|
const FIELD_FONT_SIZE : Double = 18.0

///|
// Trusted style providers share system sans, logical size and the existing
// PangoFT2 context path with native drawing; the control checks copied output.
fn measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, @text_field.TextFieldError] {
  match @linux_text.measure(document, "sans", FIELD_FONT_SIZE) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.MeasurementFailed)
  }
}

///|
fn admit(
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @text_field.TextFieldError] {
  let (origin, bounds) = match
    @text_field.scene_text_run_geometry(measurement) {
    Ok(value) => value
    Err(_) => return Err(@text_field.UnsupportedLayout)
  }
  match
    @linux_text.admit_scene_text_run_at(
      document,
      FIELD_FONT_SIZE,
      origin,
      bounds,
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
  match @linux_text.hit_test(document, "sans", FIELD_FONT_SIZE, point) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.HitTestFailed)
  }
}

///|
fn make_field(
  text : String,
  bounds : @primitives.Rect,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let document = match @text.TextDocument::new(text) {
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
fn key_event(
  key : @primitives.Key,
  shift? : Bool = false,
) -> @primitives.InputEvent {
  @primitives.KeyPressed(
    key~,
    modifiers=@primitives.Modifiers::new(
      shift~,
      control=false,
      alt=false,
      meta=false,
    ),
    repeat=false,
  )
}

///|
fn change(
  field : @text_field.TextField,
  event : @primitives.InputEvent,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  match field.handle_input(event, measure, admit, hit) {
    Ok((value, _)) => Ok(value)
    Err(error) => Err(error)
  }
}

///|
fn fixture_line(
  label : String,
  field : @text_field.TextField,
  rejected : Bool,
) -> Unit {
  let scene = field_scene(field, 640.0, 240.0, 1.0).unwrap()
  println(
    "{\"label\":\"\{label}\",\"rejected\":\{rejected},\"revision\":\{field.revision()},\"anchor\":\{field.selection().anchor()},\"head\":\{field.selection().head()},\"scene\":\{scene.canonical_json()}}",
  )
}

///|
fn emit_fixtures() -> Unit {
  let bounds = @primitives.Rect::new(32.0, 28.0, 180.0, 44.0).unwrap()
  let start = match make_field("Hi 日本", bounds) {
    Ok(value) => value
    Err(@text_field.MeasurementFailed) => abort("fixture measurement failed")
    Err(@text_field.AdmissionFailed) => abort("fixture raster admission failed")
    Err(@text_field.UnsupportedLayout) => abort("fixture unsupported layout")
    Err(@text_field.InvalidBounds) => abort("fixture invalid bounds")
    Err(_) => abort("fixture field failed")
  }
  let start = start.with_focus(true).unwrap()
  let end = change(start, key_event(@primitives.End)).unwrap()
  fixture_line("end", end, false)
  let selected = change(end, key_event(@primitives.Home, shift=true)).unwrap()
  fixture_line("selected", selected, false)
  let edited = change(selected, @primitives.TextInput(text="Edited 日本")).unwrap()
  fixture_line("edited", edited, false)
  if change(edited, @primitives.TextInput(text="bad\nline")) is Ok(_) {
    abort("newline fixture unexpectedly admitted")
  }
  fixture_line("rejected_newline", edited, true)
  if change(edited, @primitives.TextInput(text="مرحبا")) is Ok(_) {
    abort("bidi fixture unexpectedly admitted")
  }
  fixture_line("rejected_bidi", edited, true)
  let mut long = ""
  for _index = 0; _index < 8; _index = _index + 1 {
    long = long + "Wide 日本 "
  }
  let scrolling = make_field(long, bounds).unwrap().with_focus(true).unwrap()
  let scrolling = change(scrolling, key_event(@primitives.End)).unwrap()
  fixture_line("scroll_end", scrolling, false)
  let blurred = scrolling.with_focus(false).unwrap()
  fixture_line("blurred", blurred, false)
  let j_start = make_field("jJ", bounds).unwrap().with_focus(true).unwrap()
  fixture_line("j_start", j_start, false)
  let accent_start = make_field("ÁA\u{301}", bounds)
    .unwrap()
    .with_focus(true)
    .unwrap()
  fixture_line("accent_start", accent_start, false)
  let j_scroll = make_field("Wide 日本 ".repeat(8) + "jJ", bounds)
    .unwrap()
    .with_focus(true)
    .unwrap()
  fixture_line(
    "j_scroll",
    change(j_scroll, key_event(@primitives.End)).unwrap(),
    false,
  )
  let accent_scroll = make_field("Wide ".repeat(20) + "ÁA\u{301}", bounds)
    .unwrap()
    .with_focus(true)
    .unwrap()
  fixture_line(
    "accent_scroll",
    change(accent_scroll, key_event(@primitives.End)).unwrap(),
    false,
  )

  // These are public immutable-control transitions, not fabricated paint
  // snapshots. Undo returns the directional pre-edit selection; End then
  // changes only the live selection before redo restores the edit's saved
  // postselection.
  let undo_selected = edited.undo(measure, admit).unwrap()
  fixture_line("undo_selected", undo_selected, false)
  let navigated = change(undo_selected, key_event(@primitives.End)).unwrap()
  let redo_edited = navigated.redo(measure, admit).unwrap()
  fixture_line("redo_edited", redo_edited, false)
}
