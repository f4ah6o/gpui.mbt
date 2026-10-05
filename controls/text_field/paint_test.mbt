///|
/// These paint tests use the scripted, trusted measurements in model_test.mbt.
/// They exercise framework scene data only; they do not claim Pango metrics or
/// GPU pixels.
fn field_test_paint(
  field : @text_field.TextField,
  base : UInt64,
  clip_id : Int,
) -> (@scene.ClipChain, Array[@scene.SceneItem]) raise {
  match field.paint_items(base, clip_id) {
    Ok(value) => value
    Err(_) => fail("valid field scene should paint")
  }
}

///|
fn field_test_quad(
  items : Array[@scene.SceneItem],
  index : Int,
) -> (
  UInt64,
  @primitives.Rect,
  @primitives.Color,
  @scene.AffineTransform,
  Double,
  Int?,
) raise {
  match items[index] {
    @scene.QuadItem(id~, bounds~, color~, transform~, opacity~, clip_chain_id~) =>
      (id, bounds, color, transform, opacity, clip_chain_id)
    _ => fail("expected a quad at the requested paint position")
  }
}

///|
fn field_test_color_is(
  color : @primitives.Color,
  red : Int,
  green : Int,
  blue : Int,
  alpha : Int,
) -> Bool {
  color.red() == red &&
  color.green() == green &&
  color.blue() == blue &&
  color.alpha() == alpha
}

///|
test "field scene order preserves style, copied text and clip geometry" {
  let bounds = field_test_rect(10.0, 20.0, 100.0, 28.0)
  let selected = field_test_selection(field_test_create("a😀b", bounds), 1, 3)
  let field = field_test_focused(selected)
  let (clip, items) = field_test_paint(field, 100UL, 77)
  assert_eq(items.length(), 8)
  assert_eq(clip.id(), 77)
  assert_true(clip.rects() == [field_test_rect(14.0, 24.0, 92.0, 20.0)])

  let (background_id, background_bounds, background_color, _, _, background_clip
  ) = field_test_quad(items, 0)
  assert_eq(background_id, 100UL)
  assert_true(background_bounds == bounds)
  assert_true(field_test_color_is(background_color, 255, 255, 255, 255))
  assert_true(background_clip is None)

  for index in 1..<=4 {
    let (id, _, color, _, _, clip_id) = field_test_quad(items, index)
    assert_eq(id, 100UL + index.to_uint64())
    assert_true(field_test_color_is(color, 55, 105, 220, 255))
    assert_true(clip_id is None)
  }

  let (selection_id, selection_bounds, selection_color, _, _, selection_clip) = field_test_quad(
    items, 5,
  )
  assert_eq(selection_id, 105UL)
  assert_true(selection_bounds == field_test_rect(22.0, 24.0, 8.0, 20.0))
  assert_true(field_test_color_is(selection_color, 65, 105, 225, 80))
  assert_true(selection_clip == Some(77))

  match items[6] {
    @scene.TextItem(
      id=106,
      bounds~,
      text="a😀b",
      font_size=16.0,
      color~,
      transform~,
      opacity=1.0,
      clip_chain_id=Some(77)
    ) => {
      assert_true(bounds == field_test_rect(0.0, 0.0, 24.0, 20.0))
      assert_true(field_test_color_is(color, 20, 24, 30, 255))
      assert_eq(transform.tx(), 14.0)
      assert_eq(transform.ty(), 24.0)
    }
    _ => fail("text item should preserve the exact document and font style")
  }

  let (caret_id, caret_bounds, caret_color, _, _, caret_clip) = field_test_quad(
    items, 7,
  )
  assert_eq(caret_id, 107UL)
  assert_true(caret_bounds == field_test_rect(30.0, 24.0, 1.0, 16.0))
  assert_true(field_test_color_is(caret_color, 20, 24, 30, 255))
  assert_true(caret_clip == Some(77))
}

///|
test "local text bounds translate with horizontal scroll and keep the end caret visible" {
  let bounds = field_test_rect(10.0, 20.0, 32.0, 28.0)
  let at_end = field_test_selection(field_test_create("abcd", bounds), 4, 4)
  let field = field_test_focused(at_end)
  assert_eq(field.scroll_offset(), 9.0)
  let (clip, items) = field_test_paint(field, 200UL, 78)
  assert_true(clip.rects()[0] == field_test_rect(14.0, 24.0, 24.0, 20.0))
  assert_eq(items.length(), 7)

  match items[5] {
    @scene.TextItem(
      bounds~,
      text="abcd",
      transform~,
      clip_chain_id=Some(78),
      ..
    ) => {
      assert_true(bounds == field_test_rect(0.0, 0.0, 32.0, 20.0))
      assert_eq(transform.tx(), 5.0)
      assert_eq(transform.ty(), 24.0)
    }
    _ => fail("scrolled text should keep local bounds and translated origin")
  }
  let (caret_id, caret_bounds, _, _, _, caret_clip) = field_test_quad(items, 6)
  assert_eq(caret_id, 207UL)
  assert_true(caret_bounds == field_test_rect(37.0, 24.0, 1.0, 16.0))
  assert_true(caret_clip == Some(78))
  assert_eq(caret_bounds.right(), clip.rects()[0].right())
}

