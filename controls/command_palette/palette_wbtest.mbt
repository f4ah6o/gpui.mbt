///|
fn palette_test_document(text : String) -> @text.TextDocument {
  match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => abort("test text should be valid")
  }
}

///|
fn palette_test_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("test rectangle should be valid")
  }
}

///|
fn palette_test_offsets(document : @text.TextDocument) -> Array[Int] {
  let offsets = [0]
  let mut current = 0
  for scalar in document.text().iter() {
    current += if scalar.to_int() > 0xFFFF { 2 } else { 1 }
    offsets.push(current)
  }
  offsets
}

///|
/// A small scripted layout fixture. These cursor flags are observations for
/// the named sample strings only, not a Unicode segmentation implementation.
fn palette_test_cursor_stop(text : String, offset : Int) -> Bool {
  match text {
    "a\u{301}b" => offset != 1
    "a\u{301}" => offset == 0 || offset == 2
    "👩\u{200D}👩" => offset == 0 || offset == 5
    "✈\u{FE0F}" => offset == 0 || offset == 2
    "a👩\u{200D}👩" => offset == 0 || offset == 1 || offset == 6
    _ => true
  }
}

///|
fn palette_test_measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, @text_field.TextFieldError] {
  let offsets = palette_test_offsets(document)
  let carets = []
  for i = 0; i < offsets.length(); i = i + 1 {
    let x = i.to_double() * 8.0
    let offset = offsets[i]
    let caret = match
      @text_layout.CaretGeometry::new(
        offset,
        palette_test_cursor_stop(document.text(), offset),
        palette_test_rect(x, 0.0, 0.0, 16.0),
        palette_test_rect(x, 0.0, 0.0, 16.0),
      ) {
      Ok(value) => value
      Err(_) => return Err(@text_field.UnsupportedLayout)
    }
    carets.push(caret)
  }
  match
    @text_layout.TextMeasurement::new(
      document,
      palette_test_rect(
        0.0,
        0.0,
        (offsets.length() - 1).to_double() * 8.0,
        20.0,
      ),
      palette_test_rect(
        0.0,
        0.0,
        (offsets.length() - 1).to_double() * 8.0,
        20.0,
      ),
      14.0,
      1,
      0,
      carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.UnsupportedLayout)
  }
}

///|
fn palette_test_admit(
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @text_field.TextFieldError] {
  if measurement.document() == document {
    Ok(())
  } else {
    Err(@text_field.AdmissionFailed)
  }
}

///|
fn palette_test_hit(
  document : @text.TextDocument,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, @text_field.TextFieldError] {
  let offsets = palette_test_offsets(document)
  let mut nearest_index = 0
  let mut nearest_x = 0.0
  let mut nearest_distance = 1.0e300
  for i = 0; i < offsets.length(); i = i + 1 {
    let x = i.to_double() * 8.0
    let distance = if x >= point.x() { x - point.x() } else { point.x() - x }
    if distance < nearest_distance {
      nearest_index = i
      nearest_x = x
      nearest_distance = distance
    }
  }
  ignore(nearest_x)
  let offset = offsets[nearest_index]
  match @text_layout.TextHit::new(document, offset, 0, offset, true, true) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.HitTestFailed)
  }
}

///|
fn palette_test_field() -> @text_field.TextField {
  @text_field.TextField::new(
    2,
    palette_test_rect(0.0, 0.0, 400.0, 36.0),
    18.0,
    palette_test_document(""),
    palette_test_measure,
    palette_test_admit,
  ).unwrap()
}

///|
fn palette_test_key(
  key : @primitives.Key,
  repeat? : Bool = false,
) -> @primitives.InputEvent {
  @primitives.KeyPressed(key~, modifiers=@primitives.Modifiers::none(), repeat~)
}

///|
fn palette_test_binding(
  id : String,
  callback : () -> Unit,
) -> @capability.GuiBinding[Unit, Unit] {
  let descriptor = @capability.Descriptor::new(
    id,
    id,
    "palette fixture",
    @capability.Command,
    @capability.Schema::unit(),
    @capability.Schema::unit(),
    @capability.StateChange,
    false,
    @capability.Local,
    None,
    1,
  ).unwrap()
  @capability.TypedCapability::new(
    descriptor,
    _ => Ok(()),
    _ => Ok(@capability.Value::unit()),
    _ => {
      callback()
      Ok(())
    },
    () => Ok(()),
    _ => Ok(()),
  ).gui_binding()
}

