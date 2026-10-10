///|
fn projection_wb_bounds() -> @primitives.Rect {
  @primitives.Rect::new(2.0, 3.0, 180.0, 48.0).unwrap()
}

///|
fn projection_wb_root() -> @accessibility.NodeSpec {
  @accessibility.NodeSpec::new(
    1UL,
    None,
    @accessibility.Window,
    "Ubuntu window",
    projection_wb_bounds(),
  )
}

///|
fn projection_wb_button(
  key : UInt64,
  enabled? : Bool = true,
  loading? : Bool = false,
) -> @accessibility.NodeSpec {
  let spec = @accessibility.NodeSpec::new(
      key,
      Some(1UL),
      @accessibility.Button,
      "Run action",
      projection_wb_bounds(),
    )
    .with_enabled(enabled)
    .with_loading(loading)
  spec.with_actions([@accessibility.Invoke]).unwrap()
}

///|
test "Ubuntu projection copies committed tree and preserves continuous IDs" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let projection = AccessibilityProjection::new().unwrap()
  let first_source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let first = projection.publish(model, first_source).unwrap()
  let first_nodes = first.nodes()
  assert_true(first_nodes.length() == 2)
  let window = first_nodes[0]
  let original_button = first_nodes[1]
  let old_export_id = original_button.id()
  assert_true(window.role() == @accessibility.Window)
  assert_true(window.children() == [old_export_id])
  assert_true(original_button.role() == @accessibility.Button)
  assert_true(original_button.name() == "Run action")
  assert_true(original_button.is_enabled())
  assert_true(original_button.supported_actions() == [@accessibility.Invoke])

  // Mutating copied arrays must not mutate the published projection.
  let detached_children = window.children()
  ignore(detached_children.pop())
  assert_true(first.nodes()[0].children() == [old_export_id])

  let changed_spec = @accessibility.NodeSpec::new(
      2UL,
      Some(1UL),
      @accessibility.Button,
      "Run action now",
      projection_wb_bounds(),
    )
    .with_enabled(false)
    .with_actions([@accessibility.Invoke])
    .unwrap()
  let second_source = model
    .publish([projection_wb_root(), changed_spec])
    .unwrap()
  let second = projection.publish(model, second_source).unwrap()
  let second_button = second.nodes()[1]
  assert_true(second.revision() == second_source.revision())
  assert_true(second_button.id() == old_export_id)
  assert_true(second_button.name() == "Run action now")
  assert_true(!second_button.is_enabled())
  assert_true(original_button.name() == "Run action")
  assert_true(original_button.is_enabled())
  model.close()
  projection.close()
}

///|
test "Ubuntu projection rejects stale revisions and resolves live action state" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let projection = AccessibilityProjection::new().unwrap()
  let first_source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let first = projection.publish(model, first_source).unwrap()
  let first_id = first.nodes()[1].id()
  let first_intent = projection.resolve_action(first_id, @accessibility.Invoke)
  assert_true(first_intent is Ok(_))

  let loading_source = model
    .publish([projection_wb_root(), projection_wb_button(2UL, loading=true)])
    .unwrap()
  assert_true(
    projection.resolve_action(first_id, @accessibility.Invoke)
    is Err(StaleSnapshot),
  )
  assert_true(projection.snapshot() is Err(StaleSnapshot))
  let loading = projection.publish(model, loading_source).unwrap()
  let loading_id = loading.nodes()[1].id()
  assert_true(loading_id == first_id)
  assert_true(
    projection.resolve_action(loading_id, @accessibility.Invoke)
    is Err(ActionRejected(@accessibility.Loading)),
  )

  let disabled_source = model
    .publish([projection_wb_root(), projection_wb_button(2UL, enabled=false)])
    .unwrap()
  let disabled = projection.publish(model, disabled_source).unwrap()
  assert_true(
    projection.resolve_action(disabled.nodes()[1].id(), @accessibility.Invoke)
    is Err(ActionRejected(@accessibility.Disabled)),
  )

  let removed_source = model.publish([projection_wb_root()]).unwrap()
  let removed = projection.publish(model, removed_source).unwrap()
  assert_true(removed.nodes().length() == 1)
  assert_true(
    projection.resolve_action(first_id, @accessibility.Invoke)
    is Err(ActionRejected(@accessibility.StaleNode)),
  )

  let readmitted_source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let readmitted = projection.publish(model, readmitted_source).unwrap()
  let readmitted_id = readmitted.nodes()[1].id()
  assert_true(readmitted_id != first_id)
  assert_true(
    projection.resolve_action(first_id, @accessibility.Invoke)
    is Err(ActionRejected(@accessibility.StaleNode)),
  )
  assert_true(
    projection.resolve_action(readmitted_id, @accessibility.Invoke) is Ok(_),
  )

  let empty_source = model.reset().unwrap()
  let empty = projection.publish(model, empty_source).unwrap()
  assert_true(empty.nodes().length() == 0)
  assert_true(
    projection.resolve_action(readmitted_id, @accessibility.Invoke)
    is Err(ActionRejected(@accessibility.StaleNode)),
  )
  let after_reset_source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let after_reset = projection.publish(model, after_reset_source).unwrap()
  assert_true(after_reset.nodes()[1].id() != readmitted_id)
  model.close()
  projection.close()
}

