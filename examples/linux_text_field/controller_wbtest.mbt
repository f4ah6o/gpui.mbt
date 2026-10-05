///|
fn controller_error(
  code : @diagnostics.ErrorCode,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(code, "controller_test")
}

///|
fn controller_field() -> @text_field.TextField {
  make_field(
    "Hi 日本",
    @primitives.Rect::new(32.0, 28.0, 180.0, 44.0).unwrap(),
  )
  .unwrap()
  .with_focus(true)
  .unwrap()
}

///|
// Synthesize a scene-space click from copied metrics, then route it through
// the same input and Pango hit-test callbacks used by the running example.
fn controller_click_caret(
  field : @text_field.TextField,
  offset : Int,
  shift? : Bool = false,
) -> @text_field.TextField {
  let measurement = field.measurement()
  let caret = measurement.caret_at(offset).unwrap().strong()
  let (text_origin, _) = @text_field.scene_text_run_geometry(measurement).unwrap()
  let content = field.content_bounds()
  let x = content.left() -
    field.scroll_offset() +
    text_origin.x() +
    caret.left()
  let y = content.top() +
    text_origin.y() +
    caret.top() +
    caret.size().height() / 2.0
  let point = @primitives.Point::new(x, y).unwrap()
  let modifiers = @primitives.Modifiers::new(
    shift~,
    control=false,
    alt=false,
    meta=false,
  )
  let (clicked, _) = field
    .handle_input(
      @primitives.PointerButtonPressed(
        position=point,
        button=@primitives.Primary,
        modifiers~,
      ),
      measure,
      admit,
      hit,
    )
    .unwrap()
  clicked
}

///|
fn controller_assert_painted_caret(
  field : @text_field.TextField,
  offset : Int,
) -> Unit raise {
  let measurement = field.measurement()
  let caret = measurement.caret_at(offset).unwrap().strong()
  let (text_origin, _) = @text_field.scene_text_run_geometry(measurement).unwrap()
  let content = field.content_bounds()
  let expected_left = content.left() -
    field.scroll_offset() +
    text_origin.x() +
    caret.left()
  let expected_top = content.top() + text_origin.y() + caret.top()
  let (_, items) = field.paint_items(100, 7).unwrap()
  match items[items.length() - 1] {
    @scene.QuadItem(bounds~, ..) => {
      assert_eq(bounds.left(), expected_left)
      assert_eq(bounds.top(), expected_top)
      assert_eq(bounds.size().width(), 1.0)
      assert_eq(bounds.size().height(), caret.size().height())
    }
    _ => abort("real-font caret fixture")
  }
}

///|
fn controller_assert_painted_selection(
  field : @text_field.TextField,
) -> Unit raise {
  let measurement = field.measurement()
  let selection = field.selection()
  let anchor = measurement.caret_at(selection.anchor()).unwrap().strong()
  let head = measurement.caret_at(selection.head()).unwrap().strong()
  let (text_origin, _) = @text_field.scene_text_run_geometry(measurement).unwrap()
  let content = field.content_bounds()
  let left = if anchor.left() < head.left() {
    anchor.left()
  } else {
    head.left()
  }
  let right = if anchor.left() > head.left() {
    anchor.left()
  } else {
    head.left()
  }
  let expected_left = content.left() -
    field.scroll_offset() +
    text_origin.x() +
    left
  let expected_top = content.top() +
    text_origin.y() +
    measurement.logical_rect().top()
  let (_, items) = field.paint_items(100, 7).unwrap()
  match items[5] {
    @scene.QuadItem(bounds~, ..) => {
      assert_eq(bounds.left(), expected_left)
      assert_eq(bounds.top(), expected_top)
      assert_eq(bounds.size().width(), right - left)
      assert_eq(
        bounds.size().height(),
        measurement.logical_rect().size().height(),
      )
    }
    _ => abort("real-font selection fixture")
  }
}

///|
test "real sans fallback has unequal in-line carets and complete selection" {
  let field = controller_field()
  let measurement = field.measurement()
  assert_eq(measurement.line_count(), 1)
  assert_eq(measurement.unknown_glyph_count(), 0)
  let latin = measurement.caret_at(0).unwrap().strong()
  let japanese = measurement.caret_at(4).unwrap().strong()
  assert_true(latin.top() != japanese.top())
  assert_true(latin.size().height() != japanese.size().height())
  let end = change(field, key_event(@primitives.End)).unwrap()
  let selected = change(end, key_event(@primitives.Home, shift=true)).unwrap()
  let (_, items) = selected.paint_items(100, 7).unwrap()
  match items[5] {
    @scene.QuadItem(bounds~, ..) => {
      assert_eq(bounds.top(), 32.0)
      assert_eq(
        bounds.size().height(),
        measurement.logical_rect().size().height(),
      )
    }
    _ => abort("selection fixture")
  }
}

