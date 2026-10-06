///|
fn windows_field_test_measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, @text_field.TextFieldError] {
  let carets = []
  let mut offset = 0
  let mut index = 0
  let first = @primitives.Rect::new(0.0, 0.0, 0.0, 16.0).unwrap()
  carets.push(@text_layout.CaretGeometry::new(0, true, first, first).unwrap())
  for scalar in document.text().iter() {
    offset += if scalar.to_int() > 0xFFFF { 2 } else { 1 }
    index += 1
    let caret = @primitives.Rect::new(index.to_double() * 8.0, 0.0, 0.0, 16.0).unwrap()
    carets.push(
      @text_layout.CaretGeometry::new(offset, true, caret, caret).unwrap(),
    )
  }
  let bounds = @primitives.Rect::new(0.0, 0.0, index.to_double() * 8.0, 20.0).unwrap()
  match
    @text_layout.TextMeasurement::new(
      document, bounds, bounds, 14.0, 1, 0, carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.MeasurementFailed)
  }
}

///|
fn windows_field_test_admit(
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @text_field.TextFieldError] {
  if document == measurement.document() {
    Ok(())
  } else {
    Err(@text_field.AdmissionFailed)
  }
}

///|
fn windows_field_test_hit(
  document : @text.TextDocument,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, @text_field.TextFieldError] {
  let measurement = match windows_field_test_measure(document) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut offset = 0
  let mut distance = 1.0e300
  for caret in measurement.carets() {
    let x = caret.strong().left()
    let next_distance = if point.x() >= x {
      point.x() - x
    } else {
      x - point.x()
    }
    if next_distance < distance {
      offset = caret.utf16_offset()
      distance = next_distance
    }
  }
  match @text_layout.TextHit::new(document, offset, 0, offset, true, true) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.HitTestFailed)
  }
}

///|
fn windows_field_test_field(value : String) -> @text_field.TextField {
  windows_field_test_field_for_document(@text.TextDocument::new(value).unwrap())
}

///|
fn windows_field_test_field_for_document(
  document : @text.TextDocument,
) -> @text_field.TextField {
  @text_field.TextField::new(
    2,
    @primitives.Rect::new(24.0, 28.0, 300.0, 44.0).unwrap(),
    18.0,
    document,
    windows_field_test_measure,
    windows_field_test_admit,
  )
  .unwrap()
  .with_focus(true)
  .unwrap()
}

///|
fn windows_field_test_handle(
  field : @text_field.TextField,
  event : @primitives.InputEvent,
) -> (@text_field.TextField, @text_field.TextFieldAction?) {
  match
    field.handle_input(
      event, windows_field_test_measure, windows_field_test_admit, windows_field_test_hit,
    ) {
    Ok(value) => value
    Err(_) => abort("fake Windows field input failed")
  }
}

///|
fn windows_field_test_press(
  field : @text_field.TextField,
  key : @primitives.Key,
  modifiers? : @primitives.Modifiers = @primitives.Modifiers::none(),
) -> @text_field.TextField {
  let (value, _) = windows_field_test_handle(
    field,
    @primitives.KeyPressed(key~, modifiers~, repeat=false),
  )
  value
}

///|
fn windows_field_test_shortcut_modifiers(
  shift? : Bool = false,
) -> @primitives.Modifiers {
  @primitives.Modifiers::new(shift~, control=true, alt=false, meta=false)
}

///|
test "Windows field event target fences a stale owner epoch and sequence" {
  let owner = windows_text_owner(2, 9)
  let window = @platform.WindowId::new(1L)
  let current : @native.TextSessionTarget = {
    window,
    sequence: 11L,
    epoch: 9,
    owner_generation: 2,
  }
  assert_true(windows_session_target_current(owner, window, current))
  let accepted = windows_text_owner_accept_event(owner, current)
  assert_false(windows_session_target_current(accepted, window, current))
  let stale_epoch : @native.TextSessionTarget = {
    ..current,
    epoch: 8,
    sequence: 12L,
  }
  let stale_owner : @native.TextSessionTarget = {
    ..current,
    owner_generation: 3,
    sequence: 12L,
  }
  let other_window : @native.TextSessionTarget = {
    ..current,
    window: @platform.WindowId::new(2L),
    sequence: 12L,
  }
  assert_false(windows_session_target_current(owner, window, stale_epoch))
  assert_false(windows_session_target_current(owner, window, stale_owner))
  assert_false(windows_session_target_current(owner, window, other_window))
}

