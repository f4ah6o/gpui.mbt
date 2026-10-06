///|
fn ime_test_style(text : String) -> Array[@native.TextSessionStyle] {
  [{ range: @text.TextRange::new(0, text.length()).unwrap(), style: 5, }]
}

///|
test "IME owner preview never replaces committed surrounding and commit records once" {
  let original = owner_history_selected(controller_field())
  let first = ime_preedit(original, "に", Some(1), ime_test_style("に")).unwrap()
  let next = ime_preedit(
    first,
    "にほん",
    Some(3),
    ime_test_style("にほん"),
  ).unwrap()
  assert_eq(next.document().text(), "にほん")
  assert_true(next.committed_document() == original.document())
  assert_true(next.committed_document().selection() == original.selection())
  assert_false(next.can_undo())
  let converted = ime_preedit(next, "日本", Some(0), ime_test_style("日本")).unwrap()
  assert_eq(converted.selection().head(), 0)
  let committed = ime_commit(converted, "日本", None, None).unwrap()
  assert_false(committed.is_composing())
  assert_eq(committed.committed_document().text(), "日本")
  let undone = committed.undo(measure, admit).unwrap()
  assert_true(undone.document() == original.document())
  assert_false(undone.can_undo())
  let redone = undone.redo(measure, admit).unwrap()
  assert_true(redone.document() == committed.document())
}

///|
test "IME empty preedit restores directional selection history without committing deletion" {
  let original = owner_history_selected(controller_field())
  let changed = original.replace_selection("X", measure, admit).unwrap()
  let original = changed.undo(measure, admit).unwrap()
  let preview = ime_preedit(original, "日本", Some(2), []).unwrap()
  let cleared = ime_preedit(preview, "", None, []).unwrap()
  assert_false(cleared.is_composing())
  assert_true(cleared.document() == original.document())
  assert_true(cleared.selection() == original.selection())
  assert_true(cleared.can_redo())
  assert_false(cleared.can_undo())
  // An empty commit is distinct: the restored selection is actually deleted.
  let deleted = ime_commit(cleared, "", None, None).unwrap()
  assert_eq(deleted.document().text(), "")
  assert_true(
    deleted.undo(measure, admit).unwrap().document() == original.document(),
  )
}

///|
test "IME unsupported atomic metadata is typed rejected even on empty commit" {
  let original = owner_history_selected(controller_field())
  let preview = ime_preedit(original, "に", Some(1), []).unwrap()
  let deletion : @native.TextSessionDeletion = {
    index_bytes: -3,
    length_bytes: 3,
  }
  let position : @native.TextSessionPosition = {
    cursor_index_bytes: -3,
    anchor_index_bytes: 0,
  }
  assert_true(
    ime_commit(preview, "", Some(deletion), None) is Err(UnsupportedDeletion),
  )
  assert_true(
    ime_commit(preview, "日本", None, Some(position))
    is Err(UnsupportedPosition),
  )
  assert_eq(preview.document().text(), "に")
  assert_true(preview.committed_document() == original.document())
  assert_false(preview.can_undo())
}

///|
test "IME cursor styling and UTF16 endpoints reject before installing a candidate" {
  let original = owner_history_selected(controller_field())
  assert_true(ime_preedit(original, "日本", None, []) is Err(HiddenCursor))
  assert_true(
    ime_preedit(original, "日本", Some(1), [
      { range: @text.TextRange::new(0, 1).unwrap(), style: 5, },
    ])
    is Err(UnsupportedStyle),
  )
  assert_true(
    ime_preedit(original, "日本", Some(1), [
      { range: @text.TextRange::new(0, 2).unwrap(), style: 4, },
    ])
    is Err(UnsupportedStyle),
  )
  assert_true(
    ime_preedit(original, "😀", Some(1), [])
    is Err(Field(@text_field.InvalidSelection)),
  )
  assert_true(
    ime_preedit(original, "a\u{301}", Some(1), [])
    is Err(Field(@text_field.InvalidSelection)),
  )
  assert_true(
    ime_preedit(original, "日本", Some(3), [])
    is Err(Field(@text_field.InvalidSelection)),
  )
  assert_false(original.is_composing())
}