///|
fn palette_test_tree() -> Ref[@element.ElementTree] {
  let bounds = palette_test_rect(0.0, 0.0, 640.0, 400.0)
  Ref(
    @element.ElementTree::new([
      @element.ElementNode::new(1, None, bounds),
      @element.ElementNode::new(9, Some(1), bounds).with_focusable(true),
      palette_test_field().element_node(Some(1)),
    ])
    .unwrap()
    .with_focus(9)
    .unwrap(),
  )
}

///|
fn palette_test_component(callback : () -> Unit) -> CommandPalette {
  let metadata = CommandMetadata::new(
    "open.japanese", "日本語を開く", true,
  ).unwrap()
  CommandPalette::new(palette_test_field(), [
    PaletteCommand::new(metadata, palette_test_binding(metadata.id(), callback)),
  ]).unwrap()
}

///|
fn palette_test_input(
  palette : CommandPalette,
  event : @primitives.InputEvent,
) -> PaletteInput {
  palette
  .handle_input(
    event, palette_test_measure, palette_test_admit, palette_test_hit,
  )
  .unwrap()
}

///|
test "picker limits bytes duplicates and copies input metadata" {
  let one = CommandMetadata::new("a", "日本", true).unwrap()
  let values = [one]
  let picker = Picker::new(values).unwrap()
  values.clear()
  assert_eq(picker.match_count(), 1)
  assert_true(CommandMetadata::new("", "a", true) is Err(InvalidMetadata))
  assert_true(CommandMetadata::new("a", "a\n", true) is Err(InvalidMetadata))
  assert_true(
    CommandMetadata::new("a", "日".repeat(43), true) is Err(InvalidMetadata),
  )
  assert_true(
    CommandMetadata::new("a".repeat(64), "日".repeat(42), true) is Ok(_),
  )
  assert_true(Picker::new([one, one]) is Err(DuplicateCommand))
  let oversized = Array::make(129, one)
  assert_true(Picker::new(oversized) is Err(TooManyCommands))
  assert_true(picker.filter("日".repeat(86)) is Err(QueryTooLarge))
}

///|
test "picker navigation skips disabled clamps and bounds visible work" {
  let values = []
  for index = 0; index < 128; index = index + 1 {
    values.push(
      CommandMetadata::new("c\{index}", "日本 \{index}", index % 3 != 0).unwrap(),
    )
  }
  let mut picker = Picker::new(values).unwrap()
  assert_eq(picker.active_index(), Some(1))
  for _index = 0; _index < 256; _index = _index + 1 {
    picker = picker.navigate(1)
  }
  assert_eq(picker.active_index(), Some(127))
  assert_eq(picker.visible_start(), 120)
  assert_eq(picker.visible_commands().length(), 8)
  for _index = 0; _index < 256; _index = _index + 1 {
    picker = picker.navigate(-1)
  }
  assert_eq(picker.active_index(), Some(1))
  assert_eq(picker.visible_start(), 1)
  let empty = picker.filter("absent").unwrap()
  assert_eq(empty.match_count(), 0)
  assert_eq(empty.active_index(), None)
  assert_eq(empty.visible_commands().length(), 0)
  let disabled = Picker::new([
    CommandMetadata::new("off", "日本", false).unwrap(),
  ]).unwrap()
  assert_true(disabled.navigate(1).active_command() is None)
  assert_eq(disabled.visible_commands().length(), 1)
}

