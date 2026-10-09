///|
test "review stale open epoch field cannot install and rejection is atomic" {
  let palette = palette_test_component(() => ())
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  let old_epoch = palette.open_epoch()
  let old_candidate = palette
    .field()
    .replace_selection("old", palette_test_measure, palette_test_admit)
    .unwrap()
  ignore(palette.blur().unwrap())
  palette.finish_close(old_epoch, tree).unwrap()
  palette.open(tree).unwrap()
  assert_true(
    palette.install_field_at(old_epoch, old_candidate) is Err(InvalidField),
  )
  assert_eq(palette.field().committed_document().text(), "")
  assert_eq(palette.picker().query(), "")
  let oversized = palette
    .field()
    .replace_selection(
      "日".repeat(86),
      palette_test_measure,
      palette_test_admit,
    )
    .unwrap()
  assert_true(
    palette.install_field_at(palette.open_epoch(), oversized)
    is Err(QueryTooLarge),
  )
  assert_eq(palette.field().committed_document().text(), "")
  assert_eq(palette.picker().query(), "")
}

///|
test "review stale finish cannot consume newer terminal command" {
  let calls = Ref(0)
  let palette = palette_test_component(() => calls.val += 1)
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  let old_epoch = palette.open_epoch()
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  palette.finish_close(old_epoch, tree).unwrap()
  ignore(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Enter,
        modifiers=@primitives.Modifiers::none(),
      ),
    ),
  )
  palette.open(tree).unwrap()
  let new_epoch = palette.open_epoch()
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  palette.finish_close(old_epoch, tree).unwrap()
  assert_eq(calls.val, 1)
  palette.finish_close(new_epoch, tree).unwrap()
  palette.finish_close(new_epoch, tree).unwrap()
  assert_eq(calls.val, 2)
  assert_eq(tree.val.focused(), Some(9))
}

///|
test "review oversized commands rejected before availability callbacks" {
  let checks = Ref(0)
  let descriptor = @capability.Descriptor::new(
    "bound",
    "bound",
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
  let binding = @capability.TypedCapability::new(
    descriptor,
    _ => Ok(()),
    _ => Ok(@capability.Value::unit()),
    _ => Ok(()),
    () => {
      checks.val += 1
      Ok(())
    },
    _ => Ok(()),
  ).gui_binding()
  let command = PaletteCommand::new(
    CommandMetadata::new("bound", "Bound", true).unwrap(),
    binding,
  )
  assert_true(
    CommandPalette::new(
      palette_test_field(),
      Array::make(MAX_COMMANDS + 1, command),
    )
    is Err(TooManyCommands),
  )
  assert_eq(checks.val, 0)
}

///|
test "review Escape cancellation requires genuine release before new dismissal" {
  let palette = palette_test_component(() => ())
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  palette
  .install_field(
    palette
    .field()
    .update_composition(
      "に",
      @text.TextSelection::new(1, 1).unwrap(),
      palette_test_measure,
      palette_test_admit,
    )
    .unwrap(),
  )
  .unwrap()
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Escape)).effect
    is CompositionCancelled,
  )
  ignore(palette_test_input(palette, palette_test_key(@primitives.Escape)))
  assert_true(palette.is_open())
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
}
