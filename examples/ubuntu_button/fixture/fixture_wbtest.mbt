///|
fn ubuntu_button_test_input_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("fixture point rejected")
  }
}

///|
fn ubuntu_button_test_pointer(
  pressed : Bool,
  x : Double,
  y : Double,
  primary : Bool,
) -> @primitives.InputEvent {
  let position = ubuntu_button_test_input_point(x, y)
  if pressed {
    @primitives.PointerButtonPressed(
      position~,
      button=if primary { @primitives.Primary } else { @primitives.Secondary },
      modifiers=@primitives.Modifiers::none(),
    )
  } else {
    @primitives.PointerButtonReleased(
      position~,
      button=if primary { @primitives.Primary } else { @primitives.Secondary },
      modifiers=@primitives.Modifiers::none(),
    )
  }
}

///|
fn ubuntu_button_test_key_down(
  key : @primitives.Key,
  repeat : Bool,
) -> @primitives.InputEvent {
  @primitives.KeyPressed(key~, modifiers=@primitives.Modifiers::none(), repeat~)
}

///|
fn ubuntu_button_test_key_up(key : @primitives.Key) -> @primitives.InputEvent {
  @primitives.KeyReleased(key~, modifiers=@primitives.Modifiers::none())
}

///|
test "fixture routes pointer through focus tree and resets app-owned count" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let stable_id = demo.button().id()
  let bounds = demo.button().bounds()
  let point = ubuntu_button_test_input_point(
    bounds.left() + 8.0,
    bounds.top() + 8.0,
  )
  assert_true(
    demo
    .tree()
    .dispatch_input(
      ubuntu_button_test_pointer(true, point.x(), point.y(), true),
    )
    .target() ==
    Some(stable_id),
  )
  let pressed = demo.handle_input(
    ubuntu_button_test_pointer(true, point.x(), point.y(), true),
  )
  assert_true(pressed.button().is_focused())
  assert_eq(pressed.activations(), 0)
  let activated = pressed.handle_input(
    ubuntu_button_test_pointer(false, point.x(), point.y(), true),
  )
  assert_eq(activated.activations(), 1)

  let reset = activated.reset_session().unwrap()
  assert_eq(reset.button().id(), stable_id)
  assert_eq(reset.activations(), 0)
  assert_true(!reset.button().is_pressed())
  let stale_release = reset.handle_input(
    ubuntu_button_test_pointer(false, point.x(), point.y(), true),
  )
  assert_eq(stale_release.activations(), 0)
}

///|
test "fixture rejects outside origin, outside release, and secondary pointer" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let bounds = demo.button().bounds()
  let inside = ubuntu_button_test_input_point(
    bounds.left() + 8.0,
    bounds.top() + 8.0,
  )
  let outside = ubuntu_button_test_input_point(500.0, 200.0)

  let outside_press = demo.handle_input(
    ubuntu_button_test_pointer(true, outside.x(), outside.y(), true),
  )
  let inside_release = outside_press.handle_input(
    ubuntu_button_test_pointer(false, inside.x(), inside.y(), true),
  )
  assert_eq(inside_release.activations(), 0)

  let pressed = inside_release.handle_input(
    ubuntu_button_test_pointer(true, inside.x(), inside.y(), true),
  )
  assert_true(pressed.button().is_pressed())
  let outside_release = pressed.handle_input(
    ubuntu_button_test_pointer(false, outside.x(), outside.y(), true),
  )
  assert_true(!outside_release.button().is_pressed())
  let later_inside = outside_release.handle_input(
    ubuntu_button_test_pointer(false, inside.x(), inside.y(), true),
  )
  assert_eq(later_inside.activations(), 0)
  assert_true(!later_inside.button().is_pressed())

  let secondary = ButtonDemo::new(640.0, 240.0)
    .unwrap()
    .handle_input(
      ubuntu_button_test_pointer(true, inside.x(), inside.y(), false),
    )
    .handle_input(
      ubuntu_button_test_pointer(false, inside.x(), inside.y(), false),
    )
  assert_eq(secondary.activations(), 0)
}

