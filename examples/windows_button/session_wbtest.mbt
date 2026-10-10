///|
fn windows_button_test_event(
  sequence : Int64,
  kind : @platform.EventKind,
) -> @platform.Event {
  @platform.Event::new(@platform.WindowId::new(1), sequence, 1.0, kind)
}

///|
fn windows_button_test_event_at_scale(
  sequence : Int64,
  scale : Double,
  kind : @platform.EventKind,
) -> @platform.Event {
  @platform.Event::new(@platform.WindowId::new(1), sequence, scale, kind)
}

///|
fn windows_button_test_key_down(
  sequence : Int64,
  key : @primitives.Key,
  repeat : Bool,
) -> @platform.Event {
  windows_button_test_event(
    sequence,
    @platform.Input(
      @primitives.KeyPressed(
        key~,
        modifiers=@primitives.Modifiers::none(),
        repeat~,
      ),
    ),
  )
}

///|
fn windows_button_test_key_up(
  sequence : Int64,
  key : @primitives.Key,
) -> @platform.Event {
  windows_button_test_event(
    sequence,
    @platform.Input(
      @primitives.KeyReleased(key~, modifiers=@primitives.Modifiers::none()),
    ),
  )
}

///|
fn windows_button_test_text(sequence : Int64, text : String) -> @platform.Event {
  windows_button_test_event(
    sequence,
    @platform.Input(@primitives.TextInput(text~)),
  )
}

///|
test "Windows adapter routes Tab Enter and Space through the shared Button once" {
  let mut session = WindowsButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, repaint) = session
    .handle_event(windows_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  assert_true(repaint)
  assert_true(session.demo().button().is_focused())

  let (enter, _) = session
    .handle_event(windows_button_test_key_down(2, @primitives.Enter, false))
    .unwrap()
  session = enter
  assert_eq(session.demo().activations(), 1)
  let (enter_repeat, _) = session
    .handle_event(windows_button_test_key_down(3, @primitives.Enter, true))
    .unwrap()
  session = enter_repeat
  assert_eq(session.repeat_keydowns, 1)
  let (enter_up, _) = session
    .handle_event(windows_button_test_key_up(4, @primitives.Enter))
    .unwrap()
  session = enter_up
  assert_eq(session.demo().activations(), 1)

  let (space_down, _) = session
    .handle_event(windows_button_test_key_down(5, @primitives.Space, false))
    .unwrap()
  session = space_down
  assert_true(session.demo().button().is_pressed())
  let (space_repeat, _) = session
    .handle_event(windows_button_test_key_down(6, @primitives.Space, true))
    .unwrap()
  session = space_repeat
  assert_eq(session.repeat_keydowns, 2)
  let (space_up, _) = session
    .handle_event(windows_button_test_key_up(7, @primitives.Space))
    .unwrap()
  session = space_up
  assert_eq(session.demo().activations(), 2)
  assert_true(!session.demo().button().is_pressed())

  let (duplicate_up, _) = session
    .handle_event(windows_button_test_key_up(8, @primitives.Space))
    .unwrap()
  session = duplicate_up
  assert_eq(session.unmatched_key_releases, 1)
  let (unmatched_repeat, _) = session
    .handle_event(windows_button_test_key_down(9, @primitives.Enter, true))
    .unwrap()
  session = unmatched_repeat
  assert_eq(session.demo().activations(), 2)
}