///|
test "Windows field never arms experimental IMM32 by default" {
  assert_false(windows_text_session_requested(false, true, true))
  assert_false(windows_text_session_requested(true, false, true))
  assert_false(windows_text_session_requested(true, true, false))
  assert_true(windows_text_session_requested(true, true, true))
}

///|
test "Windows field measured pointer click places a directional caret" {
  let field = windows_field_test_field("abcd")
  let (origin, _) = @text_field.scene_text_run_geometry(field.measurement()).unwrap()
  let point = @primitives.Point::new(
    field.content_bounds().left() + origin.x() + 16.0,
    field.content_bounds().top() + origin.y() + 8.0,
  ).unwrap()
  let (clicked, _) = windows_field_test_handle(
    field,
    @primitives.PointerButtonPressed(
      position=point,
      button=@primitives.Primary,
      modifiers=@primitives.Modifiers::none(),
    ),
  )
  assert_true(clicked.is_focused())
  assert_eq(clicked.selection().head(), 2)
  assert_eq(clicked.selection().anchor(), 2)
}

///|
test "Windows TextInput edits committed characters and bounded undo redo" {
  let initial = windows_field_test_field("")
  let (first, _) = windows_field_test_handle(
    initial,
    @primitives.TextInput(text="a"),
  )
  let (second, _) = windows_field_test_handle(
    first,
    @primitives.TextInput(text="😀"),
  )
  assert_true(second.document().text() == "a😀")
  assert_true(second.can_undo())
  let undo_event = @primitives.KeyPressed(
    key=@primitives.Character("z"),
    modifiers=windows_field_test_shortcut_modifiers(),
    repeat=false,
  )
  let (undone, _) = windows_field_test_handle(second, undo_event)
  assert_true(undone.document().text() == "a")
  let redo_event = @primitives.KeyPressed(
    key=@primitives.Character("y"),
    modifiers=windows_field_test_shortcut_modifiers(),
    repeat=false,
  )
  let (redone, _) = windows_field_test_handle(undone, redo_event)
  assert_true(redone.document().text() == "a😀")
  let redo_repeat = @primitives.KeyPressed(
    key=@primitives.Character("y"),
    modifiers=windows_field_test_shortcut_modifiers(),
    repeat=true,
  )
  match redo_repeat {
    @primitives.KeyPressed(repeat~, ..) => assert_true(repeat)
    _ => fail("native repeat flag was not preserved")
  }
}

