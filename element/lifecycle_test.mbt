///|
fn lifecycle_size(width : Double, height : Double) -> @primitives.Size {
  match @primitives.Size::new(width, height) {
    Ok(value) => value
    Err(_) => abort("valid lifecycle size rejected")
  }
}

///|
fn lifecycle_points(value : Double) -> @layout.Dimension {
  match @layout.Dimension::points(value) {
    Ok(dimension) => dimension
    Err(_) => abort("valid lifecycle dimension rejected")
  }
}

///|
fn lifecycle_item(
  id : UInt64,
  width : Double,
  height : Double,
) -> @layout.FlexItem {
  @layout.FlexItem::new(
    id,
    lifecycle_points(width),
    lifecycle_points(height),
    lifecycle_size(width, height),
  )
}

///|
fn lifecycle_color(red : Int, green : Int, blue : Int) -> @primitives.Color {
  match @primitives.Color::rgba(red, green, blue, 255) {
    Ok(value) => value
    Err(_) => abort("valid lifecycle color rejected")
  }
}

///|
struct DemoRenderView {
  color : @primitives.Color
}

///|
impl @element.Render for DemoRenderView with fn render(self) -> @element.Element {
  let style = match
    @layout.FlexTreeStyle::new(@layout.FlowDirection::row()).with_gap(5.0) {
    Ok(value) => value
    Err(_) => abort("valid lifecycle gap rejected")
  }
  @element.Element::root(1, style)
  .with_child(
    @element.Element::new(lifecycle_item(2, 20.0, 40.0)).with_background(
      Some(self.color),
    ),
  )
  .with_child(
    @element.Element::new(lifecycle_item(3, 20.0, 40.0)).with_background(
      Some(self.color),
    ),
  )
}

///|
test "Render produces a declarative element and IntoElement accepts it" {
  let color = lifecycle_color(20, 40, 60)
  let rendered = @element.render_element(DemoRenderView::{ color, })
  let converted : @element.Element = @element.into_element(rendered)
  let requested = match converted.request_layout(lifecycle_size(100.0, 40.0)) {
    Err(_) => fail("valid request-layout phase failed")
    Ok(value) => value
  }
  let prepainted = match requested.prepaint() {
    Err(_) => fail("valid prepaint phase failed")
    Ok(value) => value
  }
  assert_true(!prepainted.overflow())
  let tree = prepainted.tree()
  let nodes = tree.nodes()
  assert_eq(nodes.length(), 3)
  assert_true(nodes[0].id() == 1)
  assert_true(nodes[1].id() == 2)
  assert_true(nodes[2].id() == 3)
  assert_true(nodes[1].bounds().left() == 0.0)
  assert_true(nodes[2].bounds().left() == 25.0)
  assert_true(
    tree.hit_test(
      match @primitives.Point::new(30.0, 20.0) {
        Ok(value) => value
        Err(_) => fail("valid lifecycle point rejected")
      },
    ) ==
    Some(3),
  )

  let scene = prepainted.paint()
  assert_eq(scene.command_count(), 2)
  match scene.command_at(0) {
    None => fail("paint phase emitted no first command")
    Some(command) => {
      assert_true(command.id() == 2)
      assert_true(command.color() == Some(color))
    }
  }
  match scene.command_at(1) {
    None => fail("paint phase emitted no second command")
    Some(command) => assert_true(command.id() == 3)
  }
  assert_true(prepainted.paint_snapshot(0.0) is Err(@scene.InvalidScale))
  match prepainted.paint_snapshot(2.0) {
    Err(_) => fail("valid scene snapshot rejected")
    Ok(snapshot) => {
      assert_true(
        snapshot.schema_version() == @scene.SCENE_SNAPSHOT_SCHEMA_VERSION,
      )
      assert_eq(snapshot.items().length(), 2)
      assert_true(snapshot.viewport() == prepainted.viewport_bounds())
    }
  }
}

///|
test "request-layout rejects a child as root and missing child containers" {
  let child = @element.Element::new(lifecycle_item(2, 10.0, 10.0))
  assert_true(
    child.request_layout(lifecycle_size(20.0, 20.0)) is Err(RootRequired),
  )

  let root_style = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let root = @element.Element::root(1, root_style).with_child(
    @element.Element::new(lifecycle_item(2, 10.0, 10.0)).with_child(
      @element.Element::new(lifecycle_item(3, 5.0, 5.0)),
    ),
  )
  assert_true(
    root.request_layout(lifecycle_size(20.0, 20.0))
    is Err(LayoutFailure(@layout.MissingContainer)),
  )
}

///|
test "request-layout rejects nesting beyond the documented bound" {
  let style = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let mut nested = @element.Element::new(lifecycle_item(2, 10.0, 10.0))
  let mut index = 0
  while index < @element.MAX_ELEMENT_DEPTH {
    nested = @element.Element::new(lifecycle_item(3, 10.0, 10.0))
      .with_children_style(style)
      .with_child(nested)
    index += 1
  }
  let root = @element.Element::root(1, style).with_child(nested)
  assert_true(
    root.request_layout(lifecycle_size(20.0, 20.0)) is Err(TreeTooDeep),
  )
}
