///|
fn input_dispatch_test_tree() -> @element.ElementTree {
  let all = element_rect(0.0, 0.0, 100.0, 100.0)
  let left = element_rect(0.0, 0.0, 40.0, 100.0)
  let left_leaf = element_rect(20.0, 0.0, 20.0, 100.0)
  let right = element_rect(40.0, 0.0, 60.0, 100.0)
  unwrap_tree([
    @element.ElementNode::new(1, None, all).with_focusable(true),
    @element.ElementNode::new(2, Some(1), left),
    @element.ElementNode::new(3, Some(2), left_leaf).with_focusable(true),
    @element.ElementNode::new(4, Some(1), right),
    @element.ElementNode::new(5, Some(4), right).with_focusable(true),
  ])
}

///|
fn input_dispatch_test_modifiers() -> @primitives.Modifiers {
  @primitives.Modifiers::new(shift=true, control=true, alt=true, meta=true)
}

///|
test "all input variants preserve payload and choose pointer or focused target" {
  let tree = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("focusable child rejected")
    Ok(value) => value
  }
  let pointer_position = element_point(10.0, 10.0)
  let modifiers = input_dispatch_test_modifiers()
  let events : Array[@primitives.InputEvent] = [
    @primitives.PointerMoved(position=pointer_position),
    @primitives.PointerButtonPressed(
      position=pointer_position,
      button=@primitives.Secondary,
      modifiers~,
    ),
    @primitives.PointerButtonReleased(
      position=pointer_position,
      button=@primitives.Back,
      modifiers~,
    ),
    @primitives.Scroll(
      position=pointer_position,
      delta=element_point(-3.5, 7.25),
      modifiers~,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("Q"),
      modifiers~,
      repeat=true,
    ),
    @primitives.KeyReleased(key=@primitives.ArrowLeft, modifiers~),
    @primitives.TextInput(text="paste: λ雪"),
  ]
  let targets : Array[UInt64] = [2, 2, 2, 2, 3, 3, 3]
  let mut index = 0
  while index < events.length() {
    let event = events[index]
    let target = targets[index]
    let plan = tree.dispatch_input(event)
    assert_true(plan.target() == Some(target))
    if index < 4 {
      // The legacy pointer API remains the source of pointer routing.
      assert_true(
        plan.target() == tree.dispatch_pointer(pointer_position).target(),
      )
    }
    let received : Array[@primitives.InputEvent] = []
    let callback_valid = Ref(true)
    match
      tree.dispatch_input_with(event, (context, delivered) => {
        if context.target() != target {
          callback_valid.val = false
        }
        received.push(delivered)
        Ok(())
      }) {
      Err(_) => fail("valid input dispatch failed")
      Ok(outcome) => {
        assert_true(outcome.target() == Some(target))
        assert_eq(received.length(), if target == 2 { 4 } else { 6 })
        assert_true(callback_valid.val)
        for delivered in received {
          assert_true(delivered == event)
        }
      }
    }
    index += 1
  }
}

///|
test "focused dispatch follows nested focus and ignores pointer sibling" {
  let tree = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("focusable child rejected")
    Ok(value) => value
  }
  let event = @primitives.KeyPressed(
    key=@primitives.Character("k"),
    modifiers=@primitives.Modifiers::new(
      shift=true,
      control=false,
      alt=true,
      meta=false,
    ),
    repeat=true,
  )
  let plan = tree.dispatch_input(event)
  assert_true(plan.target() == Some(3))
  assert_eq(plan.capture(), [1, 2, 3])
  assert_eq(plan.bubble(), [3, 2, 1])
  let ids : Array[UInt64] = []
  let phases : Array[@element.EventPhase] = []
  let exact_event = Ref(true)
  match
    tree.dispatch_input_with(event, (context, delivered) => {
      if delivered != event {
        exact_event.val = false
      }
      ids.push(context.current_target())
      phases.push(context.phase())
      Ok(())
    }) {
    Err(_) => fail("focused input dispatch failed")
    Ok(outcome) => {
      assert_true(outcome.target() == Some(3))
      assert_eq(outcome.capture_visited(), [1, 2, 3])
      assert_eq(outcome.bubble_visited(), [3, 2, 1])
    }
  }
  assert_true(exact_event.val)
  assert_eq(ids, [1, 2, 3, 3, 2, 1])
  assert_true(phases[0] == @element.EventPhase::Capture)
  assert_true(phases[2] == @element.EventPhase::Capture)
  assert_true(phases[3] == @element.EventPhase::Bubble)
  assert_true(phases[5] == @element.EventPhase::Bubble)

  // The input has no pointer position, and the pointer location would hit the
  // unrelated right-hand focusable sibling if hit testing chose the target.
  let sibling_position = element_point(50.0, 50.0)
  assert_true(tree.hit_test(sibling_position) == Some(5))
  assert_true(tree.dispatch_input(event).target() == Some(3))
}

