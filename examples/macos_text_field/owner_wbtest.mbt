///|
fn owner_test_rect() -> @primitives.Rect {
  @primitives.Rect::new(24.0, 32.0, 320.0, 48.0).unwrap()
}

///|
fn owner_test_modifiers(
  shift? : Bool = false,
  control? : Bool = false,
  alt? : Bool = false,
  meta? : Bool = false,
) -> @primitives.Modifiers {
  @primitives.Modifiers::new(shift~, control~, alt~, meta~)
}

///|
fn mac_owner_coretext_tests_available() -> Bool {
  match @macos_text.require_grayscale_raster() {
    Ok(_) => true
    Err(@macos_text.UnsupportedPlatform) => {
      println(
        "GPUI_MACOS_FIELD_TEST_SKIP CoreText owner tests require macOS; unsupported provider was typed.",
      )
      false
    }
    Err(_) => false
  }
}

///|
test "Mac field provider is available or reports the typed unsupported platform error" {
  let document = @text.TextDocument::new("platform probe").unwrap()
  match @macos_text.require_grayscale_raster() {
    Ok(_) =>
      assert_true(
        @macos_text.measure(document, FIELD_FONT_FAMILY, FIELD_FONT_SIZE)
        is Ok(_),
      )
    Err(@macos_text.UnsupportedPlatform) =>
      assert_true(
        @macos_text.measure(document, FIELD_FONT_FAMILY, FIELD_FONT_SIZE)
        is Err(@macos_text.UnsupportedPlatform),
      )
    Err(_) => fail("CoreText provider failed with an unexpected typed error")
  }
}

///|
test "Mac owner accepts only current window host epoch session and newer revision-bound sequence" {
  let window = @platform.WindowId::new(4)
  let owner = mac_text_owner(window, 31L, 7, 12)
  assert_true(owner_batch_current(owner, window, 31L, 7, 1L, 12L, 12))
  assert_false(
    owner_batch_current(owner, @platform.WindowId::new(5), 31L, 7, 1L, 12L, 12),
  )
  assert_false(owner_batch_current(owner, window, 30L, 7, 1L, 12L, 12))
  assert_false(owner_batch_current(owner, window, 31L, 6, 1L, 12L, 12))
  assert_false(owner_batch_current(owner, window, 31L, 7, 0L, 12L, 12))
  assert_false(owner_batch_current(owner, window, 31L, 7, 1L, 11L, 12))
  assert_false(owner_batch_current(owner, window, 31L, 7, 1L, 12L, 13))
  let acknowledged = owner_ack(owner, 1L, 13)
  assert_false(owner_batch_current(acknowledged, window, 31L, 7, 1L, 12L, 13))
  assert_true(owner_batch_current(acknowledged, window, 31L, 7, 2L, 13L, 13))
  let rearmed = owner_rearmed(acknowledged, 8, 14)
  assert_false(owner_batch_current(rearmed, window, 31L, 7, 3L, 13L, 13))
  assert_true(owner_batch_current(rearmed, window, 31L, 8, 1L, 14L, 14))
  assert_false(
    owner_batch_current(owner_ended(rearmed), window, 31L, 8, 1L, 14L, 14),
  )
}

