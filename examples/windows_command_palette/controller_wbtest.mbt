///|
test "Windows command palette native owner fences window epoch and FIFO sequence" {
  let fixture = palette_fixture()
  fixture.palette.open(fixture.tree).unwrap()
  let window = @platform.WindowId::new(17L)
  let owner = palette_native_owner(2, fixture.palette.open_epoch(), 41)
  let first : @native.TextSessionTarget = {
    window,
    sequence: 1L,
    epoch: 41,
    owner_generation: 2,
  }
  assert_true(
    palette_native_target_current(fixture.palette, owner, window, first),
  )
  let accepted = palette_native_accept_event(owner, first)
  assert_false(
    palette_native_target_current(fixture.palette, accepted, window, first),
  )

  let next : @native.TextSessionTarget = { ..first, sequence: 2L, }
  let wrong_window : @native.TextSessionTarget = {
    ..next,
    window: @platform.WindowId::new(18L),
  }
  let wrong_native_epoch : @native.TextSessionTarget = { ..next, epoch: 42, }
  let wrong_owner : @native.TextSessionTarget = { ..next, owner_generation: 3, }
  assert_true(
    palette_native_target_current(fixture.palette, accepted, window, next),
  )
  assert_false(
    palette_native_target_current(
      fixture.palette,
      accepted,
      window,
      wrong_window,
    ),
  )
  assert_false(
    palette_native_target_current(
      fixture.palette,
      accepted,
      window,
      wrong_native_epoch,
    ),
  )
  assert_false(
    palette_native_target_current(
      fixture.palette,
      accepted,
      window,
      wrong_owner,
    ),
  )
  assert_false(
    palette_native_target_current(
      fixture.palette,
      palette_native_owner(2, fixture.palette.open_epoch() - 1, 41),
      window,
      next,
    ),
  )

  ignore(palette_handle_input(fixture, palette_test_escape()).unwrap())
  assert_false(
    palette_native_target_current(fixture.palette, accepted, window, next),
  )
}

///|
fn palette_test_escape() -> @primitives.InputEvent {
  @primitives.KeyPressed(
    key=@primitives.Escape,
    modifiers=@primitives.Modifiers::none(),
    repeat=false,
  )
}

///|
test "native empty composition keeps Enter quarantined until release across end blur and reopen" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  let replacement = palette.field().selection().normalized_range()
  let owner = palette_native_start_composition(
    palette_native_owner(2, palette.open_epoch(), 12),
    palette.field(),
    replacement,
  ).unwrap()
  assert_false(palette.field().is_composing())

  let enter_press = @primitives.KeyPressed(
    key=@primitives.Enter,
    modifiers=@primitives.Modifiers::none(),
    repeat=false,
  )
  assert_true(
    palette_native_key_disposition(Some(owner), palette.field(), enter_press)
    is NativeImeKey,
  )
  let key_guard = palette_native_guard_for_press(enter_press)
  assert_true(key_guard is Some(GuardEnter))
  let enter_repeat = @primitives.KeyPressed(
    key=@primitives.Enter,
    modifiers=@primitives.Modifiers::none(),
    repeat=true,
  )
  let (repeat_consumed, key_guard) = palette_native_guard_event(
    key_guard, enter_repeat,
  )
  assert_true(repeat_consumed)
  assert_true(key_guard is Some(GuardEnter))

  let (restored, ended_owner) = palette_native_end_composition(owner)
  palette.install_field_at(palette.open_epoch(), restored.unwrap()).unwrap()
  assert_true(ended_owner.composition is None)
  let closing_epoch = palette.open_epoch()
  ignore(palette.blur().unwrap())
  palette_finish_close_after_fence(palette, closing_epoch, fixture.tree, true).unwrap()
  palette.open(fixture.tree).unwrap()

  let (reopened_repeat_consumed, key_guard) = palette_native_guard_event(
    key_guard, enter_repeat,
  )
  assert_true(reopened_repeat_consumed)
  assert_true(key_guard is Some(GuardEnter))
  let enter_release = @primitives.KeyReleased(
    key=@primitives.Enter,
    modifiers=@primitives.Modifiers::none(),
  )
  let (release_consumed, key_guard) = palette_native_guard_event(
    key_guard, enter_release,
  )
  assert_true(release_consumed)
  assert_true(key_guard is None)
  assert_true(palette.is_open())
  assert_eq(fixture.actions.val, 0)
  assert_eq(fixture.background_releases.val, 0)
}

