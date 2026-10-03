///|
fn element_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("valid rectangle rejected")
  }
}

///|
fn element_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid point rejected")
  }
}

///|
fn element_color(red : Int, green : Int, blue : Int) -> @primitives.Color {
  match @primitives.Color::rgba(red, green, blue, 255) {
    Ok(value) => value
    Err(_) => abort("valid color rejected")
  }
}

///|
fn unwrap_tree(nodes : Array[@element.ElementNode]) -> @element.ElementTree {
  match @element.ElementTree::new(nodes) {
    Ok(value) => value
    Err(_) => abort("valid element tree rejected")
  }
}

///|
test "element tree rejects duplicate ids and missing parents" {
  let bounds = element_rect(0.0, 0.0, 10.0, 10.0)
  assert_true(
    @element.ElementTree::new([
      @element.ElementNode::new(1, None, bounds),
      @element.ElementNode::new(1, Some(1), bounds),
    ])
    is Err(DuplicateId),
  )
  assert_true(
    @element.ElementTree::new([@element.ElementNode::new(2, Some(99), bounds)])
    is Err(MissingParent),
  )
}

///|
test "hit test and dispatch use stable reverse paint order" {
  let root = @element.ElementNode::new(
    1,
    None,
    element_rect(0.0, 0.0, 100.0, 100.0),
  )
  let parent = @element.ElementNode::new(
    2,
    Some(1),
    element_rect(10.0, 10.0, 80.0, 80.0),
  )
  let child = @element.ElementNode::new(
    3,
    Some(2),
    element_rect(20.0, 20.0, 20.0, 20.0),
  )
  let tree = unwrap_tree([root, parent, child])
  let point = element_point(25.0, 25.0)
  assert_true(tree.hit_test(point) == Some(3))
  let plan = tree.dispatch_pointer(point)
  assert_true(plan.target() == Some(3))
  let capture = plan.capture()
  let bubble = plan.bubble()
  assert_eq(capture.length(), 3)
  assert_true(capture[0] == 1)
  assert_true(capture[1] == 2)
  assert_true(capture[2] == 3)
  assert_eq(bubble.length(), 3)
  assert_true(bubble[0] == 3)
  assert_true(bubble[1] == 2)
  assert_true(bubble[2] == 1)
}

///|
test "focus accepts only focusable live nodes" {
  let bounds = element_rect(0.0, 0.0, 10.0, 10.0)
  let root = @element.ElementNode::new(1, None, bounds)
  let child_base = @element.ElementNode::new(2, Some(1), bounds)
  let child = child_base.with_focusable(true)
  let tree = unwrap_tree([root, child])
  assert_true(tree.with_focus(1) is Err(NotFocusable))
  match tree.with_focus(2) {
    Err(_) => fail("focusable node rejected")
    Ok(focused) => {
      assert_true(focused.focused() == Some(2))
      assert_true(focused.clear_focus().focused() is None)
    }
  }
  assert_true(tree.with_focus(99) is Err(UnknownElement))
}

///|
test "element scene generation follows stable node order" {
  let red = element_color(255, 0, 0)
  let blue = element_color(0, 0, 255)
  let bounds = element_rect(0.0, 0.0, 10.0, 10.0)
  let root_base = @element.ElementNode::new(1, None, bounds)
  let root = root_base.with_background(Some(red))
  let child_base = @element.ElementNode::new(2, Some(1), bounds)
  let child = child_base.with_background(Some(blue))
  let invisible = @element.ElementNode::new(3, Some(1), bounds)
  let scene = unwrap_tree([root, child, invisible]).to_scene()
  assert_eq(scene.command_count(), 2)
  match scene.command_at(0) {
    None => fail("missing first scene command")
    Some(command) => {
      assert_true(command.id() == 1)
      assert_true(command.kind() == @scene.PaintKind::Quad)
      assert_true(command.color() == Some(red))
    }
  }
  match scene.command_at(1) {
    None => fail("missing second scene command")
    Some(command) => {
      assert_true(command.id() == 2)
      assert_true(command.color() == Some(blue))
    }
  }
}

///|
test "element tree and dispatch plans own their arrays" {
  let bounds = element_rect(0.0, 0.0, 20.0, 20.0)
  let root = @element.ElementNode::new(1, None, bounds)
  let child = @element.ElementNode::new(2, Some(1), bounds)
  let source : Array[@element.ElementNode] = [root, child]
  let tree = unwrap_tree(source)
  source.push(@element.ElementNode::new(3, Some(1), bounds))
  assert_true(tree.node(3) is None)

  let exposed = tree.nodes()
  exposed.push(@element.ElementNode::new(4, Some(1), bounds))
  assert_true(tree.node(4) is None)

  let plan = tree.dispatch_pointer(element_point(10.0, 10.0))
  let capture = plan.capture()
  let bubble = plan.bubble()
  capture.push(99)
  bubble.push(98)
  assert_eq(plan.capture().length(), 2)
  assert_eq(plan.bubble().length(), 2)
}