///|
test "Ubuntu projection scopes IDs per registry and source owner" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let first_projection = AccessibilityProjection::new().unwrap()
  let second_projection = AccessibilityProjection::new().unwrap()
  let first = first_projection.publish(model, source).unwrap()
  let second = second_projection.publish(model, source).unwrap()
  let first_id = first.nodes()[1].id()
  let second_id = second.nodes()[1].id()
  assert_true(first_id != second_id)
  assert_true(
    first_projection.resolve_action(second_id, @accessibility.Invoke)
    is Err(ActionRejected(@accessibility.StaleNode)),
  )

  let foreign_model = @accessibility.AccessibilityModel::new().unwrap()
  let foreign_source = foreign_model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  assert_true(
    first_projection.publish(foreign_model, foreign_source) is Err(ForeignOwner),
  )
  assert_true(
    first_projection.resolve_action(first_id, @accessibility.Invoke) is Ok(_),
  )
  model.close()
  foreign_model.close()
  first_projection.close()
  second_projection.close()
}

///|
test "Ubuntu projection revokes exports when the source model closes" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let projection = AccessibilityProjection::new().unwrap()
  let source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let exported = projection.publish(model, source).unwrap()
  let id = exported.nodes()[1].id()
  model.close()
  assert_true(projection.snapshot() is Err(ProjectionClosed))
  assert_true(
    projection.resolve_action(id, @accessibility.Invoke)
    is Err(ProjectionClosed),
  )
  assert_true(projection.state.val.closed)
  assert_true(projection.state.val.entries.length() == 0)
}

///|
test "Ubuntu projection detects closure of an empty source tree" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let projection = AccessibilityProjection::new().unwrap()
  let empty = model.snapshot()
  let foreign_empty_model = @accessibility.AccessibilityModel::new().unwrap()
  assert_true(
    projection.publish(model, foreign_empty_model.snapshot())
    is Err(StaleSnapshot),
  )
  ignore(projection.publish(model, empty).unwrap())
  assert_true(
    projection.publish(foreign_empty_model, foreign_empty_model.snapshot())
    is Err(ForeignOwner),
  )
  assert_true(projection.snapshot() is Ok(_))
  foreign_empty_model.close()
  model.close()
  assert_true(projection.snapshot() is Err(ProjectionClosed))
  assert_true(projection.state.val.closed)

  let already_closed = @accessibility.AccessibilityModel::new().unwrap()
  let closed_snapshot = already_closed.snapshot()
  already_closed.close()
  let fresh_projection = AccessibilityProjection::new().unwrap()
  assert_true(
    fresh_projection.publish(already_closed, closed_snapshot)
    is Err(SourceClosed),
  )
  assert_true(fresh_projection.snapshot() is Ok(_))
  fresh_projection.close()
}

///|
test "Ubuntu projection close revokes copied export handles" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let projection = AccessibilityProjection::new().unwrap()
  let source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let exported = projection.publish(model, source).unwrap()
  let id = exported.nodes()[1].id()
  projection.close()
  assert_true(projection.snapshot() is Err(ProjectionClosed))
  assert_true(
    projection.resolve_action(id, @accessibility.Invoke)
    is Err(ProjectionClosed),
  )
  assert_true(exported.nodes().length() == 2)
  model.close()
}

///|
test "Ubuntu projection identity exhaustion fails publication atomically" {
  let model = @accessibility.AccessibilityModel::new().unwrap()
  let projection = AccessibilityProjection::new().unwrap()
  let initial_source = model.publish([projection_wb_root()]).unwrap()
  let initial = projection.publish(model, initial_source).unwrap()
  let old_root_id = initial.nodes()[0].id()
  let state = projection.state.val
  projection.state.val = {
    ..state,
    next_sequence: PROJECTION_MAX_UINT64,
    sequence_exhausted: false,
  }

  let multi_source = model
    .publish([
      projection_wb_root(),
      projection_wb_button(2UL),
      projection_wb_button(3UL),
    ])
    .unwrap()
  assert_true(
    projection.publish(model, multi_source) is Err(ExportIdentityExhausted),
  )
  let after_failure = projection.state.val
  assert_true(after_failure.source_revision == initial.revision())
  assert_true(after_failure.next_sequence == PROJECTION_MAX_UINT64)
  assert_true(!after_failure.sequence_exhausted)
  assert_true(after_failure.entries.length() == 1)
  assert_true(after_failure.entries[0].export_id == old_root_id)
  assert_true(
    projection.resolve_action(old_root_id, @accessibility.Invoke)
    is Err(StaleSnapshot),
  )

  let final_source = model
    .publish([projection_wb_root(), projection_wb_button(2UL)])
    .unwrap()
  let terminal = projection.publish(model, final_source).unwrap()
  assert_true(terminal.nodes()[0].id() == old_root_id)
  assert_true(terminal.nodes()[1].id().sequence == PROJECTION_MAX_UINT64)
  assert_true(projection.state.val.sequence_exhausted)
  let next_source = model
    .publish([
      projection_wb_root(),
      projection_wb_button(2UL),
      projection_wb_button(3UL),
    ])
    .unwrap()
  assert_true(
    projection.publish(model, next_source) is Err(ExportIdentityExhausted),
  )
  model.close()
  projection.close()
}