///|
test "native empty composition Escape cancels first and retains release before fresh dismissal" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  let replacement = palette.field().selection().normalized_range()
  let owner = palette_native_start_composition(
    palette_native_owner(2, palette.open_epoch(), 15),
    palette.field(),
    replacement,
  ).unwrap()
  let escape_press = palette_test_escape()
  assert_true(
    palette_native_key_disposition(Some(owner), palette.field(), escape_press)
    is CancelNativeComposition,
  )

  let (original, cleared_owner) = palette_native_cancel_composition(owner)
  palette.install_field_at(palette.open_epoch(), original.unwrap()).unwrap()
  let cancelled_owner = palette_native_owner_after_update(cleared_owner, 16)
  assert_true(cancelled_owner.composition is None)
  assert_true(palette.is_open())
  assert_eq(fixture.actions.val, 0)
  let key_guard = palette_native_guard_for_press(escape_press)
  assert_true(key_guard is Some(GuardEscape))

  let escape_repeat = @primitives.KeyPressed(
    key=@primitives.Escape,
    modifiers=@primitives.Modifiers::none(),
    repeat=true,
  )
  let (repeat_consumed, key_guard) = palette_native_guard_event(
    key_guard, escape_repeat,
  )
  assert_true(repeat_consumed)
  assert_true(key_guard is Some(GuardEscape))
  let escape_release = @primitives.KeyReleased(
    key=@primitives.Escape,
    modifiers=@primitives.Modifiers::none(),
  )
  let (release_consumed, key_guard) = palette_native_guard_event(
    key_guard, escape_release,
  )
  assert_true(release_consumed)
  assert_true(key_guard is None)
  assert_true(palette.is_open())

  assert_true(
    palette_native_key_disposition(
      Some(cancelled_owner),
      palette.field(),
      escape_press,
    )
    is SharedFieldKey,
  )
  let dismissed = palette_handle_input(fixture, escape_press).unwrap()
  match dismissed.effect {
    @palette.Closed(command_id~, ..) => assert_true(command_id is None)
    _ => fail("fresh Escape did not dismiss after native composition cancel")
  }
  palette_finish_close_after_fence(
    palette,
    palette.open_epoch(),
    fixture.tree,
    true,
  ).unwrap()
  assert_eq(fixture.actions.val, 0)
  assert_eq(fixture.tree.val.focused(), Some(9UL))
}

///|
test "Windows command palette filters committed native results but not IME marks" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  let field = palette.field()
  let replacement = field.selection().normalized_range()
  let owner = palette_native_owner(2, palette.open_epoch(), 9)
  let composing = palette_native_start_composition(owner, field, replacement).unwrap()
  let (preview, composing) = palette_native_update_mark(
    composing,
    "にほんご",
    Some(4),
    [0, 0, 0, 0],
    replacement,
  ).unwrap()
  palette.install_field_at(palette.open_epoch(), preview).unwrap()
  assert_true(palette.field().is_composing())
  assert_eq(palette.field().committed_document().text(), "")
  assert_eq(palette.picker().query(), "")
  assert_eq(palette.semantics().search_value, "")
  assert_eq(palette.picker().match_count(), 16)

  let (cancelled, cancelled_owner) = palette_native_cancel_composition(
    composing,
  )
  palette.install_field_at(palette.open_epoch(), cancelled.unwrap()).unwrap()
  assert_false(palette.field().is_composing())
  assert_eq(palette.field().document().text(), "")
  assert_eq(palette.picker().query(), "")
  assert_eq(palette.picker().match_count(), 16)
  assert_true(cancelled_owner.composition is None)

  let composing = palette_native_start_composition(
    cancelled_owner,
    palette.field(),
    replacement,
  ).unwrap()
  let (preview, composing) = palette_native_update_mark(
    composing,
    "にほんご",
    Some(4),
    [0, 0, 0, 0],
    replacement,
  ).unwrap()
  palette.install_field_at(palette.open_epoch(), preview).unwrap()
  let (committed, completed_owner) = palette_native_append_result(
    composing,
    palette.field(),
    "日本語",
    replacement,
  ).unwrap()
  palette.install_field_at(palette.open_epoch(), committed).unwrap()
  assert_false(palette.field().is_composing())
  assert_eq(palette.field().committed_document().text(), "日本語")
  assert_eq(palette.picker().query(), "日本語")
  assert_eq(palette.semantics().search_value, "日本語")
  assert_eq(palette.picker().match_count(), 1)
  assert_true(completed_owner.composition is None)
  assert_true(
    palette_native_append_result(
      completed_owner,
      palette.field(),
      "日本語",
      replacement,
    )
    is Err(_),
  )
}