///|
test "small reference traces preserve exact match order and enabled selection" {
  for mask = 0; mask < 32; mask = mask + 1 {
    let values = []
    for index = 0; index < 5; index = index + 1 {
      values.push(
        CommandMetadata::new(
          "c\{index}",
          if index % 2 == 0 {
            "日本"
          } else {
            "abc"
          },
          (mask & (1 << index)) != 0,
        ).unwrap(),
      )
    }
    for query in ["", "日", "本", "abc", "ABC", "no"] {
      let mut picker = Picker::new(values).unwrap().filter(query).unwrap()
      let reference = values.filter(command => command.label().contains(query))
      assert_eq(picker.match_count(), reference.length())
      for index = 0; index < reference.length(); index = index + 1 {
        assert_eq(picker.command_at(index).unwrap().id(), reference[index].id())
      }
      for step in [1, 1, -1, 1, 1, 1, -1, -1, -1, -1, 1] {
        picker = picker.navigate(step)
        if picker.active_command() is Some(command) {
          assert_true(command.is_enabled())
          assert_true(command.label().contains(query))
        }
        assert_true(picker.visible_commands().length() <= VISIBLE_ROWS)
        assert_true(picker.visible_start() >= 0)
      }
    }
  }
}

///|
test "committed query only and composition Enter Escape lifecycle" {
  let calls = Ref(0)
  let palette = palette_test_component(() => calls.val += 1)
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  let epoch = palette.open_epoch()
  let preview = palette
    .field()
    .update_composition(
      "にほん",
      @text.TextSelection::new(3, 3).unwrap(),
      palette_test_measure,
      palette_test_admit,
    )
    .unwrap()
  palette.install_field(preview).unwrap()
  assert_eq(palette.picker().query(), "")
  assert_eq(palette.semantics().search_value, "")
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  assert_true(palette.is_open())
  let committed = palette
    .field()
    .commit_composition("日本", palette_test_measure, palette_test_admit)
    .unwrap()
  palette.install_field(committed).unwrap()
  assert_eq(palette.picker().query(), "日本")
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  assert_true(palette.is_open())
  ignore(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Enter,
        modifiers=@primitives.Modifiers::none(),
      ),
    ),
  )
  let caret = palette
    .field()
    .handle_input(
      palette_test_key(@primitives.Home),
      palette_test_measure,
      palette_test_admit,
      palette_test_hit,
    )
    .unwrap().0
  palette.install_field(caret).unwrap()
  assert_eq(palette.picker().query(), "日本")
  let input = palette_test_input(palette, palette_test_key(@primitives.Enter))
  assert_true(input.consumed)
  assert_false(palette.is_open())
  assert_eq(calls.val, 0)
  palette.finish_close(epoch, tree).unwrap()
  palette.finish_close(epoch, tree).unwrap()
  assert_eq(calls.val, 1)
  assert_eq(tree.val.focused(), Some(9))
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Enter,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  palette.open(tree).unwrap()
  assert_eq(palette.open_epoch(), epoch + 1)
  assert_eq(palette.field().committed_document().text(), "")
  let preview = palette
    .field()
    .update_composition(
      "に",
      @text.TextSelection::new(1, 1).unwrap(),
      palette_test_measure,
      palette_test_admit,
    )
    .unwrap()
  palette.install_field(preview).unwrap()
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Escape)).effect
    is CompositionCancelled,
  )
  assert_true(palette.is_open())
  assert_false(palette.field().is_composing())
  ignore(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Escape,
        modifiers=@primitives.Modifiers::none(),
      ),
    ),
  )
  ignore(palette_test_input(palette, palette_test_key(@primitives.Escape)))
  assert_false(palette.is_open())
  palette.finish_close(palette.open_epoch(), tree).unwrap()
  assert_eq(calls.val, 1)
}

///|
test "one shot terminal before reentrant callback preserves callback focus" {
  let tree = palette_test_tree()
  let slot : Ref[CommandPalette?] = Ref(None)
  let calls = Ref(0)
  let palette = palette_test_component(() => {
    calls.val += 1
    let palette = slot.val.unwrap()
    if palette.is_open() {
      abort("callback observed open palette")
    }
    palette.finish_close(palette.open_epoch(), tree).unwrap()
    ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
    tree.val = tree.val.with_focus(2).unwrap()
  })
  slot.val = Some(palette)
  palette.open(tree).unwrap()
  let modal = tree.val.focus_owner()
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  palette.finish_close(palette.open_epoch(), tree).unwrap()
  assert_eq(calls.val, 1)
  assert_eq(tree.val.focused(), Some(2))
  assert_true(tree.val.focus_owner() != modal)
}
