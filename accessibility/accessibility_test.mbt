///|
fn accessibility_test_bounds() -> @primitives.Rect {
  @primitives.Rect::new(1.0, 2.0, 80.0, 28.0).unwrap()
}

///|
fn accessibility_test_root(key : UInt64) -> @accessibility.NodeSpec {
  @accessibility.NodeSpec::new(
    key,
    None,
    @accessibility.Window,
    "Main window",
    accessibility_test_bounds(),
  )
}

///|
fn accessibility_test_button(
  key : UInt64,
  parent_key : UInt64,
  name : String,
) -> @accessibility.NodeSpec {
  @accessibility.NodeSpec::new(
    key,
    Some(parent_key),
    @accessibility.Button,
    name,
    accessibility_test_bounds(),
  )
  .with_actions([@accessibility.Invoke])
  .unwrap()
}

///|
fn accessibility_action_is_error(
  model : @accessibility.AccessibilityModel,
  request : @accessibility.ActionRequest,
  expected : @accessibility.ActionError,
) -> Bool {
  match model.resolve_action(request) {
    Err(error) => error == expected
    Ok(_) => false
  }
}

///|
test "accessibility snapshot is copied and committed before return" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let specs = [
    accessibility_test_root(1UL),
    accessibility_test_button(2UL, 1UL, "Save"),
  ]
  let committed = model.publish(specs).unwrap()
  let committed_revision = committed.revision()
  let original_id = committed.nodes()[1].id()
  assert_eq(original_id.key(), 2UL)

  // Mutating the caller's input and returned arrays cannot rewrite the snapshot.
  specs[1] = accessibility_test_button(2UL, 1UL, "Changed")
  let escaped_nodes = committed.nodes()
  escaped_nodes[0] = escaped_nodes[1]
  let escaped_children = committed.nodes()[0].children()
  escaped_children.push(original_id)
  let escaped_actions = committed.nodes()[1].supported_actions()
  escaped_actions.push(@accessibility.Invoke)

  assert_eq(committed.nodes().length(), 2)
  assert_eq(committed.nodes()[1].name(), "Save")
  assert_eq(committed.nodes()[0].children().length(), 1)
  assert_eq(committed.nodes()[1].supported_actions().length(), 1)
  assert_eq(model.snapshot().revision(), committed_revision)
  assert_true(model.snapshot().nodes()[1].id() == original_id)
}

///|
test "accessibility IDs survive updates and stale on removal or reuse" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let first = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save"),
    ])
    .unwrap()
  let original_id = first.nodes()[1].id()

  let updated = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save changes"),
    ])
    .unwrap()
  assert_true(updated.nodes()[1].id() == original_id)
  assert_true(
    model.resolve_action(
      @accessibility.ActionRequest::new(original_id, @accessibility.Invoke),
    )
    is Ok(_),
  )

  let _ = model.publish([accessibility_test_root(1UL)]).unwrap()
  assert_true(
    accessibility_action_is_error(
      model,
      @accessibility.ActionRequest::new(original_id, @accessibility.Invoke),
      @accessibility.StaleNode,
    ),
  )

  let reused = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save again"),
    ])
    .unwrap()
  let replacement_id = reused.nodes()[1].id()
  assert_true(replacement_id != original_id)
  assert_true(
    accessibility_action_is_error(
      model,
      @accessibility.ActionRequest::new(original_id, @accessibility.Invoke),
      @accessibility.StaleNode,
    ),
  )
}

///|
test "accessibility owner provenance and copied-handle revocation" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let copied_handle = model
  let foreign = @accessibility.AccessibilityModel::new().unwrap()
  let snapshot = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save"),
    ])
    .unwrap()
  let node_id = snapshot.nodes()[1].id()

  assert_true(
    accessibility_action_is_error(
      foreign,
      @accessibility.ActionRequest::new(node_id, @accessibility.Invoke),
      @accessibility.ForeignOwner,
    ),
  )

  let reset_snapshot = model.reset().unwrap()
  assert_eq(reset_snapshot.nodes().length(), 0)
  assert_eq(copied_handle.snapshot().nodes().length(), 0)
  assert_true(
    accessibility_action_is_error(
      copied_handle,
      @accessibility.ActionRequest::new(node_id, @accessibility.Invoke),
      @accessibility.StaleNode,
    ),
  )

  let replacement = copied_handle
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save"),
    ])
    .unwrap()
  let replacement_id = replacement.nodes()[1].id()
  assert_true(replacement_id != node_id)

  copied_handle.close()
  assert_eq(model.snapshot().nodes().length(), 0)
  assert_true(
    accessibility_action_is_error(
      model,
      @accessibility.ActionRequest::new(replacement_id, @accessibility.Invoke),
      @accessibility.ModelClosed,
    ),
  )
  assert_true(model.publish([accessibility_test_root(1UL)]) is Err(_))
}