///|
test "IME target epochs proxy generations and FIFO sequence fence old records" {
  let window = @platform.WindowId::new(1)
  let owner = {
    ..ime_owner(7),
    entered: true,
    seat: 13L,
    proxy_generation: 3,
    sequence: 20L,
  }
  let target : @native.TextSessionTarget = {
    window,
    epoch: 7,
    seat: 13L,
    proxy_generation: 3,
    sequence: 21L,
    serial: 8,
  }
  assert_true(ime_target_current(owner, window, target))
  // Shared or older issued serials remain legitimate; native owns the floor.
  assert_true(ime_target_current(owner, window, { ..target, serial: 7, }))
  assert_false(ime_target_current(owner, window, { ..target, epoch: 6, }))
  assert_false(ime_target_current(owner, window, { ..target, seat: 12L, }))
  assert_false(
    ime_target_current(owner, window, { ..target, proxy_generation: 2, }),
  )
  assert_false(ime_target_current(owner, window, { ..target, sequence: 20L, }))
  assert_false(ime_target_current(owner, window, { ..target, serial: 0, }))
  assert_false(ime_target_current(owner, @platform.WindowId::new(2), target))
  let replacement = ime_owner(8)
  assert_false(ime_target_current(replacement, window, target, lifecycle=true))
  assert_false(ime_target_current(ime_owner(7), window, target))
  assert_true(ime_target_current(ime_owner(7), window, target, lifecycle=true))
}

///|
test "IME raw command allowlist never creates text from ordinary keysyms" {
  let plain = @primitives.Modifiers::none()
  let control = @primitives.Modifiers::new(
    shift=false,
    control=true,
    alt=false,
    meta=false,
  )
  assert_true(ime_command_key(0x61, None, plain) is None)
  assert_true(ime_command_key(0x20, Some(@primitives.Space), plain) is None)
  assert_true(
    ime_command_key(0x61, None, control) is Some(@primitives.Character("a")),
  )
  assert_true(
    ime_command_key(0x7a, None, control) is Some(@primitives.Character("z")),
  )
  assert_true(ime_command_key(0x62, None, control) is None)
  assert_true(
    ime_command_key(0xff1b, Some(@primitives.Escape), plain)
    is Some(@primitives.Escape),
  )
}

///|
test "IME caret matches surface paint with scroll inset origin and outward rounding" {
  for text in ["jJ", "ÁA\u{301}", "Wide 日本 ".repeat(12)] {
    let field = make_field(
        text,
        @primitives.Rect::new(32.25, 28.5, 180.0, 44.0).unwrap(),
      )
      .unwrap()
      .with_focus(true)
      .unwrap()
    let field = change(field, key_event(@primitives.End)).unwrap()
    let raw = field.caret_rect().unwrap()
    let (_, items) = field.paint_items(100, 7).unwrap()
    match items[items.length() - 1] {
      @scene.QuadItem(bounds~, ..) => assert_true(bounds == raw)
      _ => fail("painted caret missing")
    }
    let native = ime_caret_rect(field).unwrap()
    assert_eq(native.left(), raw.left().floor())
    assert_eq(native.top(), raw.top().floor())
    assert_eq(native.right(), raw.right().ceil())
    assert_eq(native.bottom(), raw.bottom().ceil())
    assert_true(native.size().width() >= 1.0)
    assert_true(native.size().height() >= 1.0)
    assert_true(native.left() < field.bounds().right())
  }
}

///|
test "IME observer reads exact committed preview marked caret and history without mutation" {
  let original = owner_history_selected(controller_field())
  let preview = ime_preedit(original, "にほん", Some(3), []).unwrap()
  let document = preview.document()
  let revision = preview.revision()
  let line = ime_observer_line(4, preview, Some(ime_owner(8)), 0)
  assert_true(line.has_prefix("GPUI_FIELD_IME_STATE "))
  let parsed = @json.parse(line.strip_prefix("GPUI_FIELD_IME_STATE ").unwrap())
  match parsed {
    Object(value) => {
      assert_true(
        value.get("committed") == Some(original.document().text().to_json()),
      )
      assert_true(value.get("preview") == Some("にほん".to_json()))
      assert_true(value.get("commits") == Some((0).to_json()))
      assert_true(value.get("marked") == Some({ "start": 0, "end": 3 }))
      assert_true(value.get("epoch") == Some((8).to_json()))
    }
    _ => fail("IME observer schema")
  }
  assert_true(preview.document() == document)
  assert_eq(preview.revision(), revision)
  assert_false(preview.can_undo())
}