///|
test "focused root and no-focus input routing are well-defined" {
  let tree = input_dispatch_test_tree()
  let keyboard_events : Array[@primitives.InputEvent] = [
    @primitives.KeyPressed(
      key=@primitives.Enter,
      modifiers=@primitives.Modifiers::none(),
      repeat=false,
    ),
    @primitives.KeyReleased(
      key=@primitives.Escape,
      modifiers=@primitives.Modifiers::none(),
    ),
    @primitives.TextInput(text="committed text"),
  ]
  for event in keyboard_events {
    let plan = tree.dispatch_input(event)
    assert_true(plan.target() is None)
    assert_eq(plan.capture(), [])
    assert_eq(plan.bubble(), [])
    let callback_count = Ref(0)
    match
      tree.dispatch_input_with(event, (_, _) => {
        callback_count.val += 1
        Ok(())
      }) {
      Err(_) => fail("empty dispatch failed")
      Ok(outcome) => {
        assert_true(outcome.target() is None)
        assert_eq(outcome.capture_visited(), [])
        assert_eq(outcome.bubble_visited(), [])
        assert_true(!outcome.was_stopped())
      }
    }
    assert_eq(callback_count.val, 0)
  }

  let root_focused = match tree.with_focus(1) {
    Err(_) => fail("focusable root rejected")
    Ok(value) => value
  }
  let root_plan = root_focused.dispatch_input(
    @primitives.TextInput(text="root target"),
  )
  assert_true(root_plan.target() == Some(1))
  assert_eq(root_plan.capture(), [1])
  assert_eq(root_plan.bubble(), [1])
}

///|
test "cleared or removed focus leaves key and text dispatch empty" {
  let focused = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("focusable child rejected")
    Ok(value) => value
  }
  let cleared = focused.clear_focus()
  let removed = match focused.without_subtree(2) {
    Err(_) => fail("live focused branch rejected")
    Ok(value) => value
  }
  assert_true(cleared.focused() is None)
  assert_true(removed.focused() is None)
  assert_true(removed.node(3) is None)

  let events : Array[@primitives.InputEvent] = [
    @primitives.KeyPressed(
      key=@primitives.Enter,
      modifiers=@primitives.Modifiers::none(),
      repeat=false,
    ),
    @primitives.TextInput(text="after focus removal"),
  ]
  let mut index = 0
  while index < events.length() {
    let event = events[index]
    for tree in [cleared, removed] {
      let callbacks = Ref(0)
      let plan = tree.dispatch_input(event)
      assert_true(plan.target() is None)
      assert_eq(plan.capture(), [])
      assert_eq(plan.bubble(), [])
      match
        tree.dispatch_input_with(event, (_, _) => {
          callbacks.val += 1
          Ok(())
        }) {
        Err(_) => fail("empty post-focus dispatch failed")
        Ok(outcome) => {
          assert_true(outcome.target() is None)
          assert_eq(outcome.capture_visited(), [])
          assert_eq(outcome.bubble_visited(), [])
          assert_true(!outcome.was_stopped())
        }
      }
      assert_eq(callbacks.val, 0)
    }
    index += 1
  }
}

