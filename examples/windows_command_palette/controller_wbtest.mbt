///|
struct PaletteNativeSnapshot {
  document : String
  anchor : Int
  head : Int
  caret : @primitives.Rect
  epoch : Int
}

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
test "native Cancelled closes before the later session sync gate" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  let original = palette.field()
  let replacement = original.selection().normalized_range()
  let initial_owner = palette_native_owner(2, palette.open_epoch(), 41)
  let composing = palette_native_start_composition(
    initial_owner, original, replacement,
  ).unwrap()
  let (preview, marked_owner) = palette_native_update_mark(
    composing,
    "に",
    Some(1),
    [0],
    replacement,
  ).unwrap()
  palette.install_field_at(palette.open_epoch(), preview).unwrap()
  assert_true(palette.field().is_composing())

  // Windows queues this old-epoch Cancelled before FocusChanged(false).
  let cancelled_target : @native.TextSessionTarget = {
    window: @platform.WindowId::new(17L),
    sequence: 88L,
    epoch: marked_owner.epoch,
    owner_generation: marked_owner.owner_generation,
  }
  let accepted_cancel = palette_native_accept_event(
    marked_owner, cancelled_target,
  )
  let (restored, cancelled_owner) = palette_native_cancel_composition(
    accepted_cancel,
  )
  palette.install_field_at(palette.open_epoch(), restored.unwrap()).unwrap()
  assert_false(palette.field().is_composing())

  let owner : Ref[PaletteNativeOwner?] = Ref(Some(cancelled_owner))
  let native_focused = Ref(true)
  let dirty = Ref(false)
  assert_true(
    palette_native_session_sync_eligible(
      true,
      palette.is_open(),
      native_focused.val,
    ),
  )
  let ended_owner : Ref[PaletteNativeOwner?] = Ref(None)
  let reconciled = palette_reconcile_native_focus_state(
    false,
    palette,
    fixture.tree,
    owner,
    native_focused,
    dirty,
    active => {
      ended_owner.val = active
      true
    },
  )

  assert_true(reconciled)
  assert_false(palette.is_open())
  assert_true(owner.val is None)
  assert_eq(ended_owner.val.unwrap().epoch, marked_owner.epoch)
  assert_eq(ended_owner.val.unwrap().sequence, 88L)
  assert_eq(fixture.tree.val.focused(), Some(9UL))
  assert_eq(fixture.actions.val, 0)
  assert_eq(fixture.native_updates.val, 0)
  assert_false(native_focused.val)
  assert_true(dirty.val)
  assert_false(
    palette_native_session_sync_eligible(
      true,
      palette.is_open(),
      native_focused.val,
    ),
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
  let previous_pending = Some(pending_frame(fixture, 1, 640.0, 480.0, 1.0))
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
  let previous_pending = Some(pending_frame(fixture, 1, 640.0, 480.0, 1.0))
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

///|
test "pending frame identity survives intervening input, external edit fence, and resize" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  ignore(
    palette_handle_input(fixture, @primitives.TextInput(text="Go")).unwrap(),
  )
  let old_owner = palette_native_owner(2, palette.open_epoch(), 41)
  let pending = pending_frame(fixture, 1, 640.0, 480.0, 1.0)
  let pending_ref = Some(pending)
  let dirty = Ref(true)
  assert_false(palette_frame_submission_ready(dirty.val, pending_ref))

  let old_target : @native.TextSessionTarget = {
    window: @platform.WindowId::new(17L),
    sequence: 1L,
    epoch: old_owner.epoch,
    owner_generation: old_owner.owner_generation,
  }
  let updated_owner = palette_sync_external_edit_owner(Some(old_owner), active => {
      Ok(palette_native_owner_after_update(active, active.epoch + 1))
    })
    .unwrap()
    .unwrap()
  assert_eq(updated_owner.epoch, 42)
  assert_false(
    palette_native_target_current(
      palette,
      updated_owner,
      @platform.WindowId::new(17L),
      old_target,
    ),
  )
  assert_eq(palette.picker().query(), "Go")
  assert_false(palette_frame_submission_ready(dirty.val, pending_ref))

  let retained_samples = palette_readback_line(
    [10.0, 20.0, 30.0, 255.0, 40.0, 50.0, 60.0, 255.0, 70.0, 80.0, 90.0, 255.0],
    pending,
    77L,
  )
  assert_true(retained_samples.contains("\"presentation\":1"))
  assert_true(retained_samples.contains("\"frame_event_sequence\":77"))
  assert_true(retained_samples.contains("\"logical_width\":640"))
  assert_true(retained_samples.contains("\"logical_height\":480"))
  assert_true(retained_samples.contains("\"scale\":1"))
  assert_true(retained_samples.contains("\"point\":[160,160]"))

  let (completed, no_pending) = palette_take_completed_frame(pending_ref)
  assert_true(no_pending is None)
  assert_true(pending_frame_matches(completed.unwrap(), pending))
  assert_true(palette_frame_submission_ready(dirty.val, no_pending))

  let resized = pending_frame(fixture, 2, 800.0, 600.0, 1.5)
  let (recorded, resized_pending) = palette_record_accepted_frame(
    no_pending, resized,
  )
  assert_true(recorded)
  assert_eq(resized_pending.unwrap().width, 800.0)
  assert_eq(resized_pending.unwrap().height, 600.0)
  assert_eq(resized_pending.unwrap().scale, 1.5)
  let (overwrote, still_resized) = palette_record_accepted_frame(
    resized_pending, pending,
  )
  assert_false(overwrote)
  assert_true(pending_frame_matches(still_resized.unwrap(), resized))
}

