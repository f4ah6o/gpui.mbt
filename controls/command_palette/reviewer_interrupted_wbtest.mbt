///|
test "review cancellation Escape release stays contained after blur" {
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
  ignore(palette_test_input(palette, palette_test_key(@primitives.Escape)))
  ignore(palette.blur().unwrap())
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
