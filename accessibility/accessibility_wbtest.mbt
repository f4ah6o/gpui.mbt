///|
fn accessibility_wb_bounds() -> @primitives.Rect {
  @primitives.Rect::new(0.0, 0.0, 20.0, 20.0).unwrap()
}

///|
fn accessibility_wb_root() -> NodeSpec {
  NodeSpec::new(1UL, None, Window, "Window", accessibility_wb_bounds())
}

///|
fn accessibility_wb_button(key : UInt64) -> NodeSpec {
  NodeSpec::new(key, Some(1UL), Button, "Button", accessibility_wb_bounds())
  .with_actions([Invoke])
  .unwrap()
}

///|

///|
test "accessibility generation exhaustion leaves a failed publish atomic" {
  let model = AccessibilityModel::new().unwrap()
  let initial = model.publish([accessibility_wb_root()]).unwrap()
  let root_id = initial.nodes[0].id
  let state = model.state.val
  model.state.val = {
    ..state,
    next_generation: MAX_UINT64,
    generation_exhausted: false,
  }

  // The candidate would consume the final generation for key 2 before key 3
  // exhausts. Failed candidates must not consume it or publish any part.
  match
    model.publish([
      accessibility_wb_root(),
      accessibility_wb_button(2UL),
      accessibility_wb_button(3UL),
    ]) {
    Err(IdentityExhausted) => ()
    _ => assert_true(false)
  }
  let after_failure = model.state.val
  assert_true(after_failure.revision == initial.revision())
  assert_true(after_failure.next_generation == MAX_UINT64)
  assert_true(!after_failure.generation_exhausted)
  assert_true(after_failure.current.nodes.length() == 1)
  assert_true(after_failure.current.nodes[0].id == root_id)

  let admitted = model
    .publish([accessibility_wb_root(), accessibility_wb_button(2UL)])
    .unwrap()
  assert_true(admitted.nodes[1].id.generation == MAX_UINT64)
  assert_true(admitted.nodes[0].id == root_id)

  // Existing live IDs can be updated after generation exhaustion, but no
  // newly admitted node, including a removed-and-reused key, can reuse an ID.
  let stable = model
    .publish([accessibility_wb_root(), accessibility_wb_button(2UL)])
    .unwrap()
  assert_true(stable.nodes[1].id == admitted.nodes[1].id)
  match
    model.publish([
      accessibility_wb_root(),
      accessibility_wb_button(2UL),
      accessibility_wb_button(3UL),
    ]) {
    Err(IdentityExhausted) => ()
    _ => assert_true(false)
  }

  let removed = model.publish([accessibility_wb_root()]).unwrap()
  assert_true(removed.nodes[0].id == root_id)
  assert_true(
    model.resolve_action(ActionRequest::new(admitted.nodes[1].id, Invoke))
    is Err(StaleNode),
  )
  let before_reuse_failure = model.snapshot()
  match model.publish([accessibility_wb_root(), accessibility_wb_button(2UL)]) {
    Err(IdentityExhausted) => ()
    _ => assert_true(false)
  }
  assert_true(model.snapshot().revision() == before_reuse_failure.revision())
  assert_true(model.snapshot().nodes.length() == 1)
  assert_true(
    model.resolve_action(ActionRequest::new(admitted.nodes[1].id, Invoke))
    is Err(StaleNode),
  )
}

///|
test "accessibility revision exhaustion rejects ordinary commits and reset" {
  let model = AccessibilityModel::new().unwrap()
  let copied_handle = model
  let initial = model
    .publish([accessibility_wb_root(), accessibility_wb_button(2UL)])
    .unwrap()
  let node_id = initial.nodes[1].id
  let near_max = MAX_UINT64 - 1UL
  let state = model.state.val
  model.state.val = {
    ..state,
    revision: near_max,
    revision_exhausted: false,
    current: { ..state.current, revision: near_max, },
  }

  let committed = model
    .publish([accessibility_wb_root(), accessibility_wb_button(2UL)])
    .unwrap()
  assert_true(committed.revision() == MAX_UINT64)
  match model.publish([accessibility_wb_root()]) {
    Err(RevisionExhausted) => ()
    _ => assert_true(false)
  }
  match model.reset() {
    Err(RevisionExhausted) => ()
    _ => assert_true(false)
  }
  assert_true(model.snapshot().revision() == MAX_UINT64)
  assert_true(model.snapshot().nodes.length() == 2)

  model.close()
  model.close()
  assert_true(copied_handle.snapshot().revision() == MAX_UINT64)
  assert_true(copied_handle.snapshot().nodes.length() == 0)
  assert_true(
    model.resolve_action(ActionRequest::new(node_id, Invoke))
    is Err(ModelClosed),
  )
}

///|
test "accessibility reset can reach max revision once and close still revokes" {
  let model = AccessibilityModel::new().unwrap()
  let initial = model.publish([accessibility_wb_root()]).unwrap()
  let near_max = MAX_UINT64 - 1UL
  let state = model.state.val
  model.state.val = {
    ..state,
    revision: near_max,
    revision_exhausted: false,
    current: { ..state.current, revision: near_max, },
  }

  let empty = model.reset().unwrap()
  assert_true(empty.revision() == MAX_UINT64)
  assert_true(empty.nodes.length() == 0)
  match model.reset() {
    Err(RevisionExhausted) => ()
    _ => assert_true(false)
  }
  assert_true(model.snapshot().revision() == MAX_UINT64)
  assert_true(model.snapshot().nodes.length() == 0)

  model.close()
  assert_true(model.snapshot().revision() == MAX_UINT64)
  assert_true(model.snapshot().nodes.length() == 0)
  assert_true(initial.nodes.length() == 1)
}

///|
test "accessibility model owner and close status are observable without IDs" {
  let model = AccessibilityModel::new().unwrap()
  let copied_handle = model
  let foreign_model = AccessibilityModel::new().unwrap()
  let empty = model.snapshot()
  assert_true(model.same_owner(copied_handle))
  assert_true(!model.same_owner(foreign_model))
  assert_true(!model.is_closed())
  assert_true(model.is_current_snapshot(empty))
  assert_true(!foreign_model.is_current_snapshot(empty))
  let committed = model.publish([accessibility_wb_root()]).unwrap()
  assert_true(!model.is_current_snapshot(empty))
  assert_true(model.is_current_snapshot(committed))
  model.close()
  assert_true(copied_handle.is_closed())
  assert_true(!copied_handle.is_current_snapshot(committed))
  assert_true(foreign_model.same_owner(foreign_model))
  assert_true(!foreign_model.is_closed())
  foreign_model.close()
}