///|
test "rejected native marks and results restore the transaction before next record" {
  let fixture = palette_fixture()
  let palette = fixture.palette
  palette.open(fixture.tree).unwrap()
  ignore(
    palette_handle_input(fixture, @primitives.TextInput(text="Go")).unwrap(),
  )
  let replacement = palette.field().selection().normalized_range()
  let starting_owner = palette_native_owner(2, palette.open_epoch(), 51)
  let marked_owner = palette_native_start_composition(
    starting_owner,
    palette.field(),
    replacement,
  ).unwrap()
  let oversized = "日".repeat(86)
  let (oversized_mark, marked_owner) = palette_native_update_mark(
    marked_owner,
    oversized,
    Some(86),
    [],
    replacement,
  ).unwrap()
  let marked_restored_snapshot : Ref[(String, Int, Int)] = Ref(("", -1, -1))
  assert_true(
    palette.install_field_at(palette.open_epoch(), oversized_mark)
    is Err(@palette.QueryTooLarge),
  )
  let after_mark_rejection = palette_reject_native_edit(
    palette,
    marked_owner,
    active => Ok(palette_native_owner_after_update(active, active.epoch + 1)),
    (cancelled, restored) => {
      let selection = restored.selection()
      marked_restored_snapshot.val = (
        restored.committed_document().text(),
        selection.anchor(),
        selection.head(),
      )
      Ok(palette_native_owner_after_update(cancelled, cancelled.epoch + 1))
    },
  ).unwrap()
  assert_eq(marked_restored_snapshot.val.0, "Go")
  assert_eq(marked_restored_snapshot.val.1, 2)
  assert_eq(marked_restored_snapshot.val.2, 2)
  assert_eq(after_mark_rejection.epoch, 53)
  assert_true(after_mark_rejection.composition is None)
  let old_mark_target : @native.TextSessionTarget = {
    window: @platform.WindowId::new(17L),
    sequence: 1L,
    epoch: marked_owner.epoch,
    owner_generation: marked_owner.owner_generation,
  }
  assert_false(
    palette_native_target_current(
      palette,
      after_mark_rejection,
      @platform.WindowId::new(17L),
      old_mark_target,
    ),
  )
  assert_false(palette.field().is_composing())
  assert_eq(palette.field().document().text(), "Go")
  assert_eq(palette.field().committed_document().text(), "Go")
  assert_eq(palette.picker().query(), "Go")

  let result_owner = palette_native_start_composition(
    after_mark_rejection,
    palette.field(),
    replacement,
  ).unwrap()
  let (oversized_result, _) = palette_native_append_result(
    result_owner,
    palette.field(),
    oversized,
    replacement,
  ).unwrap()
  assert_true(
    palette.install_field_at(palette.open_epoch(), oversized_result)
    is Err(@palette.QueryTooLarge),
  )
  let stale_field = oversized_result
  let stale_selection = stale_field.selection()
  let stale_native_rect = windows_palette_caret_rect(stale_field).unwrap()
  let native_snapshot : Ref[PaletteNativeSnapshot] = Ref({
    document: stale_field.committed_document().text(),
    anchor: stale_selection.anchor(),
    head: stale_selection.head(),
    caret: stale_native_rect,
    epoch: result_owner.epoch,
  })
  assert_true(
    native_snapshot.val.document != palette.field().committed_document().text(),
  )
  let pending_frame_before = pending_frame(fixture, 1, 640.0, 480.0, 1.0)
  let pending = Some(pending_frame_before)
  let dirty = Ref(true)
  assert_false(palette_frame_submission_ready(dirty.val, pending))
  let native_snapshot_before_rebase : Ref[PaletteNativeSnapshot] = Ref(
    native_snapshot.val,
  )
  let after_result_rejection = palette_reject_native_edit(
    palette,
    result_owner,
    active => {
      // Native cancel advances ownership and prunes queued records, but it
      // leaves the native document and selection untouched.
      native_snapshot.val = { ..native_snapshot.val, epoch: active.epoch + 1, }
      Ok(palette_native_owner_after_update(active, native_snapshot.val.epoch))
    },
    (cancelled, restored) => {
      native_snapshot_before_rebase.val = native_snapshot.val
      let restored_document = restored.committed_document()
      let restored_selection = restored_document.selection()
      let restored_rect = windows_palette_caret_rect(restored).unwrap()
      let rebased_epoch = cancelled.epoch + 1
      native_snapshot.val = {
        document: restored_document.text(),
        anchor: restored_selection.anchor(),
        head: restored_selection.head(),
        caret: restored_rect,
        epoch: rebased_epoch,
      }
      Ok(palette_native_owner_after_update(cancelled, rebased_epoch))
    },
  ).unwrap()
  assert_eq(after_result_rejection.epoch, 55)
  assert_true(after_result_rejection.composition is None)
  assert_eq(
    native_snapshot_before_rebase.val.document,
    stale_field.committed_document().text(),
  )
  assert_eq(native_snapshot_before_rebase.val.anchor, stale_selection.anchor())
  assert_eq(native_snapshot_before_rebase.val.head, stale_selection.head())
  assert_eq(native_snapshot.val.document, "Go")
  assert_eq(native_snapshot.val.anchor, 2)
  assert_eq(native_snapshot.val.head, 2)
  assert_eq(
    native_snapshot.val.caret.left(),
    windows_palette_caret_rect(palette.field()).unwrap().left(),
  )
  let old_result_target : @native.TextSessionTarget = {
    window: @platform.WindowId::new(17L),
    sequence: 1L,
    epoch: result_owner.epoch,
    owner_generation: result_owner.owner_generation,
  }
  assert_false(
    palette_native_target_current(
      palette,
      after_result_rejection,
      @platform.WindowId::new(17L),
      old_result_target,
    ),
  )
  assert_false(palette.field().is_composing())
  assert_eq(palette.field().document().text(), "Go")
  assert_eq(palette.field().committed_document().text(), "Go")
  assert_eq(palette.picker().query(), "Go")

  let next_native_target : @native.TextSessionTarget = {
    window: @platform.WindowId::new(17L),
    sequence: 1L,
    epoch: after_result_rejection.epoch,
    owner_generation: after_result_rejection.owner_generation,
  }
  assert_true(
    palette_native_target_current(
      palette,
      after_result_rejection,
      @platform.WindowId::new(17L),
      next_native_target,
    ),
  )
  assert_eq(
    native_snapshot.val.document,
    palette.field().committed_document().text(),
  )
  assert_eq(native_snapshot.val.anchor, palette.field().selection().anchor())
  assert_eq(native_snapshot.val.head, palette.field().selection().head())
  let next_owner = palette_native_accept_event(
    after_result_rejection, next_native_target,
  )
  assert_true(
    palette_native_start_composition(next_owner, palette.field(), replacement)
    is Some(_),
  )
  assert_false(palette_frame_submission_ready(dirty.val, pending))
  assert_true(pending_frame_matches(pending.unwrap(), pending_frame_before))
}