///|
test "fixture applies Enter and Space once through focused dispatch" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap().focus_button().unwrap()
  let enter = demo.handle_input(
    ubuntu_button_test_key_down(@primitives.Enter, false),
  )
  assert_eq(enter.activations(), 1)
  let repeated = enter.handle_input(
    ubuntu_button_test_key_down(@primitives.Enter, true),
  )
  assert_eq(repeated.activations(), 1)
  let after_enter = repeated.handle_input(
    ubuntu_button_test_key_up(@primitives.Enter),
  )
  assert_eq(after_enter.activations(), 1)

  let space_down = after_enter.handle_input(
    ubuntu_button_test_key_down(@primitives.Space, false),
  )
  assert_eq(space_down.activations(), 1)
  let space_repeat = space_down.handle_input(
    ubuntu_button_test_key_down(@primitives.Space, true),
  )
  assert_eq(space_repeat.activations(), 1)
  let space_up = space_repeat.handle_input(
    ubuntu_button_test_key_up(@primitives.Space),
  )
  assert_eq(space_up.activations(), 2)
}

///|
test "disabled focus transition and loading cancel pending activation" {
  let focused = ButtonDemo::new(640.0, 240.0).unwrap().focus_button().unwrap()
  let space = focused.handle_input(
    ubuntu_button_test_key_down(@primitives.Space, false),
  )
  let loading = space.with_loading(true).unwrap()
  assert_true(loading.button().is_focused())
  let stale_up = loading.handle_input(
    ubuntu_button_test_key_up(@primitives.Space),
  )
  assert_eq(stale_up.activations(), 0)

  let pointer_base = ButtonDemo::new(640.0, 240.0)
    .unwrap()
    .focus_button()
    .unwrap()
  let pointer = pointer_base.handle_input(
    ubuntu_button_test_pointer(
      true,
      pointer_base.button().bounds().left() + 8.0,
      pointer_base.button().bounds().top() + 8.0,
      true,
    ),
  )
  let disabled = pointer.with_enabled(false).unwrap()
  assert_true(disabled.tree().focused() is None)
  assert_true(!disabled.button().is_focused())
  let disabled_release = disabled.handle_input(
    ubuntu_button_test_pointer(
      false,
      pointer.button().bounds().left() + 8.0,
      pointer.button().bounds().top() + 8.0,
      true,
    ),
  )
  assert_eq(disabled_release.activations(), 0)
}

///|
test "same-value enabled update keeps focus routing and an armed Space release" {
  let focused = ButtonDemo::new(640.0, 240.0).unwrap().focus_button().unwrap()
  let armed = focused.handle_input(
    ubuntu_button_test_key_down(@primitives.Space, false),
  )
  assert_true(armed.button().is_pressed())

  let unchanged = armed.with_enabled(true).unwrap()
  assert_true(unchanged.button().is_focused())
  assert_true(unchanged.tree().focused() == Some(unchanged.button().id()))
  let released = unchanged.handle_input(
    ubuntu_button_test_key_up(@primitives.Space),
  )
  assert_eq(released.activations(), 1)
  assert_true(!released.button().is_pressed())
}

///|
test "undersized resize hides and disarms the button with a current-size scene" {
  let focused = ButtonDemo::new(640.0, 240.0).unwrap().focus_button().unwrap()
  let armed = focused.handle_input(
    ubuntu_button_test_key_down(@primitives.Space, false),
  )
  let stable_id = armed.button().id()
  let small = armed.resize(80.0, 30.0).unwrap()
  assert_true(!small.is_button_visible())
  assert_true(!small.button().is_focused())
  assert_true(!small.button().is_pressed())
  assert_true(small.tree().focused() is None)
  assert_true(small.tree().node(stable_id) is None)
  let stale_release = small.handle_input(
    ubuntu_button_test_key_up(@primitives.Space),
  )
  assert_eq(stale_release.activations(), 0)

  let snapshot = small.scene(1.0).unwrap()
  assert_true(snapshot.viewport().size().width() == 80.0)
  assert_true(snapshot.viewport().size().height() == 30.0)
  assert_eq(snapshot.items().length(), 1)

  let restored = small.resize(640.0, 240.0).unwrap()
  assert_true(restored.is_button_visible())
  assert_eq(restored.button().id(), stable_id)
  assert_true(restored.tree().focused() is None)
}

