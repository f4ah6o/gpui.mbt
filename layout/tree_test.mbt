///|
fn tree_size(width : Double, height : Double) -> @primitives.Size {
  match @primitives.Size::new(width, height) {
    Ok(value) => value
    Err(_) => abort("valid tree size rejected")
  }
}

///|
fn tree_points(value : Double) -> @layout.Dimension {
  match @layout.Dimension::points(value) {
    Ok(result) => result
    Err(_) => abort("valid tree dimension rejected")
  }
}

///|
fn tree_item(id : UInt64, main : Double, cross : Double) -> @layout.FlexItem {
  @layout.FlexItem::new(
    id,
    tree_points(main),
    tree_points(cross),
    tree_size(main, cross),
  )
}

///|
fn tree_auto_item(
  id : UInt64,
  main : @layout.Dimension,
  cross : @layout.Dimension,
  intrinsic : @primitives.Size,
) -> @layout.FlexItem {
  @layout.FlexItem::new(id, main, cross, intrinsic)
}

///|
fn tree_insets(
  top : Double,
  right : Double,
  bottom : Double,
  left : Double,
) -> @layout.Insets {
  match @layout.Insets::new(top, right, bottom, left) {
    Ok(value) => value
    Err(_) => abort("valid tree insets rejected")
  }
}

///|
test "recursive flex tree produces absolute stable preorder bounds" {
  let root_style = match
    @layout.FlexTreeStyle::new(@layout.FlowDirection::row()).with_gap(10.0) {
    Ok(value) => value
    Err(_) => abort("valid root style rejected")
  }
  let child_style = match
    @layout.FlexTreeStyle::new(@layout.FlowDirection::column()).with_gap(5.0) {
    Ok(value) => value
    Err(_) => abort("valid child style rejected")
  }
  let branch = @layout.FlexTreeNode::new(tree_item(2, 60.0, 80.0), 1).with_children(
    child_style,
  )
  let leaf_a = @layout.FlexTreeNode::new(tree_item(3, 20.0, 30.0), 2)
  let leaf_b = @layout.FlexTreeNode::new(tree_item(4, 20.0, 30.0), 2)
  let sibling = @layout.FlexTreeNode::new(tree_item(5, 30.0, 80.0), 1)
  match
    @layout.layout_flex_tree(1, tree_size(100.0, 80.0), root_style, [
      branch, leaf_a, leaf_b, sibling,
    ]) {
    Err(_) => fail("valid recursive tree rejected")
    Ok(result) => {
      assert_true(result.root_id() == 1)
      assert_true(!result.overflow())
      let items = result.items()
      assert_eq(items.length(), 4)
      assert_true(items[0].id() == 2)
      assert_true(items[1].id() == 3)
      assert_true(items[2].id() == 4)
      assert_true(items[3].id() == 5)
      assert_true(items[0].bounds().left() == 0.0)
      assert_true(items[0].bounds().top() == 0.0)
      assert_true(items[0].bounds().size().width() == 60.0)
      assert_true(items[1].bounds().left() == 0.0)
      assert_true(items[1].bounds().top() == 0.0)
      assert_true(items[2].bounds().top() == 25.0)
      assert_true(items[3].bounds().left() == 70.0)
    }
  }
}

///|
test "recursive flex tree rejects missing parents and closed subtrees" {
  let style = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let missing = @layout.FlexTreeNode::new(tree_item(2, 10.0, 10.0), 99)
  assert_true(
    @layout.layout_flex_tree(1, tree_size(100.0, 20.0), style, [missing])
    is Err(MissingParent),
  )

  let branch = @layout.FlexTreeNode::new(tree_item(2, 10.0, 10.0), 1)
  let sibling = @layout.FlexTreeNode::new(tree_item(3, 10.0, 10.0), 1)
  let late_child = @layout.FlexTreeNode::new(tree_item(4, 5.0, 5.0), 2)
  assert_true(
    @layout.layout_flex_tree(1, tree_size(100.0, 20.0), style, [
      branch, sibling, late_child,
    ])
    is Err(InvalidPreorder),
  )
}

///|
test "recursive flex tree requires container style for live children" {
  let style = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let branch = @layout.FlexTreeNode::new(tree_item(2, 40.0, 20.0), 1)
  let child = @layout.FlexTreeNode::new(tree_item(3, 10.0, 10.0), 2)
  assert_true(
    @layout.layout_flex_tree(1, tree_size(100.0, 20.0), style, [branch, child])
    is Err(MissingContainer),
  )
}

