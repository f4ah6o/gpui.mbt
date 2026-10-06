///|
test "palette observer nullable values and bounded native scene states" {
  let fixture = palette_fixture()
  let initial = palette_state_line(fixture, 1, None, 0)
  assert_true(initial.contains("\"focus_owner\":9"))
  assert_true(initial.contains("\"active_id\":null"))
  assert_true(initial.contains("\"active_index\":0"))
  let closed = palette_scene(fixture, 640.0, 480.0, 1.0)
  assert_true(closed.canonical_json().contains("Open command palette"))
  fixture.palette.open(fixture.tree).unwrap()
  let opened = palette_scene(fixture, 640.0, 480.0, 1.0)
  let semantics = fixture.palette.semantics()
  assert_eq(semantics.options.length(), 8)
  assert_true(semantics.options[2].disabled)
  assert_eq(
    opened.items().length(),
    field_scene(fixture.palette.field(), 640.0, 480.0, 1.0)
    .unwrap()
    .items()
    .length() +
    16 +
    1,
  )
  let empty = fixture.palette
    .field()
    .replace_selection("zzz", measure, admit)
    .unwrap()
  fixture.palette.install_field_at(fixture.palette.open_epoch(), empty).unwrap()
  let no_results = palette_scene(fixture, 640.0, 480.0, 1.0)
  assert_true(no_results.canonical_json().contains("No matching commands"))
  assert_eq(fixture.palette.semantics().options.length(), 0)
  assert_true(fixture.palette.semantics().active_id is None)
}