///|
test "fixture scene includes label and status as copied snapshot text" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap().focus_button().unwrap()
  let scene = demo.scene(1.0).unwrap()
  let items = scene.items()
  assert_eq(scene.schema_version(), 1)
  assert_true(items[3] is @scene.TextItem(id=102, text="Run action", ..))
  assert_true(
    items[4]
    is @scene.TextItem(
      id=200,
      text="Activations: 0   Enabled: on   Loading: off",
      ..
    ),
  )
  assert_true(items[5] is @scene.TextItem(id=201, ..))
  assert_true(scene.canonical_json().contains("Run action"))
}

///|
fn ubuntu_button_semantic_node(
  demo : ButtonDemo,
) -> @accessibility.SemanticNode {
  demo.accessibility_snapshot().nodes()[1]
}

///|
fn ubuntu_button_semantic_request(
  demo : ButtonDemo,
) -> @accessibility.ActionRequest {
  @accessibility.ActionRequest::new(
    ubuntu_button_semantic_node(demo).id(),
    @accessibility.Invoke,
  )
}

///|
fn ubuntu_button_semantic_action_is_error(
  demo : ButtonDemo,
  request : @accessibility.ActionRequest,
  expected : @accessibility.ActionError,
) -> Bool {
  match demo.validate_accessibility_request(request) {
    Err(error) => error == expected
    Ok(_) => false
  }
}

///|
test "fixture publishes button identity name geometry and state" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let nodes = demo.accessibility_snapshot().nodes()
  let expected_viewport = @primitives.Rect::new(0.0, 0.0, 640.0, 240.0).unwrap()

  assert_eq(nodes.length(), 2)
  assert_true(nodes[0].role() == @accessibility.Window)
  assert_eq(nodes[0].name(), "Ubuntu button demo")
  assert_true(nodes[0].bounds() == expected_viewport)
  assert_true(nodes[0].parent() is None)

  let button = nodes[1]
  let actions = button.supported_actions()
  assert_true(button.role() == @accessibility.Button)
  assert_eq(button.name(), demo.button().label())
  assert_true(button.bounds() == demo.button().bounds())
  assert_eq(button.id().key(), demo.button().id())
  assert_true(button.parent() == Some(nodes[0].id()))
  assert_true(button.is_enabled())
  assert_true(!button.is_loading())
  assert_true(!button.is_focused())
  assert_eq(actions.length(), 1)
  assert_true(actions[0] == @accessibility.Invoke)
}

///|
test "fixture ordinary updates preserve identity and revalidate latest state" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let original_id = ubuntu_button_semantic_node(demo).id()
  let request = @accessibility.ActionRequest::new(
    original_id,
    @accessibility.Invoke,
  )

  let focused = demo.focus_button().unwrap()
  let focused_button = ubuntu_button_semantic_node(focused)
  assert_true(focused_button.id() == original_id)
  assert_true(focused_button.is_focused())

  let loading = focused.with_loading(true).unwrap()
  let loading_button = ubuntu_button_semantic_node(loading)
  assert_true(loading_button.id() == original_id)
  assert_true(loading_button.is_loading())
  assert_true(loading_button.is_focused())
  assert_eq(loading_button.supported_actions().length(), 1)
  assert_true(
    ubuntu_button_semantic_action_is_error(
      loading,
      request,
      @accessibility.Loading,
    ),
  )

  let disabled_base = ButtonDemo::new(640.0, 240.0)
    .unwrap()
    .focus_button()
    .unwrap()
  let disabled_id = ubuntu_button_semantic_node(disabled_base).id()
  let disabled_request = ubuntu_button_semantic_request(disabled_base)
  let disabled = disabled_base.with_enabled(false).unwrap()
  let disabled_button = ubuntu_button_semantic_node(disabled)
  assert_true(disabled_button.id() == disabled_id)
  assert_true(!disabled_button.is_enabled())
  assert_true(!disabled_button.is_focused())
  assert_eq(disabled_button.supported_actions().length(), 1)
  assert_true(
    ubuntu_button_semantic_action_is_error(
      disabled,
      disabled_request,
      @accessibility.Disabled,
    ),
  )
  assert_true(
    disabled.dispatch_accessibility_request(disabled_request) is Err(_),
  )
  assert_eq(disabled.activations(), 0)
}