///|
test "removing an unrelated subtree preserves focused input route" {
  let focused = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("focusable child rejected")
    Ok(value) => value
  }
  let remaining = match focused.without_subtree(4) {
    Err(_) => fail("unrelated branch rejected")
    Ok(value) => value
  }
  assert_true(remaining.focused() == Some(3))
  assert_true(remaining.node(4) is None)
  assert_true(remaining.node(5) is None)
  let events : Array[@primitives.InputEvent] = [
    @primitives.KeyReleased(
      key=@primitives.ArrowDown,
      modifiers=@primitives.Modifiers::none(),
    ),
    @primitives.TextInput(text="focus survives sibling removal"),
  ]
  for event in events {
    let plan = remaining.dispatch_input(event)
    assert_true(plan.target() == Some(3))
    assert_eq(plan.capture(), [1, 2, 3])
    assert_eq(plan.bubble(), [3, 2, 1])
    let visited : Array[UInt64] = []
    match
      remaining.dispatch_input_with(event, (context, delivered) => {
        if delivered != event || context.target() != 3 {
          context.stop_propagation()
        }
        visited.push(context.current_target())
        Ok(())
      }) {
      Err(_) => fail("focused input dispatch after sibling removal failed")
      Ok(outcome) => {
        assert_true(outcome.target() == Some(3))
        assert_true(!outcome.was_stopped())
        assert_eq(outcome.capture_visited(), [1, 2, 3])
        assert_eq(outcome.bubble_visited(), [3, 2, 1])
      }
    }
    assert_eq(visited, [1, 2, 3, 3, 2, 1])
  }
}

///|
test "input stop propagation applies globally from either phase" {
  let tree = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("focusable child rejected")
    Ok(value) => value
  }
  let event = @primitives.TextInput(text="stop")
  match
    tree.dispatch_input_with(event, (context, _) => {
      if context.phase() == @element.EventPhase::Capture &&
        context.current_target() == 2 {
        context.stop_propagation()
      }
      Ok(())
    }) {
    Err(_) => fail("capture-stop dispatch failed")
    Ok(outcome) => {
      assert_true(outcome.was_stopped())
      assert_eq(outcome.capture_visited(), [1, 2])
      assert_eq(outcome.bubble_visited(), [])
    }
  }

  match
    tree.dispatch_input_with(event, (context, _) => {
      if context.phase() == @element.EventPhase::Bubble &&
        context.current_target() == 3 {
        context.stop_propagation()
      }
      Ok(())
    }) {
    Err(_) => fail("bubble-stop dispatch failed")
    Ok(outcome) => {
      assert_true(outcome.was_stopped())
      assert_eq(outcome.capture_visited(), [1, 2, 3])
      assert_eq(outcome.bubble_visited(), [3])
    }
  }
}

///|
test "input callback errors abort in capture and bubble" {
  let tree = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("focusable child rejected")
    Ok(value) => value
  }
  let event = @primitives.KeyReleased(
    key=@primitives.Backspace,
    modifiers=@primitives.Modifiers::none(),
  )
  let capture_error = match tree.with_focus(2) {
    Err(error) => error
    Ok(_) => abort("non-focusable node unexpectedly accepted focus")
  }
  let bubble_error = match tree.without_subtree(99) {
    Err(error) => error
    Ok(_) => abort("unknown subtree unexpectedly removed")
  }
  let capture_visited : Array[UInt64] = []
  let capture_result = tree.dispatch_input_with(event, (context, _) => {
    capture_visited.push(context.current_target())
    if context.phase() == @element.EventPhase::Capture &&
      context.current_target() == 2 {
      Err(capture_error)
    } else {
      Ok(())
    }
  })
  assert_true(
    match capture_result {
      Err(error) => error == capture_error
      Ok(_) => false
    },
  )
  assert_eq(capture_visited, [1, 2])

  let bubble_visited : Array[(UInt64, @element.EventPhase)] = []
  let bubble_result = tree.dispatch_input_with(event, (context, _) => {
    bubble_visited.push((context.current_target(), context.phase()))
    if context.phase() == @element.EventPhase::Bubble &&
      context.current_target() == 2 {
      Err(bubble_error)
    } else {
      Ok(())
    }
  })
  assert_true(
    match bubble_result {
      Err(error) => error == bubble_error
      Ok(_) => false
    },
  )
  assert_true(
    bubble_visited ==
    [
      (1, @element.EventPhase::Capture),
      (2, @element.EventPhase::Capture),
      (3, @element.EventPhase::Capture),
      (3, @element.EventPhase::Bubble),
      (2, @element.EventPhase::Bubble),
    ],
  )
}