///|
test "accessibility Invoke capability is distinct from current availability" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let plain = @accessibility.NodeSpec::new(
    2UL,
    Some(1UL),
    @accessibility.Button,
    "Plain",
    accessibility_test_bounds(),
  )
  let disabled = accessibility_test_button(3UL, 1UL, "Disabled").with_enabled(
    false,
  )
  let loading = accessibility_test_button(4UL, 1UL, "Saving").with_loading(true)
  let focused_loading = accessibility_test_button(5UL, 1UL, "Busy")
    .with_loading(true)
    .with_focused(true)
  let ready = accessibility_test_button(6UL, 1UL, "Ready")
  let snapshot = model
    .publish([
      accessibility_test_root(1UL),
      plain,
      disabled,
      loading,
      focused_loading,
      ready,
    ])
    .unwrap()
  let nodes = snapshot.nodes()

  assert_true(
    accessibility_action_is_error(
      model,
      @accessibility.ActionRequest::new(nodes[1].id(), @accessibility.Invoke),
      @accessibility.UnsupportedAction,
    ),
  )
  assert_true(
    accessibility_action_is_error(
      model,
      @accessibility.ActionRequest::new(nodes[2].id(), @accessibility.Invoke),
      @accessibility.Disabled,
    ),
  )
  assert_true(
    accessibility_action_is_error(
      model,
      @accessibility.ActionRequest::new(nodes[3].id(), @accessibility.Invoke),
      @accessibility.Loading,
    ),
  )

  let intent = model
    .resolve_action(
      @accessibility.ActionRequest::new(nodes[5].id(), @accessibility.Invoke),
    )
    .unwrap()
  assert_true(intent.action() == @accessibility.Invoke)
  assert_true(intent.node_id() == nodes[5].id())
  assert_eq(intent.revision(), snapshot.revision())
}

///|
test "accessibility queued requests are revalidated at consumption" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let initial = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save"),
    ])
    .unwrap()
  let queued = @accessibility.ActionRequest::new(
    initial.nodes()[1].id(),
    @accessibility.Invoke,
  )

  let loading = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save").with_loading(true),
    ])
    .unwrap()
  assert_true(loading.nodes()[1].id() == initial.nodes()[1].id())
  assert_true(
    accessibility_action_is_error(model, queued, @accessibility.Loading),
  )

  let _ = model.publish([accessibility_test_root(1UL)]).unwrap()
  let _ = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Replacement"),
    ])
    .unwrap()
  assert_true(
    accessibility_action_is_error(model, queued, @accessibility.StaleNode),
  )
}

///|
test "accessibility intents are repeatable validation receipts" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let snapshot = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save"),
    ])
    .unwrap()
  let request = @accessibility.ActionRequest::new(
    snapshot.nodes()[1].id(),
    @accessibility.Invoke,
  )
  let first = model.resolve_action(request).unwrap()
  let second = model.resolve_action(request).unwrap()

  assert_true(first.node_id() == second.node_id())
  assert_true(first.action() == second.action())
  assert_eq(first.revision(), second.revision())
}

///|
test "accessibility rejects duplicate keys cycles and non-preorder atomically" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let committed = model
    .publish([
      accessibility_test_root(1UL),
      accessibility_test_button(2UL, 1UL, "Save"),
    ])
    .unwrap()
  let revision = committed.revision()
  let node_id = committed.nodes()[1].id()

  match
    model.publish([
      accessibility_test_root(1UL),
      accessibility_test_button(1UL, 1UL, "Duplicate"),
    ]) {
    Err(@accessibility.DuplicateNodeKey) => ()
    _ => assert_true(false)
  }
  match
    model.publish([
      @accessibility.NodeSpec::new(
        1UL,
        Some(2UL),
        @accessibility.Group,
        "Cycle A",
        accessibility_test_bounds(),
      ),
      @accessibility.NodeSpec::new(
        2UL,
        Some(1UL),
        @accessibility.Group,
        "Cycle B",
        accessibility_test_bounds(),
      ),
    ]) {
    Err(@accessibility.InvalidPreorder) => ()
    _ => assert_true(false)
  }
  match
    model.publish([
      accessibility_test_root(1UL),
      @accessibility.NodeSpec::new(
        2UL,
        Some(1UL),
        @accessibility.Group,
        "First",
        accessibility_test_bounds(),
      ),
      @accessibility.NodeSpec::new(
        3UL,
        Some(1UL),
        @accessibility.Group,
        "Second",
        accessibility_test_bounds(),
      ),
      @accessibility.NodeSpec::new(
        4UL,
        Some(2UL),
        @accessibility.Group,
        "Late child",
        accessibility_test_bounds(),
      ),
    ]) {
    Err(@accessibility.InvalidPreorder) => ()
    _ => assert_true(false)
  }

  assert_eq(model.snapshot().revision(), revision)
  assert_true(model.snapshot().nodes()[1].id() == node_id)
  assert_true(
    model.resolve_action(
      @accessibility.ActionRequest::new(node_id, @accessibility.Invoke),
    )
    is Ok(_),
  )
}