///|
test "fixture removal and restoration allocate a fresh semantic generation" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let original = ubuntu_button_semantic_node(demo).id()
  let request = @accessibility.ActionRequest::new(
    original,
    @accessibility.Invoke,
  )

  let small = demo.resize(80.0, 30.0).unwrap()
  assert_eq(small.accessibility_snapshot().nodes().length(), 1)
  assert_true(
    ubuntu_button_semantic_action_is_error(
      small,
      request,
      @accessibility.StaleNode,
    ),
  )

  let restored = small.resize(640.0, 240.0).unwrap()
  let replacement = ubuntu_button_semantic_node(restored).id()
  assert_eq(restored.button().id(), demo.button().id())
  assert_eq(replacement.key(), original.key())
  assert_true(replacement != original)
  assert_true(
    ubuntu_button_semantic_action_is_error(
      restored,
      request,
      @accessibility.StaleNode,
    ),
  )
}

///|
test "fixture resets the model before reusing its button key" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let original = ubuntu_button_semantic_node(demo).id()
  let request = @accessibility.ActionRequest::new(
    original,
    @accessibility.Invoke,
  )
  let reset = demo.reset_session().unwrap()
  let replacement = ubuntu_button_semantic_node(reset).id()

  assert_eq(reset.button().id(), demo.button().id())
  assert_eq(replacement.key(), original.key())
  assert_true(replacement != original)
  assert_true(
    ubuntu_button_semantic_action_is_error(
      reset,
      request,
      @accessibility.StaleNode,
    ),
  )
}

///|
test "fixture rejects current requests and updates through stale value copies" {
  let old = ButtonDemo::new(640.0, 240.0).unwrap()
  let fresh = old.reset_session().unwrap()
  let fresh_request = ubuntu_button_semantic_request(fresh)

  assert_true(
    ubuntu_button_semantic_action_is_error(
      old,
      fresh_request,
      @accessibility.StaleNode,
    ),
  )
  assert_true(old.dispatch_accessibility_request(fresh_request) is Err(_))
  assert_eq(old.activations(), 0)
  assert_eq(fresh.activations(), 0)

  let focused = ButtonDemo::new(640.0, 240.0).unwrap().focus_button().unwrap()
  let disabled = focused.with_enabled(false).unwrap()
  let reenabled = disabled.with_enabled(true).unwrap()
  let current_request = ubuntu_button_semantic_request(reenabled)

  assert_true(!disabled.button().is_enabled())
  assert_true(!ubuntu_button_semantic_node(disabled).is_enabled())
  assert_true(reenabled.button().is_enabled())
  assert_true(ubuntu_button_semantic_node(reenabled).is_enabled())
  assert_true(
    ubuntu_button_semantic_action_is_error(
      disabled,
      current_request,
      @accessibility.StaleNode,
    ),
  )
  assert_true(
    disabled.dispatch_accessibility_request(current_request) is Err(_),
  )
  match disabled.with_loading(true) {
    Err(StaleFixtureState) => ()
    _ => assert_true(false)
  }
  match disabled.with_enabled(false) {
    Err(StaleFixtureState) => ()
    _ => assert_true(false)
  }
  assert_true(
    reenabled.validate_accessibility_request(current_request) is Ok(_),
  )
  assert_eq(
    reenabled
    .dispatch_accessibility_request(current_request)
    .unwrap()
    .activations(),
    1,
  )
}

///|
test "fixture close and reopen reject old owner requests" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let old_request = ubuntu_button_semantic_request(demo)
  demo.close()

  assert_true(
    ubuntu_button_semantic_action_is_error(
      demo,
      old_request,
      @accessibility.ModelClosed,
    ),
  )
  let reopened = demo.reopen().unwrap()
  assert_eq(reopened.button().id(), demo.button().id())
  assert_true(
    ubuntu_button_semantic_action_is_error(
      reopened,
      old_request,
      @accessibility.ForeignOwner,
    ),
  )
  assert_eq(reopened.activations(), 0)
}