///|
test "Windows command palette close waits for native fence before action and focus restore" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  let epoch = palette.open_epoch()
  let tree = fixture.tree
  let _ = palette_handle_input(
    fixture,
    @primitives.KeyPressed(
      key=@primitives.Enter,
      modifiers=@primitives.Modifiers::none(),
      repeat=false,
    ),
  ).unwrap()
  assert_false(palette.is_open())
  assert_eq(fixture.actions.val, 0)
  assert_eq(tree.val.focused(), Some(2UL))

  palette_finish_close_after_fence(palette, epoch, tree, false).unwrap()
  assert_eq(fixture.actions.val, 0)
  assert_eq(tree.val.focused(), Some(2UL))

  palette_finish_close_after_fence(palette, epoch, tree, true).unwrap()
  assert_eq(fixture.actions.val, 1)
  assert_eq(tree.val.focused(), Some(9UL))
  palette_finish_close_after_fence(palette, epoch, tree, true).unwrap()
  assert_eq(fixture.actions.val, 1)
  assert_true(
    palette_handle_input(
      fixture,
      @primitives.KeyReleased(
        key=@primitives.Enter,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).unwrap().consumed,
  )
  assert_eq(fixture.background_releases.val, 0)
}

///|
test "Windows command palette holds the cancel key through its physical release" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  let replacement = palette.field().selection().normalized_range()
  let native_owner = palette_native_start_composition(
    palette_native_owner(2, palette.open_epoch(), 12),
    palette.field(),
    replacement,
  ).unwrap()
  let (preview, native_owner) = palette_native_update_mark(
    native_owner,
    "に",
    Some(1),
    [0],
    replacement,
  ).unwrap()
  palette.install_field_at(palette.open_epoch(), preview).unwrap()
  assert_true(palette.field().is_composing())

  let cancelled = palette_handle_input(fixture, palette_test_escape()).unwrap()
  assert_true(cancelled.effect is @palette.CompositionCancelled)
  assert_true(palette.is_open())
  assert_false(palette.field().is_composing())
  let (original, native_owner) = palette_native_cancel_composition(native_owner)
  palette.install_field_at(palette.open_epoch(), original.unwrap()).unwrap()
  assert_true(native_owner.composition is None)

  let held_press = palette_handle_input(fixture, palette_test_escape()).unwrap()
  assert_true(held_press.consumed)
  assert_true(palette.is_open())
  let cancel_release = palette_handle_input(
    fixture,
    @primitives.KeyReleased(
      key=@primitives.Escape,
      modifiers=@primitives.Modifiers::none(),
    ),
  ).unwrap()
  assert_true(cancel_release.consumed)
  assert_true(palette.is_open())

  let close = palette_handle_input(fixture, palette_test_escape()).unwrap()
  match close.effect {
    @palette.Closed(command_id~, ..) => assert_true(command_id is None)
    _ => fail("fresh Escape press did not close the palette")
  }
  palette_finish_close_after_fence(
    palette,
    palette.open_epoch(),
    fixture.tree,
    true,
  ).unwrap()
  let close_release = palette_handle_input(
    fixture,
    @primitives.KeyReleased(
      key=@primitives.Escape,
      modifiers=@primitives.Modifiers::none(),
    ),
  ).unwrap()
  assert_true(close_release.consumed)
  assert_false(palette.is_open())
  assert_eq(fixture.actions.val, 0)
  assert_eq(fixture.tree.val.focused(), Some(9UL))
}