///|
test "successful begin and rearm accept Preedit without a synthetic Entered batch" {
  if mac_owner_coretext_tests_available() {
    let window = @platform.WindowId::new(22)
    let field = make_field("abc", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let owner = mac_text_owner(window, 41L, 7, field.revision())
    let first_batch : @macos.EditorBatch = {
      target: {
        window,
        host_epoch: 41L,
        epoch: 7,
        sequence: 1L,
        owner_revision: field.revision().to_int64(),
      },
      events: [
        @macos.Preedit(
          text="に",
          fallback="",
          cursor_utf16=Some(1),
          styles=[],
          replacement_range=None,
        ),
      ],
    }
    assert_true(mac_target_current(owner, first_batch, field))
    let preview = mac_apply_batch(field, owner, first_batch, 640.0, 240.0).unwrap()
    assert_true(preview.field.is_composing())
    assert_eq(preview.field.document().text(), "abcに")

    // A successful native cancel/external update establishes the new epoch.
    let rearmed = owner_rearmed(preview.owner, 8, preview.field.revision())
    let next_batch : @macos.EditorBatch = {
      target: {
        window,
        host_epoch: 41L,
        epoch: 8,
        sequence: 1L,
        owner_revision: preview.field.revision().to_int64(),
      },
      events: [
        @macos.Preedit(
          text="日本",
          fallback="",
          cursor_utf16=Some(2),
          styles=[],
          replacement_range=None,
        ),
      ],
    }
    assert_true(mac_target_current(rearmed, next_batch, preview.field))
    let next_preview = mac_apply_batch(
      preview.field,
      rearmed,
      next_batch,
      640.0,
      240.0,
    ).unwrap()
    assert_eq(next_preview.field.document().text(), "abc日本")
  }
}

///|
test "IME startup waits for owner focus mode and a real native focus transition" {
  assert_false(mac_ime_begin_ready(true, true, true, false))
  assert_false(mac_ime_begin_ready(true, false, true, true))
  assert_false(mac_ime_begin_ready(true, true, false, true))
  assert_false(mac_ime_begin_ready(false, true, true, true))
  assert_true(mac_ime_begin_ready(true, true, true, true))
}

///|
test "Mac editor printable physical keys never synthesize committed text" {
  let none = owner_test_modifiers()
  let command = owner_test_modifiers(meta=true)
  assert_true(
    mac_editor_command_key(Some(@primitives.Character("q")), none) is None,
  )
  assert_true(mac_editor_command_key(Some(@primitives.Space), none) is None)
  assert_true(mac_editor_command_key(None, none) is None)
  assert_true(
    mac_editor_command_key(Some(@primitives.Character("q")), command) is None,
  )
  assert_true(
    mac_editor_command_key(Some(@primitives.Character("a")), command)
    is Some(@primitives.Character("a")),
  )
  assert_true(
    mac_editor_command_key(Some(@primitives.Character("C")), command)
    is Some(@primitives.Character("c")),
  )
  assert_true(
    mac_editor_command_key(Some(@primitives.Character("x")), command)
    is Some(@primitives.Character("x")),
  )
  assert_true(
    mac_editor_command_key(Some(@primitives.Character("v")), command)
    is Some(@primitives.Character("v")),
  )
  assert_true(
    mac_editor_command_key(Some(@primitives.Character("z")), command)
    is Some(@primitives.Character("z")),
  )
  assert_true(
    mac_editor_command_key(
      Some(@primitives.Character("z")),
      owner_test_modifiers(shift=true, meta=true),
    )
    is Some(@primitives.Character("z")),
  )
  assert_true(
    mac_editor_command_key(
      Some(@primitives.ArrowLeft),
      owner_test_modifiers(shift=true),
    )
    is Some(@primitives.ArrowLeft),
  )
  assert_true(
    mac_editor_command_key(
      Some(@primitives.ArrowLeft),
      owner_test_modifiers(alt=true),
    )
    is None,
  )
}

///|
test "Mac physical press and release pair is forwarded or dropped together" {
  let window = @platform.WindowId::new(9)
  let owner = mac_text_owner(window, 2L, 5, 0)
  let (printable, printable_press) = mac_forwarded_press(
    owner,
    15,
    Some(@primitives.Character("r")),
    owner_test_modifiers(),
  )
  assert_true(printable_press is None)
  let (_, printable_release) = mac_forwarded_release(printable, 15)
  assert_true(printable_release is None)
  let (command, first_press) = mac_forwarded_press(
    owner,
    0,
    Some(@primitives.Character("a")),
    owner_test_modifiers(meta=true),
  )
  match first_press {
    Some(
      @primitives.KeyPressed(
        key=@primitives.Character("a"),
        modifiers~,
        repeat~
      )
    ) => {
      assert_true(modifiers.meta())
      assert_false(repeat)
    }
    _ => fail("Command+A must be forwarded exactly once")
  }
  let (repeated, repeat_press) = mac_forwarded_press(
    command,
    0,
    Some(@primitives.Character("a")),
    owner_test_modifiers(meta=true),
  )
  match repeat_press {
    Some(
      @primitives.KeyPressed(
        key=@primitives.Character("a"),
        modifiers~,
        repeat~
      )
    ) => {
      assert_true(modifiers.meta())
      assert_true(repeat)
    }
    _ => fail("a repeated command press must preserve repeat state")
  }
  let (released, release) = mac_forwarded_release(repeated, 0)
  match release {
    Some(@primitives.KeyReleased(key=@primitives.Character("a"), modifiers~)) =>
      assert_true(modifiers.meta())
    _ => fail("the release must pair with the forwarded press")
  }
  assert_eq(released.forwarded_keys.length(), 0)
  assert_true(mac_forwarded_release(released, 0).1 is None)
}

///|
test "IME cancellation batch ACK preserves the Escape press release pair" {
  if mac_owner_coretext_tests_available() {
    let window = @platform.WindowId::new(12)
    let original = make_field("abc", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let preview = mac_apply_preedit(original, "に", "", Some(1), [], None).unwrap()
    let owner = mac_text_owner(window, 31L, 7, preview.revision())
    let modifiers = owner_test_modifiers()
    let cancel_batch : @macos.EditorBatch = {
      target: {
        window,
        host_epoch: 31L,
        epoch: 7,
        sequence: 1L,
        owner_revision: preview.revision().to_int64(),
      },
      events: [
        @macos.ForwardedPressed(
          key_code=53,
          key=Some(@primitives.Escape),
          modifiers~,
        ),
        @macos.Cancelled,
      ],
    }
    let cancelled = mac_apply_batch(preview, owner, cancel_batch, 640.0, 240.0).unwrap()
    assert_false(cancelled.field.is_composing())
    assert_eq(cancelled.field.committed_document().text(), "abc")
    assert_false(cancelled.external_edit)
    assert_eq(cancelled.commits, 0)
    assert_eq(cancelled.owner.forwarded_keys.length(), 1)

    let acknowledged = owner_ack(
      cancelled.owner,
      1L,
      cancelled.field.revision(),
    )
    let release_batch : @macos.EditorBatch = {
      target: {
        window,
        host_epoch: 31L,
        epoch: 7,
        sequence: 2L,
        owner_revision: cancelled.field.revision().to_int64(),
      },
      events: [
        @macos.ForwardedReleased(
          key_code=53,
          key=Some(@primitives.Escape),
          modifiers~,
        ),
      ],
    }
    let released = mac_apply_batch(
      cancelled.field,
      acknowledged,
      release_batch,
      640.0,
      240.0,
    ).unwrap()
    assert_false(released.external_edit)
    assert_eq(released.owner.forwarded_keys.length(), 0)
    assert_eq(released.field.committed_document().text(), "abc")
  }
}

///|
test "active Mac IME drops every raw keyboard record because batches own key dispatch" {
  let none = owner_test_modifiers()
  assert_false(
    mac_platform_input_allowed(@primitives.TextInput(text="日本"), true),
  )
  assert_false(
    mac_platform_input_allowed(
      @primitives.KeyPressed(
        key=@primitives.Character("j"),
        modifiers=none,
        repeat=false,
      ),
      true,
    ),
  )
  assert_false(
    mac_platform_input_allowed(
      @primitives.KeyPressed(
        key=@primitives.Character("a"),
        modifiers=owner_test_modifiers(meta=true),
        repeat=false,
      ),
      true,
    ),
  )
  assert_false(
    mac_platform_input_allowed(
      @primitives.KeyPressed(
        key=@primitives.ArrowLeft,
        modifiers=none,
        repeat=false,
      ),
      true,
    ),
  )
  assert_false(
    mac_platform_input_allowed(
      @primitives.KeyReleased(key=@primitives.ArrowLeft, modifiers=none),
      true,
    ),
  )
  assert_true(
    mac_platform_input_allowed(@primitives.TextInput(text="日本"), false),
  )
}

///|
test "Mac replacement metadata accepts only the current selection or visible marked range" {
  if mac_owner_coretext_tests_available() {
    let start = make_field("abcd", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let selected = route_input(
        start,
        @primitives.KeyPressed(
          key=@primitives.ArrowLeft,
          modifiers=owner_test_modifiers(shift=true),
          repeat=false,
        ),
        640.0,
        240.0,
      ).unwrap().0
    let selected_range = selected.selection().normalized_range()
    assert_true(mac_replacement_range_supported(selected, Some(selected_range)))
    assert_false(
      mac_replacement_range_supported(
        selected,
        Some(@text.TextRange::new(0, 1).unwrap()),
      ),
    )
    assert_true(mac_replacement_range_supported(selected, None))

    let preview = selected
      .update_composition(
        "に",
        @text.TextSelection::new(1, 1).unwrap(),
        measure,
        admit,
      )
      .unwrap()
    let marked = preview.marked_range().unwrap()
    assert_true(mac_replacement_range_supported(preview, Some(marked)))
    assert_false(
      mac_replacement_range_supported(
        preview,
        Some(@text.TextRange::new(0, 1).unwrap()),
      ),
    )
    assert_true(mac_replacement_range_supported(preview, None))
  }
}

///|
test "accepted-frame state observer is read-only and carries exact integer caret geometry" {
  if mac_owner_coretext_tests_available() {
    let field = make_field("Hello 日本", owner_test_rect()).unwrap()
    let field = field.with_focus(true).unwrap()
    let revision = field.revision()
    let document = field.document()
    let value = state_json(3, field, 17, 1)
    let parsed = @json.parse(value)
    match parsed {
      Object(object) => {
        assert_true(object.get("presentation") == Some((3).to_json()))
        assert_true(object.get("text") == Some("Hello 日本".to_json()))
        assert_true(object.get("committed") == Some("Hello 日本".to_json()))
        assert_true(object.get("revision") == Some(revision.to_json()))
        assert_true(object.get("session_epoch") == Some((17).to_json()))
        assert_true(object.get("commit_count") == Some((1).to_json()))
        assert_true(object.get("caret") is Some(Object(_)))
        assert_true(object.get("field_bounds") is Some(Object(_)))
        assert_eq(object.length(), 16)
      }
      _ => fail("observer emitted a non-object JSON record")
    }
    assert_true(field.document() == document)
    assert_eq(field.revision(), revision)
    assert_true(field.is_focused())
    assert_false(state_observer_enabled(None))
    assert_true(state_observer_enabled(Some("1")))
    assert_false(state_observer_enabled(Some("true")))
  }
}

///|
test "Mac empty preedit restores selection while empty commit deletes it" {
  if mac_owner_coretext_tests_available() {
    let focused = make_field("abcd", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let selected = route_input(
        focused,
        @primitives.KeyPressed(
          key=@primitives.Character("a"),
          modifiers=owner_test_modifiers(meta=true),
          repeat=false,
        ),
        640.0,
        240.0,
      ).unwrap().0
    let preview = mac_apply_preedit(selected, "に", "", Some(1), [], None).unwrap()
    assert_true(preview.is_composing())
    assert_eq(preview.committed_document().text(), "abcd")
    let restored = mac_apply_preedit(preview, "", "", None, [], None).unwrap()
    assert_false(restored.is_composing())
    assert_eq(restored.document().text(), "abcd")
    assert_eq(restored.selection().anchor(), selected.selection().anchor())
    assert_eq(restored.selection().head(), selected.selection().head())

    let preview = mac_apply_preedit(selected, "に", "", Some(1), [], None).unwrap()
    let deleted = mac_apply_commit(preview, "", None).unwrap()
    assert_false(deleted.is_composing())
    assert_eq(deleted.document().text(), "")
    assert_true(deleted.can_undo())
  }
}

///|
test "Mac owner rejects reconversion and fallback metadata without changing the field" {
  if mac_owner_coretext_tests_available() {
    let field = make_field("abcd", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let before_revision = field.revision()
    let reconversion = mac_apply_commit(
      field,
      "x",
      Some(@text.TextRange::new(1, 3).unwrap()),
    )
    assert_true(reconversion is Err(UnsupportedReconversion))
    assert_eq(field.document().text(), "abcd")
    assert_eq(field.revision(), before_revision)

    let fallback = mac_apply_preedit(field, "に", "nihongo", Some(1), [], None)
    assert_true(fallback is Err(UnsupportedInput))
    assert_eq(field.document().text(), "abcd")
    assert_eq(field.revision(), before_revision)
  }
}

///|
test "Mac underline validation uses full-span UTF-16 endpoints" {
  assert_true(
    mac_preedit_styles_supported("😀", [
      { range: @text.TextRange::new(0, 2).unwrap(), style: 5, },
    ]),
  )
  assert_false(
    mac_preedit_styles_supported("😀", [
      { range: @text.TextRange::new(0, 1).unwrap(), style: 5, },
    ]),
  )
  assert_false(
    mac_preedit_styles_supported("abc", [
      { range: @text.TextRange::new(0, 3).unwrap(), style: 255, },
    ]),
  )
}

///|
test "Mac commit ledger counts only a commit in an accepted frame" {
  let initial = mac_commit_ledger()
  let pending = mac_stage_commits(initial, 2)
  assert_eq(pending.accepted, 0)
  assert_eq(pending.pending, 2)
  let rejected = mac_reject_commits(pending)
  assert_eq(rejected.accepted, 0)
  assert_eq(rejected.pending, 0)
  let retry = mac_accept_commits(mac_stage_commits(rejected, 1))
  assert_eq(retry.accepted, 1)
  assert_eq(retry.pending, 0)
}

///|
test "Mac application exit routes globally even when its event has no window token" {
  let nil_window = @platform.Event::new(
    @platform.WindowId::new(0),
    1L,
    1.0,
    @platform.ExitRequested,
  )
  let wake = @platform.Event::new(
    @platform.WindowId::new(0),
    2L,
    1.0,
    @platform.Wake,
  )
  assert_true(mac_global_exit_requested(nil_window))
  assert_false(mac_global_exit_requested(wake))
}

///|
test "Mac rejected frame restores shown text and history then accepts recovery" {
  if mac_owner_coretext_tests_available() {
    let shown = make_field("abcd", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let shown = route_input(
        shown,
        @primitives.KeyPressed(
          key=@primitives.Character("a"),
          modifiers=owner_test_modifiers(meta=true),
          repeat=false,
        ),
        640.0,
        240.0,
      ).unwrap().0
    let pending = mac_apply_commit(shown, "日本", None).unwrap()
    let ledger = mac_stage_commits(mac_commit_ledger(), 1)
    assert_eq(pending.document().text(), "日本")
    assert_eq(ledger.accepted, 0)
    assert_eq(ledger.pending, 1)

    let rejected_error = @diagnostics.FrameworkError::new(
      @diagnostics.InvalidInput,
      "mac_field_test_reject",
    )
    assert_true(classify_field_frame(Err(rejected_error)) is RejectPending)
    let restored = mac_restore_rejected_field(shown, pending).unwrap()
    let rejected_ledger = mac_reject_commits(ledger)
    assert_eq(restored.document().text(), shown.document().text())
    assert_eq(restored.selection().anchor(), shown.selection().anchor())
    assert_eq(restored.selection().head(), shown.selection().head())
    assert_true(restored.is_focused())
    assert_false(restored.is_composing())
    assert_eq(restored.can_undo(), shown.can_undo())
    assert_eq(restored.can_redo(), shown.can_redo())
    assert_eq(rejected_ledger.accepted, 0)
    assert_eq(rejected_ledger.pending, 0)
    assert_true(mac_direct_rearm_is_safe(false, true, restored, shown))

    let recovered = restored.replace_selection("再", measure, admit).unwrap()
    let accepted_ledger = mac_accept_commits(
      mac_stage_commits(rejected_ledger, 1),
    )
    assert_eq(accepted_ledger.accepted, 1)
    assert_eq(accepted_ledger.pending, 0)
    assert_eq(recovered.document().text(), "再")
    assert_true(
      recovered.undo(measure, admit).unwrap().document() == restored.document(),
    )
  }
}

///|
test "Mac direct commit input rearms immediately only for a visible accepted rollback" {
  if mac_owner_coretext_tests_available() {
    let shown = make_field("plain", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let same = mac_restore_rejected_field(shown, shown).unwrap()
    assert_true(mac_direct_rearm_is_safe(false, true, same, shown))
    assert_false(mac_direct_rearm_is_safe(false, false, same, shown))
    assert_false(mac_direct_rearm_is_safe(true, true, same, shown))
    let moved = same
      .with_bounds(@primitives.Rect::new(28.0, 32.0, 320.0, 48.0).unwrap())
      .unwrap()
    assert_false(mac_direct_rearm_is_safe(false, true, moved, shown))
  }
}