///|
test "auto containers measure nested row and column content with insets and limits" {
  let root_style = match
    @layout.FlexTreeStyle::new(@layout.FlowDirection::row()).with_gap(7.0) {
    Ok(value) => value
    Err(_) => abort("valid root gap rejected")
  }
  let column_style = match
    @layout.FlexTreeStyle::new(@layout.FlowDirection::column()).with_gap(3.0) {
    Ok(value) =>
      value.with_insets(tree_insets(2.0, 6.0, 1.0, 5.0), @layout.Insets::zero())
    Err(_) => abort("valid column gap rejected")
  }
  let row_style = match
    @layout.FlexTreeStyle::new(@layout.FlowDirection::row()).with_gap(2.0) {
    Ok(value) =>
      value.with_insets(tree_insets(1.0, 2.0, 3.0, 4.0), @layout.Insets::zero())
    Err(_) => abort("valid row gap rejected")
  }

  let column = @layout.FlexTreeNode::new(
    tree_auto_item(
      2,
      @layout.Dimension::auto(),
      @layout.Dimension::auto(),
      tree_size(999.0, 999.0),
    ),
    1,
  ).with_children(column_style)
  let nested_row = @layout.FlexTreeNode::new(
    tree_auto_item(
      4,
      @layout.Dimension::auto(),
      @layout.Dimension::auto(),
      tree_size(999.0, 999.0),
    ),
    2,
  ).with_children(row_style)
  let leaf_a_item = match
    tree_auto_item(
      5,
      tree_points(20.0),
      tree_points(10.0),
      tree_size(20.0, 10.0),
    ).with_main_limits(25.0, None) {
    Ok(value) => value
    Err(_) => abort("valid main minimum rejected")
  }
  let leaf_a_item = match leaf_a_item.with_cross_limits(0.0, Some(9.0)) {
    Ok(value) => value
    Err(_) => abort("valid cross maximum rejected")
  }
  let leaf_a = @layout.FlexTreeNode::new(leaf_a_item, 4)
  let leaf_b = @layout.FlexTreeNode::new(
    tree_auto_item(6, tree_points(30.0), tree_points(8.0), tree_size(30.0, 8.0)),
    4,
  )
  let sibling = @layout.FlexTreeNode::new(
    tree_auto_item(
      3,
      @layout.Dimension::auto(),
      @layout.Dimension::auto(),
      tree_size(25.0, 12.0),
    ),
    1,
  )

  match
    @layout.layout_flex_tree(1, tree_size(300.0, 100.0), root_style, [
      column, nested_row, leaf_a, leaf_b, sibling,
    ]) {
    Err(_) => fail("nested auto containers rejected")
    Ok(result) => {
      assert_true(!result.overflow())
      let boxes = result.items()
      assert_eq(boxes.length(), 5)
      assert_true(boxes[0].id() == 2)
      assert_true(boxes[0].bounds().size().width() == 74.0)
      assert_true(boxes[0].bounds().size().height() == 16.0)
      assert_true(boxes[1].id() == 4)
      assert_true(boxes[1].bounds().left() == 5.0)
      assert_true(boxes[1].bounds().top() == 2.0)
      assert_true(boxes[1].bounds().size().width() == 63.0)
      assert_true(boxes[1].bounds().size().height() == 13.0)
      assert_true(boxes[2].id() == 5)
      assert_true(boxes[2].bounds().left() == 9.0)
      assert_true(boxes[2].bounds().top() == 3.0)
      assert_true(boxes[2].bounds().size().width() == 25.0)
      assert_true(boxes[2].bounds().size().height() == 9.0)
      assert_true(boxes[3].id() == 6)
      assert_true(boxes[3].bounds().left() == 36.0)
      assert_true(boxes[4].id() == 3)
      assert_true(boxes[4].bounds().left() == 81.0)
      assert_true(boxes[4].bounds().size().width() == 25.0)
      assert_true(boxes[4].bounds().size().height() == 12.0)
    }
  }
}

