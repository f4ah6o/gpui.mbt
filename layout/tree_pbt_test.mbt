///|
fn tree_pbt_size(width : Double, height : Double) -> @primitives.Size {
  match @primitives.Size::new(width, height) {
    Ok(value) => value
    Err(_) => abort("valid recursive property size rejected")
  }
}

///|
fn tree_pbt_points(value : Double) -> @layout.Dimension {
  match @layout.Dimension::points(value) {
    Ok(result) => result
    Err(_) => abort("valid recursive property dimension rejected")
  }
}

///|
fn tree_pbt_sized_item(
  id : UInt64,
  direction : @layout.FlowDirection,
  width : Double,
  height : Double,
) -> @layout.FlexItem {
  let main = if direction is @layout.Row {
    tree_pbt_points(width)
  } else {
    tree_pbt_points(height)
  }
  let cross = if direction is @layout.Row {
    tree_pbt_points(height)
  } else {
    tree_pbt_points(width)
  }
  @layout.FlexItem::new(id, main, cross, tree_pbt_size(width, height))
}

///|
// Stable suite ID: layout.flex-tree.invariants
test "property recursive layout is deterministic and descendants stay ordered" {
  @quickcheck.check(
    (values : (Int, Int, Int, Int)) => {
      let (root_width0, branch_width0, leaf_height0, gap0) = values
      let root_width = (root_width0 % 300).abs().to_double() + 100.0
      let branch_width = (branch_width0 % 60).abs().to_double() + 20.0
      let leaf_height = (leaf_height0 % 20).abs().to_double() + 1.0
      let gap = (gap0 % 8).abs().to_double()
      let root_style_result = @layout.FlexTreeStyle::new(
        @layout.FlowDirection::row(),
      ).with_gap(gap)
      let child_style_result = @layout.FlexTreeStyle::new(
        @layout.FlowDirection::column(),
      ).with_gap(gap)
      match (root_style_result, child_style_result) {
        (Ok(root_style), Ok(child_style)) => {
          let branch = @layout.FlexTreeNode::new(
            @layout.FlexItem::new(
              2,
              tree_pbt_points(branch_width),
              tree_pbt_points(80.0),
              tree_pbt_size(branch_width, 80.0),
            ),
            1,
          ).with_children(child_style)
          let leaf_a = @layout.FlexTreeNode::new(
            @layout.FlexItem::new(
              3,
              tree_pbt_points(20.0),
              tree_pbt_points(leaf_height),
              tree_pbt_size(20.0, leaf_height),
            ),
            2,
          )
          let leaf_b = @layout.FlexTreeNode::new(
            @layout.FlexItem::new(
              4,
              tree_pbt_points(20.0),
              tree_pbt_points(leaf_height),
              tree_pbt_size(20.0, leaf_height),
            ),
            2,
          )
          let sibling = @layout.FlexTreeNode::new(
            @layout.FlexItem::new(
              5,
              tree_pbt_points(20.0),
              tree_pbt_points(80.0),
              tree_pbt_size(20.0, 80.0),
            ),
            1,
          )
          let nodes = [branch, leaf_a, leaf_b, sibling]
          match
            (
              @layout.layout_flex_tree(
                1,
                tree_pbt_size(root_width, 80.0),
                root_style,
                nodes,
              ),
              @layout.layout_flex_tree(
                1,
                tree_pbt_size(root_width, 80.0),
                root_style,
                nodes,
              ),
            ) {
            (Ok(first), Ok(second)) => {
              let a = first.items()
              let b = second.items()
              a.length() == 4 &&
              b.length() == 4 &&
              a[0].id() == 2 &&
              a[1].id() == 3 &&
              a[2].id() == 4 &&
              a[3].id() == 5 &&
              a[0].bounds() == b[0].bounds() &&
              a[1].bounds() == b[1].bounds() &&
              a[2].bounds() == b[2].bounds() &&
              a[3].bounds() == b[3].bounds() &&
              a[1].bounds().left() >= a[0].bounds().left() &&
              a[1].bounds().right() <= a[0].bounds().right() &&
              a[1].bounds().top() <= a[2].bounds().top()
            }
            _ => false
          }
        }
        _ => false
      }
    },
    count=256,
    max_size=64,
    max_shrinks=500,
    seed=4323271489673228617,
  )
}

///|
/// Stable suite ID: layout.flex-tree.auto-sizing
test "property auto container dimensions sum flow sizes and maximize cross sizes" {
  @quickcheck.check(
    (values : (Int, Int, Int, Int, Int, Int)) => {
      let (direction0, width_a0, height_a0, width_b0, height_b0, gap0) = values
      let direction = if (direction0 % 2).abs() == 0 {
        @layout.FlowDirection::row()
      } else {
        @layout.FlowDirection::column()
      }
      let width_a = (width_a0 % 60).abs().to_double() + 1.0
      let height_a = (height_a0 % 60).abs().to_double() + 1.0
      let width_b = (width_b0 % 60).abs().to_double() + 1.0
      let height_b = (height_b0 % 60).abs().to_double() + 1.0
      let gap = (gap0 % 8).abs().to_double()
      let child_style_result = @layout.FlexTreeStyle::new(direction).with_gap(
        gap,
      )
      match child_style_result {
        Err(_) => false
        Ok(child_style) => {
          let root_style = @layout.FlexTreeStyle::new(
            @layout.FlowDirection::row(),
          )
          let auto_item = @layout.FlexItem::new(
            2,
            @layout.Dimension::auto(),
            @layout.Dimension::auto(),
            tree_pbt_size(900.0, 900.0),
          )
          let branch = @layout.FlexTreeNode::new(auto_item, 1).with_children(
            child_style,
          )
          let first = @layout.FlexTreeNode::new(
            tree_pbt_sized_item(3, direction, width_a, height_a),
            2,
          )
          let second = @layout.FlexTreeNode::new(
            tree_pbt_sized_item(4, direction, width_b, height_b),
            2,
          )
          let expected_width = if direction is @layout.Row {
            width_a + width_b + gap
          } else if width_a > width_b {
            width_a
          } else {
            width_b
          }
          let expected_height = if direction is @layout.Row {
            if height_a > height_b {
              height_a
            } else {
              height_b
            }
          } else {
            height_a + height_b + gap
          }
          match
            (
              @layout.layout_flex_tree(
                1,
                tree_pbt_size(400.0, 400.0),
                root_style,
                [branch, first, second],
              ),
              @layout.layout_flex_tree(
                1,
                tree_pbt_size(400.0, 400.0),
                root_style,
                [branch, first, second],
              ),
            ) {
            (Ok(left), Ok(right)) => {
              let left_boxes = left.items()
              let right_boxes = right.items()
              left_boxes.length() == 3 &&
              right_boxes.length() == 3 &&
              left_boxes[0].id() == 2 &&
              left_boxes[0].bounds().size().width() == expected_width &&
              left_boxes[0].bounds().size().height() == expected_height &&
              left_boxes[0].bounds() == right_boxes[0].bounds() &&
              left_boxes[2].bounds().top() >= left_boxes[0].bounds().top()
            }
            _ => false
          }
        }
      }
    },
    count=256,
    max_size=64,
    max_shrinks=500,
    seed=8285246981798288716,
  )
}
