///|
test "review repeated Escape after cancellation cannot dismiss" {
  let palette = palette_test_component(() => ())
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
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
  ignore(
    palette_test_input(
      palette,
      palette_test_key(@primitives.Escape, repeat=true),
    ),
  )
  assert_true(palette.is_open())
}

///|
test "review modified Escape release cannot leak" {
  let palette = palette_test_component(() => ())
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  ignore(
    palette_test_input(
      palette,
      @primitives.KeyPressed(
        key=@primitives.Escape,
        modifiers=@primitives.Modifiers::new(
          shift=true,
          control=false,
          alt=false,
          meta=false,
        ),
        repeat=false,
      ),
    ),
  )
  palette.finish_close(palette.open_epoch(), tree).unwrap()
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Escape,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
}

///|
test "review initial disabled prefix retains visible active selection" {
  let commands = []
  for index = 0; index < 12; index = index + 1 {
    commands.push(
      CommandMetadata::new("c\{index}", "Command \{index}", index == 11).unwrap(),
    )
  }
  let picker = Picker::new(commands).unwrap()
  assert_eq(picker.active_index(), Some(11))
  assert_true(
    picker.visible_start() <= 11 &&
    picker.visible_start() + picker.visible_commands().length() > 11,
  )
}

///|
test "review reopened palette guards duplicate closing press until release" {
  let tree = palette_test_tree()
  let slot : Ref[CommandPalette?] = Ref(None)
  let calls = Ref(0)
  let palette = palette_test_component(() => {
    calls.val += 1
    slot.val.unwrap().open(tree).unwrap()
  })
  slot.val = Some(palette)
  palette.open(tree).unwrap()
  let epoch = palette.open_epoch()
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  palette.finish_close(epoch, tree).unwrap()
  assert_eq(calls.val, 1)
  assert_true(palette.is_open())
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  assert_true(palette.is_open())
}
