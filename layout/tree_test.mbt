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