///|
test "unfocused selection stays painted without an active caret" {
  let bounds = field_test_rect(10.0, 20.0, 100.0, 28.0)
  let field = field_test_selection(field_test_create("abcd", bounds), 1, 3)
  assert_true(!field.is_focused())
  assert_true(field.selection() == @text.TextSelection::new(1, 3).unwrap())
  let (_, items) = field_test_paint(field, 300UL, 79)
  assert_eq(items.length(), 7)
  assert_eq(items[5].id(), 305UL)
  assert_true(items[6] is @scene.TextItem(text="abcd", ..))
  let (_, _, inactive_border, _, _, border_clip) = field_test_quad(items, 1)
  assert_true(field_test_color_is(inactive_border, 130, 140, 150, 255))
  assert_true(border_clip is None)
  let (_, inactive_bounds, inactive_color, _, _, inactive_clip) = field_test_quad(
    items, 5,
  )
  assert_true(inactive_bounds == field_test_rect(22.0, 24.0, 16.0, 20.0))
  assert_true(field_test_color_is(inactive_color, 140, 150, 160, 64))
  assert_true(inactive_clip == Some(79))
  for item in items {
    assert_true(item.id() != 307UL)
  }
  assert_true(field.selection() == @text.TextSelection::new(1, 3).unwrap())
}

///|
test "empty text paints a bounded valid v1 scene and outputs are detached" {
  let field = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 24.0, 24.0)),
  )
  let (clip, items) = field_test_paint(field, 400UL, 80)
  assert_eq(items.length(), 7)
  match items[5] {
    @scene.TextItem(
      bounds~,
      text="",
      font_size=16.0,
      clip_chain_id=Some(80),
      ..
    ) => assert_true(bounds == field_test_rect(0.0, 0.0, 1.0, 20.0))
    _ => fail("empty text must still form a valid bounded text item")
  }
  let (caret_id, caret_bounds, _, _, _, caret_clip) = field_test_quad(items, 6)
  assert_eq(caret_id, 407UL)
  assert_true(caret_bounds == field_test_rect(4.0, 4.0, 1.0, 16.0))
  assert_true(caret_clip == Some(80))

  let rect_copy = clip.rects()
  ignore(rect_copy.pop())
  assert_eq(clip.rects().length(), 1)
  let item_copy = items
  ignore(item_copy.pop())
  let (again_clip, again_items) = field_test_paint(field, 400UL, 80)
  assert_eq(again_clip.rects().length(), 1)
  assert_eq(again_items.length(), 7)

  let snapshot = match
    @scene.SceneSnapshot::new(
      field_test_rect(0.0, 0.0, 24.0, 24.0),
      1.0,
      [],
      [clip],
      again_items,
    ) {
    Ok(value) => value
    Err(_) =>
      fail("empty field should assemble into the unchanged scene v1 envelope")
  }
  assert_eq(snapshot.schema_version(), 1)
  assert_eq(snapshot.items().length(), 7)
  let canonical = snapshot.canonical_json()
  assert_true(canonical.contains("\"schema_version\":1"))
  assert_true(canonical.contains("\"kind\":\"text\""))
  assert_true(canonical.contains("\"text\":\"\""))
  assert_true(canonical.contains("\"clip_chain_id\":80"))
  let snapshot_items = snapshot.items()
  ignore(snapshot_items.pop())
  assert_eq(snapshot.items().length(), 7)
  let snapshot_clips = snapshot.clip_chains()
  let snapshot_rects = snapshot_clips[0].rects()
  ignore(snapshot_rects.pop())
  assert_eq(snapshot.clip_chains()[0].rects().length(), 1)
}

///|
test "item ID reservation accepts the boundary and rejects overflow" {
  let field = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 24.0, 24.0)),
  )
  let maximum_base : UInt64 = 18446744073709551608
  let (_, items) = field_test_paint(field, maximum_base, 81)
  assert_eq(items.length(), 7)
  assert_eq(items[6].id(), 18446744073709551615UL)
  assert_true(
    field.paint_items(maximum_base + 1UL, 81) is Err(@text_field.InvalidItemId),
  )
}

///|
test "field element node retains bounds parent and focused keyboard route" {
  let bounds = field_test_rect(10.0, 20.0, 100.0, 28.0)
  let field = field_test_create("x", bounds)
  let node = field.element_node(Some(5UL))
  assert_eq(node.id(), 17UL)
  assert_eq(node.parent(), Some(5UL))
  assert_true(node.bounds() == bounds)
  assert_true(node.is_focusable())

  let root = @element.ElementNode::new(
    5UL,
    None,
    field_test_rect(0.0, 0.0, 200.0, 100.0),
  )
  let tree = match @element.ElementTree::new([root, node]) {
    Ok(value) => value
    Err(_) => fail("field element should fit under its parent")
  }
  let focused = match tree.with_focus(17UL) {
    Ok(value) => value
    Err(_) => fail("field node should be focusable")
  }
  assert_eq(focused.focused(), Some(17UL))
  let key = @primitives.Character("x")
  let modifiers = @primitives.Modifiers::none()
  let route = focused.dispatch_input(
    @primitives.KeyPressed(key~, modifiers~, repeat=false),
  )
  assert_eq(route.target(), Some(17UL))
  assert_true(route.capture() == [5UL, 17UL])
  assert_true(route.bubble() == [17UL, 5UL])
}
