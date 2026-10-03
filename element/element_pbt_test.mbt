///|
fn element_pbt_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("valid property rectangle rejected")
  }
}

///|
fn element_pbt_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid property point rejected")
  }
}

///|
// Stable suite ID: element.dispatch.focus.invariants
test "property dispatch route is reversible and stop propagation is global" {
  @quickcheck.check(
    (selector : Int) => {
      let root = @element.ElementNode::new(
        1,
        None,
        element_pbt_rect(0.0, 0.0, 100.0, 100.0),
      )
      let left = @element.ElementNode::new(
        2,
        Some(1),
        element_pbt_rect(0.0, 0.0, 50.0, 100.0),
      )
      let left_leaf = @element.ElementNode::new(
        3,
        Some(2),
        element_pbt_rect(0.0, 0.0, 50.0, 100.0),
      )
      let right = @element.ElementNode::new(
        4,
        Some(1),
        element_pbt_rect(50.0, 0.0, 50.0, 100.0),
      )
      match @element.ElementTree::new([root, left, left_leaf, right]) {
        Err(_) => false
        Ok(tree) => {
          let choose_left = selector % 2 == 0
          let point = if choose_left {
            element_pbt_point(25.0, 25.0)
          } else {
            element_pbt_point(75.0, 25.0)
          }
          let expected_target : UInt64 = if choose_left { 3 } else { 4 }
          let expected_length = if choose_left { 3 } else { 2 }
          let plan = tree.dispatch_pointer(point)
          let capture = plan.capture()
          let bubble = plan.bubble()
          let mut routes_match = plan.target() == Some(expected_target) &&
            capture.length() == expected_length &&
            bubble.length() == expected_length
          let mut index = 0
          while index < capture.length() && routes_match {
            routes_match = capture[index] ==
              bubble[bubble.length() - index - 1]
            index += 1
          }
          if !routes_match {
            false
          } else {
            match
              tree.dispatch_pointer_with(point, context => {
                if context.phase() == @element.EventPhase::Capture &&
                  context.current_target() == expected_target {
                  context.stop_propagation()
                }
                Ok(())
              }) {
              Err(_) => false
              Ok(outcome) =>
                outcome.target() == Some(expected_target) &&
                outcome.was_stopped() &&
                outcome.capture_visited().length() == expected_length &&
                outcome.bubble_visited().length() == 0
            }
          }
        }
      }
    },
    count=256,
    max_size=64,
    max_shrinks=500,
    seed=10329009742518438231,
  )
}

///|
// Stable suite ID: element.focus.subtree-removal
test "property removing a subtree never leaves focus on a dead node" {
  @quickcheck.check(
    (remove_focused_branch : Bool) => {
      let bounds = element_pbt_rect(0.0, 0.0, 100.0, 100.0)
      let root = @element.ElementNode::new(1, None, bounds)
      let branch = @element.ElementNode::new(2, Some(1), bounds)
      let focused = @element.ElementNode::new(3, Some(2), bounds).with_focusable(
        true,
      )
      let sibling = @element.ElementNode::new(4, Some(1), bounds)
      match @element.ElementTree::new([root, branch, focused, sibling]) {
        Err(_) => false
        Ok(tree) =>
          match tree.with_focus(3) {
            Err(_) => false
            Ok(focused_tree) => {
              let removed_id : UInt64 = if remove_focused_branch { 2 } else { 4 }
              match focused_tree.without_subtree(removed_id) {
                Err(_) => false
                Ok(next) =>
                  if remove_focused_branch {
                    next.focused() is None &&
                    next.node(2) is None &&
                    next.node(3) is None &&
                    next.node(4) is Some(_)
                  } else {
                    next.focused() == Some(3) &&
                    next.node(3) is Some(_) &&
                    next.node(4) is None
                  }
              }
            }
          }
      }
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=15145738496382914517,
  )
}