///|
test "real negative bearings use shared rounded origin without text mutation" {
  for value in ["j", "J", "Á", "é", "a\u{301}"] {
    let document = @text.TextDocument::new(value).unwrap()
    let measurement = measure(document).unwrap()
    assert_true(
      measurement.ink_rect().left() < 0.0 || measurement.ink_rect().top() < 0.0,
    )
    let field = make_field(
      value,
      @primitives.Rect::new(32.0, 28.0, 180.0, 44.0).unwrap(),
    ).unwrap()
    let (origin, bounds) = @text_field.scene_text_run_geometry(
      field.measurement(),
    ).unwrap()
    assert_true(origin.x() >= 0.0 && origin.y() >= 0.0)
    assert_true(origin.x() + measurement.ink_rect().left() >= 0.0)
    assert_true(origin.y() + measurement.ink_rect().top() >= 0.0)
    assert_true(origin.x() + measurement.ink_rect().right() <= bounds.right())
    assert_true(origin.y() + measurement.ink_rect().bottom() <= bounds.bottom())
    assert_eq(field.document().text(), value)
    let (_, items) = field.paint_items(100, 7).unwrap()
    assert_true(
      items[5] is @scene.TextRunItem(text_origin~, ..) && text_origin == origin,
    )
  }
}

///|
test "real sans negative-bearing origin maps start and accent cursor-stop hits" {
  let value = "jÁa\u{301}"
  let initial = make_field(
    value,
    @primitives.Rect::new(32.0, 28.0, 180.0, 44.0).unwrap(),
  ).unwrap()
  let measurement = initial.measurement()
  let origin = @text_field.scene_text_run_geometry(measurement).unwrap().0
  assert_true(measurement.ink_rect().left() < 0.0)
  assert_true(origin.x() > 0.0)
  assert_true(measurement.caret_at(0).unwrap().is_cursor_position())
  assert_true(measurement.caret_at(2).unwrap().is_cursor_position())
  assert_false(measurement.caret_at(3).unwrap().is_cursor_position())
  assert_true(measurement.caret_at(4).unwrap().is_cursor_position())

  // At the negative-bearing start, the viewport coordinate includes the
  // checked run inset. The real Pango callback must invert it back to x=0.
  let start = controller_click_caret(initial, 0)
  assert_true(start.is_focused())
  assert_eq(start.selection().head(), 0)
  controller_assert_painted_caret(start, 0)

  // Á is one composed cursor-stop interval; a+acute has no stop before the
  // combining mark at UTF-16 3, but its end is valid at offset 4.
  let after_composed = controller_click_caret(start, 2, shift=true)
  assert_true(
    after_composed.selection() == @text.TextSelection::new(0, 2).unwrap(),
  )
  controller_assert_painted_selection(after_composed)
  let after_decomposed = controller_click_caret(after_composed, 4, shift=true)
  assert_true(
    after_decomposed.selection() == @text.TextSelection::new(0, 4).unwrap(),
  )
  controller_assert_painted_selection(after_decomposed)
  controller_assert_painted_caret(after_decomposed, 4)
  assert_eq(after_decomposed.document().text(), value)
}

///|
test "real sans scrolled Pango hit mapping retains run origin and accent stops" {
  let prefix = "Wide ".repeat(20)
  let value = prefix + "jÁa\u{301}"
  let bounds = @primitives.Rect::new(32.0, 28.0, 180.0, 44.0).unwrap()
  let initial = make_field(value, bounds).unwrap().with_focus(true).unwrap()
  let at_end = change(initial, key_event(@primitives.End)).unwrap()
  let prefix_utf16 = @text.TextDocument::new(prefix).unwrap().utf16_length()
  let end_offset = prefix_utf16 + 4
  assert_true(at_end.scroll_offset() > 0.0)
  assert_eq(at_end.selection().head(), end_offset)
  controller_assert_painted_caret(at_end, end_offset)

  // This suffix stop remains visible after scrolling. Its click goes through
  // TextField::handle_input and the example's real sans/18px Pango hit callback.
  let target = prefix_utf16 + 2
  assert_true(
    at_end.measurement().caret_at(target).unwrap().is_cursor_position(),
  )
  let selected = controller_click_caret(at_end, target, shift=true)
  assert_true(
    selected.selection() ==
    @text.TextSelection::new(end_offset, target).unwrap(),
  )
  assert_true(selected.scroll_offset() > 0.0)
  controller_assert_painted_selection(selected)
  controller_assert_painted_caret(selected, target)
  assert_eq(selected.document().text(), value)
}