///|
test "fixture validation is inert and owner delivery uses shared counter" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let request = ubuntu_button_semantic_request(demo)
  let original_button = demo.button()
  let receipt = demo.validate_accessibility_request(request).unwrap()
  assert_true(receipt.action() == @accessibility.Invoke)
  assert_eq(demo.activations(), 0)
  assert_true(!demo.button().is_focused())
  assert_true(!demo.button().is_pressed())

  let delivered = demo.dispatch_accessibility_request(request).unwrap()
  assert_eq(delivered.activations(), 1)
  assert_true(!delivered.button().is_focused())
  assert_true(!delivered.button().is_pressed())
  assert_true(delivered.button().id() == original_button.id())

  // ActionIntent is a repeatable validation receipt. This fixture deliberately
  // does not deduplicate requests; app-specific idempotency belongs to the
  // owner’s action path.
  let repeated = delivered.dispatch_accessibility_request(request).unwrap()
  assert_eq(repeated.activations(), 2)
}

///|
test "fixture transitions fence retained action and physical-input copies" {
  let old = ButtonDemo::new(640.0, 240.0).unwrap()
  let request = ubuntu_button_semantic_request(old)
  let current = old.dispatch_accessibility_request(request).unwrap()
  assert_eq(current.activations(), 1)
  let repeated = current.dispatch_accessibility_request(request).unwrap()
  assert_eq(repeated.activations(), 2)
  assert_true(repeated.validate_accessibility_request(request) is Ok(_))
  old.close()
  assert_true(repeated.validate_accessibility_request(request) is Ok(_))
  match old.with_loading(true) {
    Err(StaleFixtureState) => ()
    _ => assert_true(false)
  }
  assert_true(old.dispatch_accessibility_request(request) is Err(_))

  let focused = ButtonDemo::new(640.0, 240.0).unwrap().focus_button().unwrap()
  let space_armed = focused.handle_input(
    ubuntu_button_test_key_down(@primitives.Space, false),
  )
  let space_done = space_armed.handle_input(
    ubuntu_button_test_key_up(@primitives.Space),
  )
  assert_eq(space_done.activations(), 1)
  assert_true(!space_done.button().is_pressed())
  match focused.with_loading(true) {
    Err(StaleFixtureState) => ()
    _ => assert_true(false)
  }
  match space_armed.with_loading(false) {
    Err(StaleFixtureState) => ()
    _ => assert_true(false)
  }

  let pointer_base = ButtonDemo::new(640.0, 240.0)
    .unwrap()
    .focus_button()
    .unwrap()
  let bounds = pointer_base.button().bounds()
  let inside = ubuntu_button_test_input_point(
    bounds.left() + 8.0,
    bounds.top() + 8.0,
  )
  let pointer_armed = pointer_base.handle_input(
    ubuntu_button_test_pointer(true, inside.x(), inside.y(), true),
  )
  let pointer_done = pointer_armed.handle_input(
    ubuntu_button_test_pointer(false, inside.x(), inside.y(), true),
  )
  assert_eq(pointer_done.activations(), 1)
  assert_true(!pointer_done.button().is_pressed())
  match pointer_base.with_enabled(false) {
    Err(StaleFixtureState) => ()
    _ => assert_true(false)
  }
  match pointer_armed.with_loading(true) {
    Err(StaleFixtureState) => ()
    _ => assert_true(false)
  }
}

///|
test "fixture revision exhaustion fences mutations but preserves close" {
  let demo = ButtonDemo::new(640.0, 240.0).unwrap()
  let request = ubuntu_button_semantic_request(demo)
  let at_max = {
    ..demo,
    fixture_revision: DEMO_MAX_FIXTURE_REVISION,
    fixture_revision_source: Ref(Some(DEMO_MAX_FIXTURE_REVISION)),
  }
  let older = { ..at_max, fixture_revision: DEMO_MAX_FIXTURE_REVISION - 1UL, }

  assert_true(at_max.dispatch_accessibility_request(request) is Err(_))
  assert_true(older.validate_accessibility_request(request) is Err(_))
  older.close()
  assert_true(
    ubuntu_button_semantic_action_is_error(
      at_max,
      request,
      @accessibility.StaleNode,
    ),
  )
  at_max.close()
  assert_true(
    ubuntu_button_semantic_action_is_error(
      at_max,
      request,
      @accessibility.ModelClosed,
    ),
  )
}
