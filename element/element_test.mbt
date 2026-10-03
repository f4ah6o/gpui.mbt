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
test "element tree rejects descendants after their subtree closes" {
  let bounds = element_rect(0.0, 0.0, 10.0, 10.0)
  assert_true(
    @element.ElementTree::new([
      @element.ElementNode::new(1, None, bounds),
      @element.ElementNode::new(2, Some(1), bounds),
      @element.ElementNode::new(3, None, bounds),
      @element.ElementNode::new(4, Some(2), bounds),
    ])
    is Err(InvalidPreorder),
  )
  let valid = unwrap_tree([
    @element.ElementNode::new(1, None, bounds),
    @element.ElementNode::new(2, Some(1), bounds),
    @element.ElementNode::new(3, Some(2), bounds),
    @element.ElementNode::new(4, Some(1), bounds),
  ])
  assert_true(valid.node(4) is Some(_))
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

///|
test "callback dispatch walks capture then bubble deterministically" {
  let bounds = element_rect(0.0, 0.0, 100.0, 100.0)
  let tree = unwrap_tree([
    @element.ElementNode::new(1, None, bounds),
    @element.ElementNode::new(2, Some(1), bounds),
    @element.ElementNode::new(3, Some(2), bounds),
  ])
  let ids : Array[UInt64] = []
  let phases : Array[@element.EventPhase] = []
  match
    tree.dispatch_pointer_with(element_point(10.0, 10.0), context => {
      ids.push(context.current_target())
      phases.push(context.phase())
      Ok(())
    }) {
    Err(_) => fail("valid dispatch failed")
    Ok(outcome) => {
      assert_true(outcome.target() == Some(3))
      assert_true(!outcome.was_stopped())
      assert_eq(outcome.capture_visited().length(), 3)
      assert_eq(outcome.bubble_visited().length(), 3)
    }
  }
  assert_eq(ids.length(), 6)
  assert_true(ids[0] == 1)
  assert_true(ids[1] == 2)
  assert_true(ids[2] == 3)
  assert_true(ids[3] == 3)
  assert_true(ids[4] == 2)
  assert_true(ids[5] == 1)
  assert_true(phases[0] == @element.EventPhase::Capture)
  assert_true(phases[2] == @element.EventPhase::Capture)
  assert_true(phases[3] == @element.EventPhase::Bubble)
  assert_true(phases[5] == @element.EventPhase::Bubble)
}

///|
test "stop propagation prevents later capture and all bubble callbacks" {
  let bounds = element_rect(0.0, 0.0, 100.0, 100.0)
  let tree = unwrap_tree([
    @element.ElementNode::new(1, None, bounds),
    @element.ElementNode::new(2, Some(1), bounds),
    @element.ElementNode::new(3, Some(2), bounds),
  ])
  let visited : Array[UInt64] = []
  let stopped_seen = Ref(false)
  match
    tree.dispatch_pointer_with(element_point(10.0, 10.0), context => {
      visited.push(context.current_target())
      if context.phase() == @element.EventPhase::Capture &&
        context.current_target() == 2 {
        context.stop_propagation()
        stopped_seen.val = context.is_propagation_stopped()
      }
      Ok(())
    }) {
    Err(_) => fail("valid dispatch failed")
    Ok(outcome) => {
      assert_true(outcome.was_stopped())
      assert_eq(outcome.capture_visited().length(), 2)
      assert_eq(outcome.bubble_visited().length(), 0)
    }
  }
  assert_eq(visited.length(), 2)
  assert_true(stopped_seen.val)
  assert_true(visited[0] == 1)
  assert_true(visited[1] == 2)
}

///|
test "subtree removal preserves preorder and normalizes focus" {
  let bounds = element_rect(0.0, 0.0, 20.0, 20.0)
  let root = @element.ElementNode::new(1, None, bounds)
  let branch = @element.ElementNode::new(2, Some(1), bounds)
  let leaf = @element.ElementNode::new(3, Some(2), bounds).with_focusable(true)
  let sibling = @element.ElementNode::new(4, Some(1), bounds)
  let tree = unwrap_tree([root, branch, leaf, sibling])
  match tree.with_focus(3) {
    Err(_) => fail("focusable node rejected")
    Ok(focused) =>
      match focused.without_subtree(2) {
        Err(_) => fail("live subtree rejected")
        Ok(next) => {
          assert_true(next.focused() is None)
          assert_true(next.node(2) is None)
          assert_true(next.node(3) is None)
          assert_true(next.node(4) is Some(_))
          let nodes = next.nodes()
          assert_eq(nodes.length(), 2)
          assert_true(nodes[0].id() == 1)
          assert_true(nodes[1].id() == 4)
        }
      }
  }
  assert_true(tree.without_subtree(99) is Err(UnknownElement))
}
