///|
test "select all exhaustion rejects changes while an existing full selection stays a no-op" {
  let document = @text.TextDocument::new("abc").unwrap()
  let field = TextField::new(
      17UL,
      @primitives.Rect::new(0.0, 0.0, 100.0, 28.0).unwrap(),
      16.0,
      document,
      undo_revision_measure,
      (_, _) => Ok(()),
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let exhausted = { ..field, revision: @int.MAX_VALUE, }
  let event = @primitives.KeyPressed(
    key=@primitives.Character("a"),
    modifiers=@primitives.Modifiers::new(
      shift=false,
      control=true,
      alt=false,
      meta=false,
    ),
    repeat=false,
  )
  assert_true(
    exhausted.handle_input(
      event,
      _ => Err(MeasurementFailed),
      (_, _) => Err(AdmissionFailed),
      (_, _) => Err(HitTestFailed),
    )
    is Err(RevisionExhausted),
  )
  assert_true(exhausted.document == document)
  assert_eq(exhausted.revision, @int.MAX_VALUE)
  assert_false(exhausted.history.can_undo())
  let full = field_selection_at(field, 0, 3, true).unwrap()
  let exhausted_full = { ..full, revision: @int.MAX_VALUE, }
  let unchanged = exhausted_full
    .handle_input(
      event,
      _ => Err(MeasurementFailed),
      (_, _) => Err(AdmissionFailed),
      (_, _) => Err(HitTestFailed),
    )
    .unwrap().0
  assert_true(unchanged.document == full.document)
  assert_eq(unchanged.revision, @int.MAX_VALUE)
}