///|
test "auto sibling container keeps its measured base before flex growth" {
  let root_style = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let branch_style = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let growing_item = match
    tree_auto_item(
      2,
      @layout.Dimension::auto(),
      @layout.Dimension::auto(),
      tree_size(900.0, 900.0),
    ).with_flex(1.0, 1.0) {
    Ok(value) => value
    Err(_) => abort("valid flex factors rejected")
  }
  let first = @layout.FlexTreeNode::new(growing_item, 1).with_children(
    branch_style,
  )
  let second = @layout.FlexTreeNode::new(
    tree_auto_item(
      3,
      @layout.Dimension::auto(),
      @layout.Dimension::auto(),
      tree_size(900.0, 900.0),
    ),
    1,
  ).with_children(branch_style)
  let first_child = @layout.FlexTreeNode::new(
    tree_auto_item(
      4,
      tree_points(30.0),
      tree_points(10.0),
      tree_size(30.0, 10.0),
    ),
    2,
  )
  let second_child = @layout.FlexTreeNode::new(
    tree_auto_item(
      5,
      tree_points(20.0),
      tree_points(12.0),
      tree_size(20.0, 12.0),
    ),
    3,
  )
  match
    @layout.layout_flex_tree(1, tree_size(100.0, 40.0), root_style, [
      first, first_child, second, second_child,
    ]) {
    Err(_) => fail("auto sibling containers rejected")
    Ok(result) => {
      let boxes = result.items()
      assert_eq(boxes.length(), 4)
      assert_true(boxes[0].id() == 2)
      assert_true(boxes[0].bounds().size().width() == 80.0)
      assert_true(boxes[0].bounds().size().height() == 10.0)
      assert_true(boxes[1].id() == 4)
      assert_true(boxes[1].bounds().size().width() == 30.0)
      assert_true(boxes[2].id() == 3)
      assert_true(boxes[2].bounds().left() == 80.0)
      assert_true(boxes[2].bounds().size().width() == 20.0)
      assert_true(boxes[2].bounds().size().height() == 12.0)
      assert_true(boxes[3].bounds().left() == 80.0)
      assert_true(boxes[3].bounds().size().width() == 20.0)
    }
  }
}

///|
test "auto sizing rejects percentages only on indefinite measured axes" {
  let root_style = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let auto_row = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
  let auto_parent = @layout.FlexTreeNode::new(
    tree_auto_item(
      2,
      @layout.Dimension::auto(),
      tree_points(40.0),
      tree_size(100.0, 40.0),
    ),
    1,
  ).with_children(auto_row)
  let percent_main = match @layout.Dimension::percent(0.5) {
    Ok(value) => value
    Err(_) => abort("valid percentage rejected")
  }
  let percentage_child = @layout.FlexTreeNode::new(
    tree_auto_item(3, percent_main, tree_points(10.0), tree_size(10.0, 10.0)),
    2,
  )
  assert_true(
    @layout.layout_flex_tree(1, tree_size(200.0, 100.0), root_style, [
      auto_parent, percentage_child,
    ])
    is Err(Flex(IndefinitePercentage)),
  )

  let definite_parent = @layout.FlexTreeNode::new(
    tree_auto_item(
      4,
      tree_points(100.0),
      @layout.Dimension::auto(),
      tree_size(100.0, 500.0),
    ),
    1,
  ).with_children(@layout.FlexTreeStyle::new(@layout.FlowDirection::column()))
  let percent_cross = match @layout.Dimension::percent(0.5) {
    Ok(value) => value
    Err(_) => abort("valid cross percentage rejected")
  }
  let definite_child = @layout.FlexTreeNode::new(
    tree_auto_item(5, tree_points(20.0), percent_cross, tree_size(50.0, 20.0)),
    4,
  )
  match
    @layout.layout_flex_tree(1, tree_size(200.0, 100.0), root_style, [
      definite_parent, definite_child,
    ]) {
    Err(_) => fail("percentage against definite orthogonal axis rejected")
    Ok(result) => {
      let boxes = result.items()
      assert_true(boxes[0].bounds().size().width() == 100.0)
      assert_true(boxes[0].bounds().size().height() == 20.0)
      assert_true(boxes[1].bounds().size().width() == 50.0)
      assert_true(boxes[1].bounds().size().height() == 20.0)
    }
  }
}

///|
test "recursive flex tree rejects nesting beyond the supported depth" {
  let nodes : Array[@layout.FlexTreeNode] = []
  let mut id : UInt64 = 2
  let mut parent : UInt64 = 1
  let mut depth = 0
  while depth <= @layout.MAX_FLEX_TREE_DEPTH {
    nodes.push(@layout.FlexTreeNode::new(tree_item(id, 1.0, 1.0), parent))
    parent = id
    id += 1
    depth += 1
  }
  assert_true(
    @layout.layout_flex_tree(
      1,
      tree_size(100.0, 100.0),
      @layout.FlexTreeStyle::new(@layout.FlowDirection::row()),
      nodes,
    )
    is Err(TreeTooDeep),
  )
}