///|
test "a retained context cannot stop a later input dispatch" {
  let tree = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("focusable child rejected")
    Ok(value) => value
  }
  let saved : Ref[@element.DispatchContext?] = Ref(None)
  let event = @primitives.TextInput(text="first")
  match
    tree.dispatch_input_with(event, (context, _) => {
      if saved.val is None {
        saved.val = Some(context)
      }
      Ok(())
    }) {
    Err(_) => fail("initial dispatch failed")
    Ok(_) => ()
  }
  match saved.val {
    None => fail("dispatch context was not retained")
    Some(context) => context.stop_propagation()
  }
  let visited : Array[UInt64] = []
  let callback_valid = Ref(true)
  match
    tree.dispatch_input_with(
      @primitives.KeyPressed(
        key=@primitives.Tab,
        modifiers=@primitives.Modifiers::none(),
        repeat=false,
      ),
      (context, _) => {
        if context.is_propagation_stopped() {
          callback_valid.val = false
        }
        visited.push(context.current_target())
        Ok(())
      },
    ) {
    Err(_) => fail("fresh dispatch was stopped by stale context")
    Ok(outcome) => {
      assert_true(!outcome.was_stopped())
      assert_eq(outcome.capture_visited(), [1, 2, 3])
      assert_eq(outcome.bubble_visited(), [3, 2, 1])
    }
  }
  assert_true(callback_valid.val)
  assert_eq(visited.length(), 6)
}

///|
test "callback tree selection cannot retarget the started input event" {
  let first = match input_dispatch_test_tree().with_focus(3) {
    Err(_) => fail("first focus target rejected")
    Ok(value) => value
  }
  let second = match input_dispatch_test_tree().with_focus(5) {
    Err(_) => fail("second focus target rejected")
    Ok(value) => value
  }
  let selected = Ref(first)
  let visited : Array[UInt64] = []
  match
    first.dispatch_input_with(
      @primitives.KeyPressed(
        key=@primitives.ArrowRight,
        modifiers=@primitives.Modifiers::none(),
        repeat=false,
      ),
      (context, _) => {
        selected.val = second
        visited.push(context.current_target())
        Ok(())
      },
    ) {
    Err(_) => fail("initial immutable tree dispatch failed")
    Ok(outcome) => assert_true(outcome.target() == Some(3))
  }
  assert_eq(visited, [1, 2, 3, 3, 2, 1])
  assert_true(
    selected.val.dispatch_input(@primitives.TextInput(text="next")).target() ==
    Some(5),
  )
}

///|
// Stable suite ID: element.input.fixed-route-reference
test "property focused input routes match fixed-tree references" {
  @quickcheck.check(
    (selector : Int) => {
      let tree = input_dispatch_test_tree()
      let target : UInt64 = if selector % 2 == 0 { 3 } else { 5 }
      match tree.with_focus(target) {
        Err(_) => false
        Ok(focused) => {
          let expected_capture : Array[UInt64] = if target == 3 {
            [1, 2, 3]
          } else {
            [1, 4, 5]
          }
          let expected_bubble : Array[UInt64] = if target == 3 {
            [3, 2, 1]
          } else {
            [5, 4, 1]
          }
          let event = @primitives.KeyPressed(
            key=@primitives.Character("x"),
            modifiers=input_dispatch_test_modifiers(),
            repeat=selector % 3 == 0,
          )
          let plan = focused.dispatch_input(event)
          if plan.target() != Some(target) ||
            plan.capture() != expected_capture ||
            plan.bubble() != expected_bubble {
            false
          } else {
            let seen : Array[UInt64] = []
            match
              focused.dispatch_input_with(event, (context, delivered) => {
                if delivered != event || context.target() != target {
                  context.stop_propagation()
                }
                seen.push(context.current_target())
                Ok(())
              }) {
              Err(_) => false
              Ok(outcome) => {
                let expected_seen : Array[UInt64] = []
                for id in expected_capture {
                  expected_seen.push(id)
                }
                for id in expected_bubble {
                  expected_seen.push(id)
                }
                outcome.target() == Some(target) &&
                !outcome.was_stopped() &&
                seen == expected_seen
              }
            }
          }
        }
      }
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=16436612377569977809,
  )
}