///|
test "cut candidate installs only after successful clipboard write" {
  let field = change(controller_field(), key_event(@primitives.End)).unwrap()
  let field = change(field, key_event(@primitives.Home, shift=true)).unwrap()
  let control = @primitives.Modifiers::new(
    shift=false,
    control=true,
    alt=false,
    meta=false,
  )
  let (unchanged, action) = field
    .handle_input(
      @primitives.KeyPressed(
        key=@primitives.Character("x"),
        modifiers=control,
        repeat=false,
      ),
      measure,
      admit,
      hit,
    )
    .unwrap()
  assert_true(unchanged.document() == field.document())
  match action {
    Some(@text_field.Cut(text~, candidate~)) => {
      assert_eq(text, "Hi 日本")
      let failed = cut_after_write(
        unchanged,
        candidate,
        Err(controller_error(@diagnostics.PermissionDenied)),
      )
      assert_true(failed.document() == field.document())
      assert_eq(failed.revision(), field.revision())
      assert_eq(
        cut_after_write(unchanged, candidate, Ok(())).document().text(),
        "",
      )
    }
    _ => abort("cut fixture")
  }
}

///|
test "clipboard pump checks epoch revision and focus before admission" {
  let field = controller_field()
  let revision = field.revision()
  let fresh = paste_if_current(field, revision, Ok(7), Ok(7), "P").unwrap()
  assert_eq(fresh.document().text(), "PHi 日本")
  let stale_epoch = paste_if_current(field, revision, Ok(7), Ok(8), "P").unwrap()
  assert_true(stale_epoch.document() == field.document())
  let stale_revision = paste_if_current(field, revision - 1, Ok(7), Ok(7), "P").unwrap()
  assert_true(stale_revision.document() == field.document())
  let blurred = field.with_focus(false).unwrap()
  let after_blur = paste_if_current(
    blurred,
    blurred.revision(),
    Ok(7),
    Ok(7),
    "P",
  ).unwrap()
  assert_true(after_blur.document() == blurred.document())
  let revoked = paste_if_current(
    field,
    revision,
    Ok(7),
    Err(controller_error(@diagnostics.StaleHandle)),
    "P",
  ).unwrap()
  assert_true(revoked.document() == field.document())
  assert_true(
    paste_if_current(field, revision, Ok(7), Ok(7), "bad\nline")
    is Err(@text_field.ForbiddenInput),
  )
}

///|
test "Busy retains pending edits and preflight rejection restores submitted text" {
  let submitted = controller_field()
  let pending = submitted.replace_selection("P", measure, admit).unwrap()
  assert_true(
    classify_field_frame(Err(controller_error(@diagnostics.Busy)))
    is BusyPending,
  )
  assert_eq(pending.document().text(), "PHi 日本")
  assert_eq(submitted.document().text(), "Hi 日本")
  assert_true(classify_field_frame(Ok(())) is Accepted)
  assert_true(
    classify_field_frame(Err(controller_error(@diagnostics.DeviceLost)))
    is RecoverPending,
  )
  for
    code in [
      @diagnostics.InvalidInput,
      @diagnostics.UnsupportedCapability,
      @diagnostics.ResourceExhausted,
    ] {
    assert_true(
      classify_field_frame(Err(controller_error(code))) is RejectPending,
    )
    let restored = restore_submitted_field(submitted, pending).unwrap()
    assert_true(restored.document() == submitted.document())
    assert_true(restored.is_focused())
  }
  let resized = pending
    .with_bounds(@primitives.Rect::new(24.0, 28.0, 300.0, 44.0).unwrap())
    .unwrap()
    .with_focus(false)
    .unwrap()
  let restored = restore_submitted_field(submitted, resized).unwrap()
  assert_true(restored.document() == submitted.document())
  assert_true(restored.bounds() == resized.bounds())
  assert_false(restored.is_focused())
}

///|
test "Escape owner disarms before logical blur and retains document" {
  let field = controller_field()
  let (same, action) = field
    .handle_input(key_event(@primitives.Escape), measure, admit, hit)
    .unwrap()
  assert_true(action is Some(@text_field.Blur))
  assert_true(same.is_focused())
  let blurred = apply_owner_blur(same, Ok(())).unwrap()
  assert_false(blurred.is_focused())
  assert_true(blurred.document() == field.document())
  assert_true(
    apply_owner_blur(same, Err(controller_error(@diagnostics.NativeFailure)))
    is Err(Native(_)),
  )
  assert_true(same.is_focused())
}

///|
test "focused tree routes actual committed text but Character key never inserts" {
  let field = controller_field()
  let (same, _) = route_input(
    field,
    key_event(@primitives.Character("Q")),
    640.0,
    240.0,
  ).unwrap()
  assert_true(same.document() == field.document())
  let (edited, _) = route_input(
    same,
    @primitives.TextInput(text="Q"),
    640.0,
    240.0,
  ).unwrap()
  assert_eq(edited.document().text(), "QHi 日本")
  let blurred = field.with_focus(false).unwrap()
  let (same, _) = route_input(
    blurred,
    @primitives.TextInput(text="Q"),
    640.0,
    240.0,
  ).unwrap()
  assert_true(same.document() == blurred.document())
}