///|
test "Windows field IME preview empty preedit cancellation and result are atomic" {
  let initial = windows_field_test_press(
    windows_field_test_field("abc"),
    @primitives.Character("a"),
    modifiers=windows_field_test_shortcut_modifiers(),
  )
  assert_eq(initial.selection().normalized_range().start(), 0)
  assert_eq(initial.selection().normalized_range().end(), 3)
  let replacement = initial.selection().normalized_range()
  let owner = windows_start_composition(
    windows_text_owner(2, 4),
    initial,
    replacement,
  ).unwrap()
  let (preview, owner) = windows_update_mark(
    owner,
    "かな",
    Some(2),
    [0, 0],
    replacement,
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(preview.is_composing())
  assert_true(preview.document().text() == "かな")
  assert_true(preview.committed_document() == initial.document())
  let (cleared, owner) = windows_update_mark(
    owner,
    "",
    None,
    [],
    replacement,
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_false(cleared.is_composing())
  assert_true(cleared.document() == initial.document())
  assert_true(cleared.marked_range() is None)
  let (cancelled_opt, _) = windows_cancel_composition(owner).unwrap()
  let cancelled = cancelled_opt.unwrap()
  assert_true(cancelled.document() == initial.document())
  assert_true(cancelled.selection() == initial.selection())
  assert_false(cancelled.can_undo())

  let (result_owner, committed) = windows_append_result(
    windows_start_composition(windows_text_owner(2, 5), initial, replacement).unwrap(),
    initial,
    "世界",
    replacement,
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_false(committed.is_composing())
  assert_true(committed.document().text() == "世界")
  assert_true(result_owner.composition is None)
  assert_true(committed.can_undo())
  let undone = committed
    .undo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(undone.document() == initial.document())
  assert_true(undone.selection() == initial.selection())
  assert_true(undone.can_redo())
}

///|
test "Windows IMM result commits once, then END cancels a later preedit" {
  let initial = windows_field_test_press(
    windows_field_test_field("ab"),
    @primitives.End,
  )
  let replacement = initial.selection().normalized_range()
  let owner = windows_start_composition(
    windows_text_owner(7, 3),
    initial,
    replacement,
  ).unwrap()
  let (owner, after_result) = windows_append_result(
    owner, initial, "漢", replacement, windows_field_test_measure, windows_field_test_admit,
  ).unwrap()
  assert_eq(after_result.document().text(), "ab漢")
  assert_false(after_result.is_composing())
  let next_range = after_result.selection().normalized_range()
  assert_true(next_range == @text.TextRange::new(3, 3).unwrap())
  let owner = windows_start_composition(owner, after_result, next_range).unwrap()
  let (preview, owner) = windows_update_mark(
    owner,
    "字",
    Some(1),
    [0],
    next_range,
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(preview.document().text() == "ab漢字")
  let (committed_opt, _) = windows_end_composition(owner).unwrap()
  let committed = committed_opt.unwrap()
  assert_true(committed.document().text() == "ab漢")
  assert_true(committed.can_undo())
  let undone = committed
    .undo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(undone.document() == initial.document())
  assert_true(undone.selection() == initial.selection())
}

///|
test "Windows renderer rejection rolls back result and next preedit to shown history" {
  let initial = windows_field_test_press(
    windows_field_test_field("abc"),
    @primitives.End,
  )
  let (shown, _) = windows_field_test_handle(
    initial,
    @primitives.TextInput(text="!"),
  )
  assert_true(shown.can_undo())
  let result_range = shown.selection().normalized_range()
  let started = windows_start_composition(
    windows_text_owner(9, 12),
    shown,
    result_range,
  ).unwrap()
  let (after_result_owner, after_result) = windows_append_result(
    started, shown, "漢", result_range, windows_field_test_measure, windows_field_test_admit,
  ).unwrap()
  let preedit_range = after_result.selection().normalized_range()
  let preedit_started = windows_start_composition(
    after_result_owner, after_result, preedit_range,
  ).unwrap()
  let (pending, _) = windows_update_mark(
    preedit_started,
    "字",
    Some(1),
    [0],
    preedit_range,
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(pending.document().text() == "abc!漢字")
  assert_true(
    classify_field_frame(
      Err(@diagnostics.FrameworkError::new(@diagnostics.Busy, "present")),
    ) ==
    BusyPending,
  )

  let mut restored = restore_submitted_field(shown, pending).unwrap()
  if restored.is_composing() {
    restored = restored
      .cancel_composition(windows_field_test_measure, windows_field_test_admit)
      .unwrap()
  }
  assert_true(!restored.is_composing())
  assert_true(restored.document().text() == shown.document().text())
  assert_true(restored.selection() == shown.selection())
  assert_eq(restored.revision(), shown.revision())
  assert_eq(restored.can_undo(), shown.can_undo())
  assert_eq(restored.can_redo(), shown.can_redo())
  let undone = restored
    .undo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(undone.document().text() == "abc")
  let redone = undone
    .redo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(redone.document().text() == shown.document().text())
  assert_true(redone.selection() == shown.selection())
}

///|
fn windows_field_test_reject_admit(
  _document : @text.TextDocument,
  _measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @text_field.TextFieldError] {
  Err(@text_field.AdmissionFailed)
}

///|
test "Windows IME rejects split-surrogate cursor and failed preview admission atomically" {
  let initial = windows_field_test_field("abc")
  let replacement = initial.selection().normalized_range()
  let owner = windows_start_composition(
    windows_text_owner(4, 8),
    initial,
    replacement,
  ).unwrap()
  assert_true(
    windows_update_mark(
      owner,
      "😀",
      Some(1),
      [0, 0],
      replacement,
      windows_field_test_measure,
      windows_field_test_admit,
    )
    is Err(@text_field.InvalidSelection),
  )
  assert_true(
    windows_update_mark(
      owner,
      "かな",
      Some(2),
      [0, 0],
      replacement,
      windows_field_test_measure,
      windows_field_test_reject_admit,
    )
    is Err(@text_field.AdmissionFailed),
  )
  let (restored_opt, cleared_owner) = windows_cancel_composition(owner).unwrap()
  let restored = restored_opt.unwrap()
  assert_true(cleared_owner.composition is None)
  assert_true(restored.document() == initial.document())
  assert_true(restored.selection() == initial.selection())
  assert_false(restored.can_undo())
}

///|
test "Windows field Busy retains pending value and rejection restores the shown history" {
  let original_doc = @text.TextDocument::new("abc")
    .unwrap()
    .with_selection(@text.TextSelection::new(3, 0).unwrap())
    .unwrap()
  let initial = windows_field_test_field_for_document(original_doc)
  let (typed, _) = windows_field_test_handle(
    initial,
    @primitives.TextInput(text="x"),
  )
  let (shown, _) = windows_field_test_handle(
    typed,
    @primitives.TextInput(text="y"),
  )
  let (pending, _) = windows_field_test_handle(
    shown,
    @primitives.TextInput(text="z"),
  )
  let busy = Err(@diagnostics.FrameworkError::new(@diagnostics.Busy, "present"))
  assert_true(classify_field_frame(busy) == BusyPending)
  assert_true(pending.document().text() == "xyz")
  assert_true(pending.can_undo())
  let rejected = restore_submitted_field(shown, pending).unwrap()
  assert_true(rejected.document() == shown.document())
  assert_true(rejected.selection() == shown.selection())
  assert_true(rejected.revision() == shown.revision())
  assert_true(rejected.can_undo() == shown.can_undo())
  assert_true(rejected.can_redo() == shown.can_redo())
  let undo = rejected
    .undo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(undo.document().text() == "x")
  let original = undo
    .undo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(original.document() == initial.document())
  assert_true(original.selection() == initial.selection())
  let redo = original
    .redo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(redo.document().text() == "x")
  let shown_again = redo
    .redo(windows_field_test_measure, windows_field_test_admit)
    .unwrap()
  assert_true(shown_again.document() == shown.document())
  assert_true(shown_again.selection() == shown.selection())
}

///|
test "Windows field paste freshness checks revision focus and native epoch" {
  let field = windows_field_test_press(
    windows_field_test_field("abc"),
    @primitives.End,
  )
  let revision = field.revision()
  let pasted = paste_if_current(
    field,
    revision,
    Some(7),
    Some(7),
    true,
    true,
    "!",
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(pasted.document().text() == "abc!")
  assert_true(pasted.can_undo())
  let stale_epoch = paste_if_current(
    field,
    revision,
    Some(7),
    Some(8),
    true,
    true,
    "!",
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(stale_epoch.document() == field.document())
  let stale_revision = paste_if_current(
    field,
    revision + 1,
    Some(7),
    Some(7),
    true,
    true,
    "!",
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(stale_revision.document() == field.document())
  let unfocused = field.with_focus(false).unwrap()
  let stale_focus = paste_if_current(
    unfocused,
    revision,
    Some(7),
    Some(7),
    true,
    false,
    "!",
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(stale_focus.document() == field.document())
}

///|
test "Windows field cut installs only after clipboard write and freshness checks" {
  let initial = windows_field_test_press(
    windows_field_test_field("abc"),
    @primitives.Character("a"),
    modifiers=windows_field_test_shortcut_modifiers(),
  )
  let (_, action) = windows_field_test_handle(
    initial,
    @primitives.KeyPressed(
      key=@primitives.Character("x"),
      modifiers=windows_field_test_shortcut_modifiers(),
      repeat=false,
    ),
  )
  let candidate = match action {
    Some(@text_field.Cut(text~, candidate~)) => {
      assert_eq(text, "abc")
      candidate
    }
    _ => fail("select-all cut should produce an admitted candidate")
  }
  let written = cut_after_write(
    initial,
    candidate,
    Some(5),
    Some(5),
    true,
    true,
    Ok(()),
  )
  assert_eq(written.document().text(), "")
  let stale_epoch = cut_after_write(
    initial,
    candidate,
    Some(5),
    Some(6),
    true,
    true,
    Ok(()),
  )
  assert_true(stale_epoch.document().text() == initial.document().text())
  let lost_focus = cut_after_write(
    initial,
    candidate,
    Some(5),
    Some(5),
    true,
    false,
    Ok(()),
  )
  assert_true(lost_focus.document().text() == initial.document().text())
  let failed_write = cut_after_write(
    initial,
    candidate,
    Some(5),
    Some(5),
    true,
    true,
    Err(
      @diagnostics.FrameworkError::new(@diagnostics.NativeFailure, "clipboard"),
    ),
  )
  assert_true(failed_write.document().text() == initial.document().text())
}

///|
test "Windows Ctrl+X clipboard failure after preedit uses resolved field snapshot" {
  let initial = windows_field_test_press(
    windows_field_test_field("abc"),
    @primitives.Character("a"),
    modifiers=windows_field_test_shortcut_modifiers(),
  )
  let replacement = initial.selection().normalized_range()
  let active = windows_start_composition(
    windows_text_owner(11, 19),
    initial,
    replacement,
  ).unwrap()
  let (preview, active) = windows_update_mark(
    active,
    "かな",
    Some(2),
    [0, 0],
    replacement,
    windows_field_test_measure,
    windows_field_test_admit,
  ).unwrap()
  assert_true(preview.is_composing())
  let cut_shortcut = @primitives.KeyPressed(
    key=@primitives.Character("x"),
    modifiers=windows_field_test_shortcut_modifiers(),
    repeat=false,
  )
  assert_true(windows_resolves_preedit(true, cut_shortcut))
  assert_false(
    windows_resolves_preedit(
      true,
      @primitives.KeyPressed(
        key=@primitives.ArrowLeft,
        modifiers=@primitives.Modifiers::none(),
        repeat=false,
      ),
    ),
  )
  // The event loop resolves the native transaction before Ctrl+X asks for a
  // candidate; the paste/cut rollback base must be that restored snapshot.
  let (resolved_opt, _) = windows_cancel_composition(active).unwrap()
  let resolved = resolved_opt.unwrap()
  let (_, action) = windows_field_test_handle(resolved, cut_shortcut)
  let candidate = match action {
    Some(@text_field.Cut(text~, candidate~)) => {
      assert_eq(text, "abc")
      candidate
    }
    _ => fail("Ctrl+X after resolving preedit should produce a cut")
  }
  let restored = cut_after_write(
    resolved,
    candidate,
    None,
    None,
    true,
    true,
    Err(
      @diagnostics.FrameworkError::new(@diagnostics.NativeFailure, "clipboard"),
    ),
  )
  assert_false(restored.is_composing())
  assert_true(restored.document().text() == initial.document().text())
  assert_true(restored.selection() == initial.selection())
  assert_false(restored.can_undo())
  assert_false(restored.can_redo())
}
