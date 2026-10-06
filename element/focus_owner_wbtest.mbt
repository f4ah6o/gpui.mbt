///|
test "focus identity exhaustion is typed and never wraps or blocks restoration" {
  let bounds = match @primitives.Rect::new(0.0, 0.0, 10.0, 10.0) {
    Ok(bounds) => bounds
    Err(_) => abort("valid bounds rejected")
  }
  let nodes = [ElementNode::new(1, None, bounds).with_focusable(true)]
  let tree = match ElementTree::new(nodes) {
    Ok(tree) => tree
    Err(_) => abort("valid tree rejected")
  }
  let focused = match tree.with_focus(1) {
    Ok(tree) => tree
    Err(_) => abort("valid focus rejected")
  }
  let owner = match focused.focus_owner() {
    Some(owner) => owner
    None => abort("focus acquisition missing")
  }
  let saved = focus_identity_sequence.val
  focus_identity_sequence.val = 0xffff_ffff_ffff_ffff
  let new_tree = ElementTree::new(nodes)
  let new_focus = tree.with_focus(1)
  let restored = tree.with_focus_owner(owner)
  let exhausted_value = focus_identity_sequence.val
  focus_identity_sequence.val = saved
  assert_true(new_tree is Err(FocusIdentityExhausted))
  assert_true(new_focus is Err(FocusIdentityExhausted))
  assert_true(exhausted_value == 0xffff_ffff_ffff_ffff)
  match restored {
    Err(_) => fail("restoring existing ownership must not allocate identity")
    Ok(restored) => assert_true(restored.focus_owner() == Some(owner))
  }
}
