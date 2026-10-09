///|
fn mac_button_test_event(
  sequence : Int64,
  kind : @platform.EventKind,
) -> @platform.Event {
  @platform.Event::new(@platform.WindowId::new(1), sequence, 1.0, kind)
}

///|
fn mac_button_test_event_at_scale(
  sequence : Int64,
  scale : Double,
  kind : @platform.EventKind,
) -> @platform.Event {
  @platform.Event::new(@platform.WindowId::new(1), sequence, scale, kind)
}

///|
fn mac_button_test_key_down(
  sequence : Int64,
  key : @primitives.Key,
  repeat : Bool,
) -> @platform.Event {
  mac_button_test_event(
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
fn mac_button_test_key_up(
  sequence : Int64,
  key : @primitives.Key,
) -> @platform.Event {
  mac_button_test_event(
    sequence,
    @platform.Input(
      @primitives.KeyReleased(key~, modifiers=@primitives.Modifiers::none()),
    ),
  )
}

///|
test "macOS event adapter routes Tab Enter and Space once" {
  let mut session = MacButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (after_tab, tab_repaint) = session
    .handle_event(mac_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = after_tab
  assert_true(tab_repaint)
  assert_true(session.demo().button().is_focused())

  let (after_enter, _) = session
    .handle_event(mac_button_test_key_down(2, @primitives.Enter, false))
    .unwrap()
  session = after_enter
  assert_eq(session.demo().activations(), 1)
  let (after_repeat, _) = session
    .handle_event(mac_button_test_key_down(3, @primitives.Enter, true))
    .unwrap()
  session = after_repeat
  let (after_enter_up, _) = session
    .handle_event(mac_button_test_key_up(4, @primitives.Enter))
    .unwrap()
  session = after_enter_up
  assert_eq(session.demo().activations(), 1)

  let (space_held, _) = session
    .handle_event(mac_button_test_key_down(5, @primitives.Space, false))
    .unwrap()
  session = space_held
  assert_eq(session.demo().activations(), 1)
  assert_true(session.demo().button().is_pressed())
  let (space_repeat, _) = session
    .handle_event(mac_button_test_key_down(6, @primitives.Space, true))
    .unwrap()
  session = space_repeat
  let (space_released, _) = session
    .handle_event(mac_button_test_key_up(7, @primitives.Space))
    .unwrap()
  session = space_released
  assert_eq(session.demo().activations(), 2)
  assert_true(!session.demo().button().is_pressed())

  let (duplicate_up, _) = session
    .handle_event(mac_button_test_key_up(8, @primitives.Space))
    .unwrap()
  session = duplicate_up
  let (unmatched_repeat, _) = session
    .handle_event(mac_button_test_key_down(9, @primitives.Enter, true))
    .unwrap()
  session = unmatched_repeat
  assert_eq(session.demo().activations(), 2)
}

///|
test "macOS adapter cancels stale keyboard input on blur and invalid resize" {
  let mut session = MacButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(mac_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (space_held, _) = session
    .handle_event(mac_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = space_held
  let (blurred, _) = session
    .handle_event(mac_button_test_event(3, @platform.FocusChanged(false)))
    .unwrap()
  session = blurred
  assert_true(!session.demo().button().is_pressed())
  let (after_key_up, _) = session
    .handle_event(mac_button_test_key_up(4, @primitives.Space))
    .unwrap()
  session = after_key_up
  assert_eq(session.demo().activations(), 0)

  let (suspended, repaint) = session
    .handle_event(
      mac_button_test_event(5, @platform.Resized(width=0.0, height=0.0)),
    )
    .unwrap()
  session = suspended
  assert_true(!repaint)
  assert_true(!session.is_presentable())
  let (stale_input, _) = session
    .handle_event(mac_button_test_key_up(6, @primitives.Space))
    .unwrap()
  session = stale_input
  let (restored, repaint) = session
    .handle_event(
      mac_button_test_event(7, @platform.Resized(width=640.0, height=240.0)),
    )
    .unwrap()
  session = restored
  assert_true(repaint)
  assert_true(session.is_presentable())
  assert_eq(session.demo().activations(), 0)
  assert_true(!session.demo().button().is_focused())
  let (no_replay, _) = session
    .handle_event(mac_button_test_key_up(8, @primitives.Space))
    .unwrap()
  session = no_replay
  assert_eq(session.demo().activations(), 0)

  let (invalid, repaint) = session
    .handle_event(
      mac_button_test_event(9, @platform.Resized(width=-1.0, height=240.0)),
    )
    .unwrap()
  session = invalid
  assert_true(!repaint)
  assert_true(!session.is_presentable())
  let (still_invalid, repaint) = session
    .handle_event(
      mac_button_test_event_at_scale(10, 2.0, @platform.ScaleChanged),
    )
    .unwrap()
  session = still_invalid
  assert_true(!repaint)
  assert_true(!session.is_presentable())
  let _ = session
}

///|
test "macOS adapter suspends and restores invalid scale without replay" {
  let mut session = MacButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(mac_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (space_held, _) = session
    .handle_event(mac_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = space_held
  let (suspended, repaint) = session
    .handle_event(
      mac_button_test_event_at_scale(3, 0.0, @platform.ScaleChanged),
    )
    .unwrap()
  session = suspended
  assert_true(!repaint)
  assert_true(!session.is_presentable())
  assert_true(!session.demo().button().is_pressed())

  let (ignored_input, _) = session
    .handle_event(mac_button_test_key_up(4, @primitives.Space))
    .unwrap()
  session = ignored_input
  let (restored, repaint) = session
    .handle_event(
      mac_button_test_event_at_scale(5, 2.0, @platform.ScaleChanged),
    )
    .unwrap()
  session = restored
  assert_true(repaint)
  assert_true(session.is_presentable())
  assert_true(!session.demo().button().is_focused())
  assert_eq(session.demo().activations(), 0)
  let (stale_release, _) = session
    .handle_event(mac_button_test_key_up(6, @primitives.Space))
    .unwrap()
  session = stale_release
  assert_eq(session.demo().activations(), 0)
}

///|
test "disabled loading reset and undersized resize keep fixture state bounded" {
  let mut session = MacButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(mac_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (disabled, _) = session
    .handle_event(
      mac_button_test_key_down(2, @primitives.Character("d"), false),
    )
    .unwrap()
  session = disabled
  assert_true(!session.demo().button().is_enabled())
  assert_true(!session.demo().button().is_focused())
  let (enabled, _) = session
    .handle_event(
      mac_button_test_key_down(3, @primitives.Character("d"), false),
    )
    .unwrap()
  session = enabled
  assert_true(session.demo().button().is_enabled())

  let (focused_again, _) = session
    .handle_event(mac_button_test_key_down(4, @primitives.Tab, false))
    .unwrap()
  session = focused_again
  let (loading, _) = session
    .handle_event(
      mac_button_test_key_down(5, @primitives.Character("l"), false),
    )
    .unwrap()
  session = loading
  assert_true(session.demo().button().is_loading())
  assert_true(session.demo().button().is_focused())
  let (reset, _) = session
    .handle_event(
      mac_button_test_key_down(6, @primitives.Character("r"), false),
    )
    .unwrap()
  session = reset
  assert_true(!session.demo().button().is_loading())
  assert_true(!session.demo().button().is_focused())

  let (small, _) = session
    .handle_event(
      mac_button_test_event(7, @platform.Resized(width=80.0, height=30.0)),
    )
    .unwrap()
  session = small
  assert_true(session.is_presentable())
  assert_true(!session.demo().is_button_visible())
  let snapshot = session.scene().unwrap()
  assert_eq(snapshot.items().length(), 1)
  let (restored, _) = session
    .handle_event(
      mac_button_test_event(8, @platform.Resized(width=640.0, height=240.0)),
    )
    .unwrap()
  session = restored
  assert_true(session.demo().is_button_visible())
  assert_eq(session.demo().activations(), 0)
  let _ = session
}

///|
test "macOS adapter syncs queued resize and scale history to current metrics" {
  let mut session = MacButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(mac_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (space_held, _) = session
    .handle_event(mac_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = space_held
  assert_true(session.demo().button().is_pressed())

  let (undersized, _) = session
    .handle_event(
      mac_button_test_event(3, @platform.Resized(width=80.0, height=30.0)),
    )
    .unwrap()
  session = undersized
  let (scale_changed, _) = session
    .handle_event(
      mac_button_test_event_at_scale(4, 1.5, @platform.ScaleChanged),
    )
    .unwrap()
  session = scale_changed
  let (middle_size, _) = session
    .handle_event(
      mac_button_test_event_at_scale(
        5,
        1.5,
        @platform.Resized(width=480.0, height=180.0),
      ),
    )
    .unwrap()
  session = middle_size
  let (old_scale, _) = session
    .handle_event(
      mac_button_test_event_at_scale(6, 1.0, @platform.ScaleChanged),
    )
    .unwrap()
  session = old_scale
  let (last_queued_size, _) = session
    .handle_event(
      mac_button_test_event(7, @platform.Resized(width=550.0, height=220.0)),
    )
    .unwrap()
  session = last_queued_size

  let (current, repaint) = session.sync_metrics(600.0, 240.0, 2.0)
  session = current
  assert_true(repaint)
  assert_true(session.is_presentable())
  assert_eq(session.width, 600.0)
  assert_eq(session.height, 240.0)
  assert_eq(session.scale, 2.0)
  let snapshot = session.scene().unwrap()
  assert_eq(snapshot.viewport().size().width(), 600.0)
  assert_eq(snapshot.viewport().size().height(), 240.0)
  assert_eq(snapshot.scale(), 2.0)
  assert_true(!session.demo().button().is_focused())
  assert_true(!session.demo().button().is_pressed())
  let (after_release, _) = session
    .handle_event(mac_button_test_key_up(8, @primitives.Space))
    .unwrap()
  assert_eq(after_release.demo().activations(), 0)
}

///|
test "macOS same-metrics sync preserves focused pressed input" {
  let mut session = MacButtonSession::new(640.0, 240.0, 1.0).unwrap()
  let (focused, _) = session
    .handle_event(mac_button_test_key_down(1, @primitives.Tab, false))
    .unwrap()
  session = focused
  let (space_held, _) = session
    .handle_event(mac_button_test_key_down(2, @primitives.Space, false))
    .unwrap()
  session = space_held

  let (synced, repaint) = session.sync_metrics(640.0, 240.0, 1.0)
  session = synced
  assert_true(!repaint)
  assert_true(session.demo().button().is_focused())
  assert_true(session.demo().button().is_pressed())
  assert_eq(session.demo().activations(), 0)
}
