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
test "real negative-bearing sans input is rejected as a whole" {
  let document = @text.TextDocument::new("j").unwrap()
  let measured = measure(document).unwrap()
  // The declared DejaVu/Noto fixture profile genuinely produces overhang.
  assert_true(measured.ink_rect().left() < 0.0)
  let field = controller_field()
  assert_true(
    field.replace_selection("j", measure, admit)
    is Err(@text_field.UnsupportedLayout),
  )
  assert_eq(field.document().text(), "Hi 日本")
  assert_eq(field.revision(), 1)
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