///|
test "Windows committed character shortcuts toggle state and reset the shared owner" {
  let mut session = WindowsButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(windows_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let initial_id = session.demo().accessibility_snapshot().nodes()[1].id()

  let (loading, _) = session
    .handle_event(windows_button_test_text(2, "l"))
    .unwrap()
  session = loading
  assert_true(session.demo().button().is_loading())
  assert_true(session.demo().button().is_focused())
  let loading_node = session.demo().accessibility_snapshot().nodes()[1]
  assert_true(loading_node.id() == initial_id)
  assert_true(loading_node.is_loading())
  assert_true(
    session
    .demo()
    .validate_accessibility_request(
      @accessibility.ActionRequest::new(initial_id, @accessibility.Invoke),
    )
    is Err(@accessibility.Loading),
  )
  assert_eq(session.demo().activations(), 0)

  let (enabled_off, _) = session
    .handle_event(windows_button_test_text(3, "d"))
    .unwrap()
  session = enabled_off
  let disabled_node = session.demo().accessibility_snapshot().nodes()[1]
  assert_true(!session.demo().button().is_enabled())
  assert_true(!disabled_node.is_enabled())
  assert_true(!disabled_node.is_focused())
  assert_true(
    session
    .demo()
    .validate_accessibility_request(
      @accessibility.ActionRequest::new(initial_id, @accessibility.Invoke),
    )
    is Err(@accessibility.Disabled),
  )

  let (enabled_on, _) = session
    .handle_event(windows_button_test_text(4, "D"))
    .unwrap()
  session = enabled_on
  assert_true(session.demo().button().is_enabled())
  let (reset, _) = session
    .handle_event(windows_button_test_text(5, "r"))
    .unwrap()
  session = reset
  let reset_node = session.demo().accessibility_snapshot().nodes()[1]
  assert_true(!session.demo().button().is_focused())
  assert_true(!session.demo().button().is_loading())
  assert_true(reset_node.id() != initial_id)
  assert_true(
    session
    .demo()
    .validate_accessibility_request(
      @accessibility.ActionRequest::new(initial_id, @accessibility.Invoke),
    )
    is Err(@accessibility.StaleNode),
  )
}

///|
test "Windows adapter cancels armed input on blur and unmatched release stays inert" {
  let mut session = WindowsButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(windows_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (pressed, _) = session
    .handle_event(windows_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = pressed
  assert_true(session.demo().button().is_pressed())

  let (blurred, repaint) = session
    .handle_event(windows_button_test_event(3, @platform.FocusChanged(false)))
    .unwrap()
  session = blurred
  assert_true(repaint)
  assert_true(!session.demo().button().is_pressed())
  let (stale_release, _) = session
    .handle_event(windows_button_test_key_up(4, @primitives.Space))
    .unwrap()
  session = stale_release
  assert_eq(session.demo().activations(), 0)

  let bounds = session.demo().button().bounds()
  let position = @primitives.Point::new(
    bounds.left() + bounds.size().width() / 2.0,
    bounds.top() + bounds.size().height() / 2.0,
  ).unwrap()
  let (unmatched_pointer_release, _) = session
    .handle_event(
      windows_button_test_event(
        5,
        @platform.Input(
          @primitives.PointerButtonReleased(
            position~,
            button=@primitives.Primary,
            modifiers=@primitives.Modifiers::none(),
          ),
        ),
      ),
    )
    .unwrap()
  session = unmatched_pointer_release
  assert_eq(session.unmatched_pointer_releases, 1)
  let (pointer_down, _) = session
    .handle_event(
      windows_button_test_event(
        6,
        @platform.Input(
          @primitives.PointerButtonPressed(
            position~,
            button=@primitives.Primary,
            modifiers=@primitives.Modifiers::none(),
          ),
        ),
      ),
    )
    .unwrap()
  session = pointer_down
  assert_true(session.demo().button().is_pressed())
  let (closing, _) = session
    .handle_event(windows_button_test_event(7, @platform.CloseRequested))
    .unwrap()
  session = closing
  assert_true(!session.is_presentable())
  assert_true(!session.demo().button().is_pressed())
  let (release_after_close, _) = session
    .handle_event(
      windows_button_test_event(
        8,
        @platform.Input(
          @primitives.PointerButtonReleased(
            position~,
            button=@primitives.Primary,
            modifiers=@primitives.Modifiers::none(),
          ),
        ),
      ),
    )
    .unwrap()
  session = release_after_close
  assert_eq(session.demo().activations(), 0)
}

///|
test "Windows adapter suspends zero dimensions and restores current size without replay" {
  let mut session = WindowsButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(windows_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (pressed, _) = session
    .handle_event(windows_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = pressed

  let (suspended, repaint) = session
    .handle_event(
      windows_button_test_event(3, @platform.Resized(width=0.0, height=0.0)),
    )
    .unwrap()
  session = suspended
  assert_true(!repaint)
  assert_true(!session.is_presentable())
  assert_true(!session.demo().button().is_pressed())
  assert_true(session.scene() is Err(Suspended))

  let (ignored_release, _) = session
    .handle_event(windows_button_test_key_up(4, @primitives.Space))
    .unwrap()
  session = ignored_release
  let (restored, repaint) = session
    .handle_event(
      windows_button_test_event(5, @platform.Resized(width=640.0, height=240.0)),
    )
    .unwrap()
  session = restored
  assert_true(repaint)
  assert_true(session.is_presentable())
  assert_true(!session.demo().button().is_focused())
  assert_eq(session.demo().activations(), 0)
  let (no_replay, _) = session
    .handle_event(windows_button_test_key_up(6, @primitives.Space))
    .unwrap()
  session = no_replay
  assert_eq(session.demo().activations(), 0)
}

///|
test "Windows same-metrics sync preserves armed input and changed metrics cancel it" {
  let mut session = WindowsButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(windows_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (pressed, _) = session
    .handle_event(windows_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = pressed

  let (same, repaint) = session.sync_metrics(640.0, 240.0, 1.0)
  session = same
  assert_true(!repaint)
  assert_true(session.demo().button().is_pressed())

  let (resized, repaint) = session.sync_metrics(270.0, 180.0, 2.0)
  session = resized
  assert_true(repaint)
  assert_true(session.is_presentable())
  assert_eq(session.width, 270.0)
  assert_eq(session.scale, 2.0)
  assert_true(session.demo().button().is_focused())
  assert_true(!session.demo().button().is_pressed())
  let (release, _) = session
    .handle_event(windows_button_test_key_up(3, @primitives.Space))
    .unwrap()
  session = release
  assert_eq(session.demo().activations(), 0)
}

///|
test "Windows invalid backing scale suspends and restores without stale input" {
  let mut session = WindowsButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(windows_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (space_down, _) = session
    .handle_event(windows_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = space_down

  let (invalid_scale, repaint) = session
    .handle_event(
      windows_button_test_event_at_scale(3, 0.0, @platform.ScaleChanged),
    )
    .unwrap()
  session = invalid_scale
  assert_true(!repaint)
  assert_true(!session.is_presentable())
  assert_true(!session.demo().button().is_pressed())

  let (valid_scale, repaint) = session
    .handle_event(
      windows_button_test_event_at_scale(4, 2.0, @platform.ScaleChanged),
    )
    .unwrap()
  session = valid_scale
  assert_true(repaint)
  assert_true(session.is_presentable())
  assert_eq(session.scene().unwrap().scale(), 2.0)
  assert_true(!session.demo().button().is_focused())
  let (late_release, _) = session
    .handle_event(windows_button_test_key_up(5, @primitives.Space))
    .unwrap()
  session = late_release
  assert_eq(session.demo().activations(), 0)
}