///|
test "Windows command palette Busy presentation retains the complete retry state" {
  let fixture = palette_fixture()
  fixture.palette.open(fixture.tree).unwrap()
  ignore(
    palette_handle_input(fixture, @primitives.TextInput(text="Go")).unwrap(),
  )
  let active_owner = {
    ..palette_native_owner(2, fixture.palette.open_epoch(), 41),
    sequence: 7L,
  }
  let owner = Ref(Some(active_owner))
  let previous_pending = Some(pending_frame(fixture, 1))
  let dirty = Ref(true)
  let scene = palette_scene(fixture, 640.0, 480.0, 1.0).unwrap()
  let prepared = prepare_palette_frame(
    fixture,
    scene,
    2,
    owner.val,
    dirty.val,
    previous_pending,
    640.0,
    480.0,
    1.0,
  )
  let end_calls = Ref(0)
  let (decision, retained) = palette_present_result(
    Err(@diagnostics.FrameworkError::new(@diagnostics.Busy, "present")),
    prepared,
    fixture,
    owner,
    dirty,
    _ => {
      end_calls.val += 1
      false
    },
  )
  assert_true(fixture.palette.is_open())
  assert_true(decision is BusyPending)
  assert_eq(fixture.palette.picker().query(), "Go")
  assert_eq(fixture.palette.field().committed_document().text(), "Go")
  assert_eq(fixture.tree.val.focused(), Some(2UL))
  assert_eq(fixture.actions.val, 0)
  assert_eq(end_calls.val, 0)
  assert_true(dirty.val)
  assert_eq(retained.frame.presentation, 2)
  assert_eq(retained.frame.query, "Go")
  assert_eq(retained.field_text, "Go")
  assert_eq(retained.committed_text, "Go")
  assert_false(retained.composing)
  assert_eq(retained.selection_anchor, 2)
  assert_eq(retained.selection_head, 2)
  assert_eq(retained.owner.unwrap().epoch, 41)
  assert_eq(retained.owner.unwrap().sequence, 7L)
  assert_eq(retained.focus_owner.unwrap().id(), 2UL)
  assert_eq(retained.actions, 0)
  assert_true(retained.dirty)
  assert_eq(retained.previous_pending.unwrap().presentation, 1)
  assert_true(retained.scene.items().length() > 0)
}

///|
test "Windows command palette hard presentation rejection fails closed without action" {
  let fixture = palette_fixture()
  fixture.palette.open(fixture.tree).unwrap()
  ignore(
    palette_handle_input(fixture, @primitives.TextInput(text="Go")).unwrap(),
  )
  let owner = Ref(
    Some({
      ..palette_native_owner(2, fixture.palette.open_epoch(), 41),
      sequence: 7L,
    }),
  )
  let dirty = Ref(true)
  let previous_pending = Some(pending_frame(fixture, 1))
  let scene = palette_scene(fixture, 640.0, 480.0, 1.0).unwrap()
  let prepared = prepare_palette_frame(
    fixture,
    scene,
    2,
    owner.val,
    dirty.val,
    previous_pending,
    640.0,
    480.0,
    1.0,
  )
  let end_calls = Ref(0)
  let (decision, retained) = palette_present_result(
    Err(@diagnostics.FrameworkError::new(@diagnostics.StaleHandle, "present")),
    prepared,
    fixture,
    owner,
    dirty,
    _ => {
      end_calls.val += 1
      false
    },
  )
  assert_true(decision is RejectPending)
  assert_false(fixture.palette.is_open())
  assert_true(owner.val is None)
  assert_false(dirty.val)
  assert_eq(end_calls.val, 1)
  assert_eq(fixture.actions.val, 0)
  assert_eq(fixture.palette.picker().query(), "Go")
  assert_eq(fixture.palette.field().committed_document().text(), "Go")
  assert_eq(fixture.tree.val.focused(), Some(2UL))
  assert_eq(retained.frame.query, "Go")
  assert_eq(retained.previous_pending.unwrap().presentation, 1)
}
