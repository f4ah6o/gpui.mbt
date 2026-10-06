///|
fn owner_test_tree() -> @element.ElementTree {
  let bounds = match @primitives.Rect::new(0.0, 0.0, 20.0, 20.0) {
    Ok(bounds) => bounds
    Err(_) => abort("valid bounds rejected")
  }
  let nodes = [
    @element.ElementNode::new(1, None, bounds),
    @element.ElementNode::new(2, Some(1), bounds).with_focusable(true),
    @element.ElementNode::new(3, Some(1), bounds).with_focusable(true),
    @element.ElementNode::new(4, Some(1), bounds).with_focusable(true),
  ]
  match @element.ElementTree::new(nodes) {
    Ok(tree) => tree
    Err(_) => abort("valid tree rejected")
  }
}

///|
fn owner_test_focus(
  tree : @element.ElementTree,
  id : UInt64,
) -> @element.ElementTree {
  match tree.with_focus(id) {
    Ok(tree) => tree
    Err(_) => abort("valid focus rejected")
  }
}

///|
fn owner_test_capture(tree : @element.ElementTree) -> @element.FocusOwner {
  match tree.focus_owner() {
    Some(owner) => owner
    None => abort("focus acquisition missing")
  }
}

///|
fn owner_test_remove(
  tree : @element.ElementTree,
  id : UInt64,
) -> @element.ElementTree {
  match tree.without_subtree(id) {
    Ok(tree) => tree
    Err(_) => abort("valid subtree removal rejected")
  }
}

///|
test "modal restoration recovers captured ownership without mutating snapshots" {
  let empty = owner_test_tree()
  assert_true(empty.focus_owner() is None)
  let previous = owner_test_focus(empty, 2)
  let previous_owner = owner_test_capture(previous)
  let modal = owner_test_focus(previous, 3)
  let modal_owner = owner_test_capture(modal)
  let restored = modal.restore_focus(Some(previous_owner), modal_owner)
  assert_true(previous_owner.id() == 2)
  assert_true(modal_owner.id() == 3)
  assert_true(restored.focused() == Some(2))
  assert_true(restored.focus_owner() == Some(previous_owner))
  assert_true(modal.focus_owner() == Some(modal_owner))
  assert_true(previous.focus_owner() == Some(previous_owner))
  assert_true(empty.focused() is None)
}

///|
test "modal restoration clears its focus when no prior acquisition existed" {
  let modal = owner_test_focus(owner_test_tree(), 3)
  let restored = modal.restore_focus(None, owner_test_capture(modal))
  assert_true(restored.focused() is None)
  assert_true(restored.focus_owner() is None)
}

///|
test "modal restoration preserves a callback's new focus acquisition" {
  let previous = owner_test_focus(owner_test_tree(), 2)
  let modal = owner_test_focus(previous, 3)
  let callback = owner_test_focus(modal, 4)
  let restored = callback.restore_focus(
    previous.focus_owner(),
    owner_test_capture(modal),
  )
  assert_true(restored.focused() == Some(4))
  assert_true(restored.focus_owner() == callback.focus_owner())
}

///|
test "explicitly refocusing the modal ID prevents an older restoration" {
  let previous = owner_test_focus(owner_test_tree(), 2)
  let modal = owner_test_focus(previous, 3)
  let callback = owner_test_focus(modal, 3)
  let old_owner = owner_test_capture(modal)
  let new_owner = owner_test_capture(callback)
  assert_true(old_owner.id() == new_owner.id())
  assert_true(old_owner != new_owner)
  assert_true(!old_owner.equal(new_owner))
  let restored = callback.restore_focus(previous.focus_owner(), old_owner)
  assert_true(restored.focus_owner() == Some(new_owner))
}