///|
test "accessibility focus is unique and loading focus remains valid" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let first_focused = accessibility_test_button(2UL, 1UL, "First").with_focused(
    true,
  )
  let second_focused = accessibility_test_button(3UL, 1UL, "Second").with_focused(
    true,
  )
  match
    model.publish([accessibility_test_root(1UL), first_focused, second_focused]) {
    Err(@accessibility.MultipleFocusedNodes) => ()
    _ => assert_true(false)
  }

  let disabled_focused = accessibility_test_button(4UL, 1UL, "Disabled")
    .with_enabled(false)
    .with_focused(true)
  match model.publish([accessibility_test_root(1UL), disabled_focused]) {
    Err(@accessibility.FocusedNodeDisabled) => ()
    _ => assert_true(false)
  }

  let loading_focused = accessibility_test_button(5UL, 1UL, "Loading")
    .with_loading(true)
    .with_focused(true)
  let snapshot = model
    .publish([accessibility_test_root(1UL), loading_focused])
    .unwrap()
  assert_true(snapshot.nodes()[1].is_focused())
  assert_true(snapshot.nodes()[1].is_loading())
}

///|
test "accessibility bounds node count depth and snapshot text" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let too_many : Array[@accessibility.NodeSpec] = []
  let mut index = 0
  while index <= @accessibility.max_node_count {
    let key = index.to_uint64() + 1UL
    let parent_key = if index == 0 { None } else { Some(1UL) }
    too_many.push(
      @accessibility.NodeSpec::new(
        key,
        parent_key,
        @accessibility.Group,
        "Node",
        accessibility_test_bounds(),
      ),
    )
    index += 1
  }
  match model.publish(too_many) {
    Err(@accessibility.TooManyNodes) => ()
    _ => assert_true(false)
  }

  let too_deep : Array[@accessibility.NodeSpec] = []
  index = 0
  while index <= @accessibility.max_tree_depth {
    let key = index.to_uint64() + 1UL
    let parent_key = if index == 0 { None } else { Some(index.to_uint64()) }
    too_deep.push(
      @accessibility.NodeSpec::new(
        key,
        parent_key,
        @accessibility.Group,
        "Node",
        accessibility_test_bounds(),
      ),
    )
    index += 1
  }
  match model.publish(too_deep) {
    Err(@accessibility.TreeTooDeep) => ()
    _ => assert_true(false)
  }

  let mut too_long = ""
  index = 0
  while index <= @accessibility.max_name_units {
    too_long = too_long + "x"
    index += 1
  }
  match
    model.publish([
      @accessibility.NodeSpec::new(
        1UL,
        None,
        @accessibility.Window,
        too_long,
        accessibility_test_bounds(),
      ),
    ]) {
    Err(@accessibility.NameTooLong) => ()
    _ => assert_true(false)
  }

  let mut bounded_name = ""
  index = 0
  while index < @accessibility.max_name_units {
    bounded_name = bounded_name + "x"
    index += 1
  }
  let many_names : Array[@accessibility.NodeSpec] = []
  index = 0
  while index < 257 {
    let key = index.to_uint64() + 1UL
    let parent_key = if index == 0 { None } else { Some(1UL) }
    many_names.push(
      @accessibility.NodeSpec::new(
        key,
        parent_key,
        @accessibility.Group,
        bounded_name,
        accessibility_test_bounds(),
      ),
    )
    index += 1
  }
  match model.publish(many_names) {
    Err(@accessibility.SnapshotTextTooLong) => ()
    _ => assert_true(false)
  }
}