///|
test "IME rejected presentation restores complete history then cancels and fences its target" {
  let original = owner_history_selected(controller_field())
  let redo_target = original.replace_selection("X", measure, admit).unwrap()
  let original = redo_target.undo(measure, admit).unwrap()
  let submitted = ime_preedit(original, "に", Some(1), []).unwrap()
  let pending = ime_preedit(submitted, "にほん", Some(3), []).unwrap()
  let pending = ime_commit(pending, "日本", None, None).unwrap()
  assert_true(pending.can_undo())
  assert_false(pending.can_redo())
  let current = pending
    .with_bounds(@primitives.Rect::new(24.0, 28.0, 300.0, 44.0).unwrap())
    .unwrap()
  let window = @platform.WindowId::new(1)
  let old = {
    ..ime_owner(5),
    entered: true,
    seat: 12L,
    proxy_generation: 3,
    sequence: 100L,
  }
  let old_left : @native.TextSessionTarget = {
    window,
    epoch: 5,
    seat: 12L,
    proxy_generation: 3,
    sequence: 101L,
    serial: 0,
  }
  for
    code in [
      @diagnostics.InvalidInput,
      @diagnostics.UnsupportedCapability,
      @diagnostics.ResourceExhausted,
    ] {
    assert_true(
      classify_field_frame(Err(controller_error(code))) is RejectPending,
    )
    let restored = restore_rejected_ime_field(submitted, current).unwrap()
    assert_true(restored.document() == original.document())
    assert_true(restored.committed_document() == original.document())
    assert_true(restored.selection() == original.selection())
    assert_true(restored.bounds() == current.bounds())
    assert_true(restored.is_focused())
    assert_false(restored.is_composing())
    assert_false(restored.can_undo())
    assert_true(restored.can_redo())
    assert_true(
      restored.redo(measure, admit).unwrap().document() ==
      redo_target.document(),
    )
    let new = ime_owner_after_update(old, 6)
    assert_eq(new.epoch, 6)
    assert_false(new.entered)
    assert_eq(new.seat, 0L)
    assert_eq(new.proxy_generation, 0)
    assert_eq(new.sequence, 0L)
    assert_false(ime_target_current(new, window, old_left, lifecycle=true))
    let new_preedit = { ..old_left, epoch: 6, serial: 10, }
    assert_false(ime_target_current(new, window, new_preedit))
    let entered = {
      ..new,
      entered: true,
      seat: 12L,
      proxy_generation: 3,
      sequence: 100L,
    }
    assert_true(ime_target_current(entered, window, new_preedit))
    let retry = ime_preedit(restored, "日本", Some(2), []).unwrap()
    let accepted = ime_commit(retry, "日本", None, None).unwrap()
    let undone = accepted.undo(measure, admit).unwrap()
    assert_true(undone.document() == original.document())
    assert_false(undone.can_undo())
    // Failed candidates and previews did not make their own undo records.
    assert_true(
      undone.redo(measure, admit).unwrap().document() == accepted.document(),
    )
  }
  let ordinary_ack = ime_owner_after_update(old, 5)
  assert_eq(ordinary_ack.sequence, old.sequence)
  assert_true(ordinary_ack.entered)
}

///|
test "IME caret rejects out of signed native range before integer conversion" {
  for origin in [2147483647.0, -2147483657.0] {
    let field = make_field(
        "jJ",
        @primitives.Rect::new(origin, 28.0, 180.0, 44.0).unwrap(),
      )
      .unwrap()
      .with_focus(true)
      .unwrap()
    assert_true(ime_caret_rect(field) is Err(@text_field.InvalidBounds))
  }
}

///|
test "IME underline endpoints cannot split a grapheme joined across the original prefix" {
  let original = make_field(
      "ba",
      @primitives.Rect::new(32.0, 28.0, 180.0, 44.0).unwrap(),
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let original = change(original, key_event(@primitives.ArrowRight)).unwrap()
  assert_eq(original.selection().head(), 1)
  assert_true(
    ime_preedit(original, "\u{301}", Some(1), [])
    is Err(Field(@text_field.InvalidSelection)),
  )
  assert_eq(original.document().text(), "ba")
  assert_false(original.is_composing())
  assert_false(original.can_undo())
}