///|
test "modal restoration preserves deliberate clearing or removal of modal focus" {
  let previous = owner_test_focus(owner_test_tree(), 2)
  let modal = owner_test_focus(previous, 3)
  let expected = owner_test_capture(modal)
  let cleared = modal.clear_focus()
  assert_true(
    cleared.restore_focus(previous.focus_owner(), expected).focused() is None,
  )
  let removed = owner_test_remove(modal, 3)
  assert_true(removed.focus_owner() is None)
  assert_true(
    removed.restore_focus(previous.focus_owner(), expected).focused() is None,
  )
}

///|
test "removed prior owner is rejected and modal cleanup leaves focus clear" {
  let previous = owner_test_focus(owner_test_tree(), 2)
  let owner = owner_test_capture(previous)
  let modal = owner_test_focus(previous, 3)
  let removed = owner_test_remove(modal, 2)
  assert_true(removed.focus_owner() == modal.focus_owner())
  assert_true(removed.with_focus_owner(owner) is Err(UnknownElement))
  let restored = removed.restore_focus(Some(owner), owner_test_capture(modal))
  assert_true(restored.focused() is None)
  assert_true(restored.focus_owner() is None)
}

///|
test "immutable subtree changes retain live prior acquisition identity" {
  let previous = owner_test_focus(owner_test_tree(), 2)
  let owner = owner_test_capture(previous)
  let modal = owner_test_focus(previous, 3)
  let removed = owner_test_remove(modal, 4)
  let restored = removed.restore_focus(Some(owner), owner_test_capture(modal))
  assert_true(restored.focus_owner() == Some(owner))
  assert_true(restored.node(4) is None)
  match removed.clear_focus().with_focus_owner(owner) {
    Err(_) => fail("live acquisition was rejected")
    Ok(focused) => assert_true(focused.focus_owner() == Some(owner))
  }
}

///|
test "rebuilding a tree cannot revive reused numeric focus IDs" {
  let previous = owner_test_focus(owner_test_tree(), 2)
  let prior_owner = owner_test_capture(previous)
  let modal = owner_test_focus(previous, 3)
  let modal_owner = owner_test_capture(modal)
  let rebuilt = match @element.ElementTree::new(modal.nodes()) {
    Ok(tree) => tree
    Err(_) => abort("rebuilt tree rejected")
  }
  assert_true(rebuilt.with_focus_owner(prior_owner) is Err(UnknownElement))
  assert_true(rebuilt.with_focus_owner(modal_owner) is Err(UnknownElement))
  let callback = owner_test_focus(rebuilt, 3)
  assert_true(callback.focus_owner() != modal.focus_owner())
  assert_true(
    callback.restore_focus(Some(prior_owner), modal_owner).focus_owner() ==
    callback.focus_owner(),
  )
  // Even when the new modal owns focus, a prior token from the old lineage is
  // stale. This covers removing an owner, then reconstructing its numeric ID.
  let restored = callback.restore_focus(
    Some(prior_owner),
    owner_test_capture(callback),
  )
  assert_true(restored.focused() is None)
}

///|
test "a removed owner replaced under its numeric ID remains stale" {
  let previous = owner_test_focus(owner_test_tree(), 2)
  let prior_owner = owner_test_capture(previous)
  let modal = owner_test_focus(previous, 3)
  let removed = owner_test_remove(modal, 2)
  assert_true(removed.node(2) is None)
  let bounds = match @primitives.Rect::new(5.0, 5.0, 10.0, 10.0) {
    Ok(bounds) => bounds
    Err(_) => abort("valid bounds rejected")
  }
  let replacements = removed.nodes()
  replacements.push(
    @element.ElementNode::new(2, Some(1), bounds).with_focusable(true),
  )
  let rebuilt = match @element.ElementTree::new(replacements) {
    Ok(tree) => tree
    Err(_) => abort("replacement tree rejected")
  }
  assert_true(rebuilt.node(2) is Some(_))
  assert_true(rebuilt.with_focus_owner(prior_owner) is Err(UnknownElement))
  let new_modal = owner_test_focus(rebuilt, 3)
  let restored = new_modal.restore_focus(
    Some(prior_owner),
    owner_test_capture(new_modal),
  )
  assert_true(restored.focused() is None)
}
