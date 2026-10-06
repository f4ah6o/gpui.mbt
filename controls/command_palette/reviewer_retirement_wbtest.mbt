///|
test "review key retirement only affects completed closed matching epoch" {
  let calls = Ref(0)
  let palette = palette_test_component(() => calls.val += 1)
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  let old_epoch = palette.open_epoch()
  ignore(palette_test_input(palette, palette_test_key(@primitives.Enter)))
  palette.retire_key_guard(old_epoch)
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Enter)).consumed,
  )
  palette.finish_close(old_epoch, tree).unwrap()
  palette.retire_key_guard(old_epoch + 1)
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Enter)).consumed,
  )
  palette.open(tree).unwrap()
  let new_epoch = palette.open_epoch()
  palette.retire_key_guard(new_epoch)
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Enter)).consumed,
  )
  assert_true(palette.is_open())
  ignore(palette.blur().unwrap())
  palette.finish_close(new_epoch, tree).unwrap()
  palette.retire_key_guard(old_epoch)
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Enter)).consumed,
  )
  palette.retire_key_guard(new_epoch)
  assert_false(
    palette_test_input(palette, palette_test_key(@primitives.Enter)).consumed,
  )
  assert_eq(calls.val, 1)
  assert_eq(tree.val.focused(), Some(9))
}
