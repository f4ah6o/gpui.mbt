///|
fn field_test_preedit(
  field : @text_field.TextField,
  text : String,
  anchor : Int,
  head : Int,
) -> @text_field.TextField {
  field
  .update_composition(
    text,
    @text.TextSelection::new(anchor, head).unwrap(),
    field_test_measure,
    field_test_admit,
  )
  .unwrap()
}

///|
fn field_test_composition_original() -> @text_field.TextField raise {
  field_test_focused(
    field_test_selection(
      field_test_create("abcd", field_test_rect(0.0, 0.0, 100.0, 28.0)),
      3,
      1,
    ),
  )
}

///|
test "preedit replaces the original selected range repeatedly without history" {
  let original = field_test_composition_original()
  let first = field_test_preedit(original, "に", 1, 1)
  let second = field_test_preedit(first, "にほん", 3, 3)
  let third = field_test_preedit(second, "日本", 2, 2)
  assert_eq(first.document().text(), "aにd")
  assert_eq(second.document().text(), "aにほんd")
  assert_eq(third.document().text(), "a日本d")
  assert_true(third.is_composing())
  assert_true(third.marked_range() == Some(@text.TextRange::new(1, 3).unwrap()))
  assert_true(third.selection() == @text.TextSelection::new(3, 3).unwrap())
  assert_eq(third.revision(), original.revision() + 3)
  for preview in [first, second, third] {
    assert_false(preview.can_undo())
    assert_false(preview.can_redo())
    assert_true(preview.measurement().document() == preview.document())
  }
  assert_eq(original.document().text(), "abcd")
  assert_true(original.selection() == @text.TextSelection::new(3, 1).unwrap())
  assert_false(original.is_composing())
  assert_true(original.marked_range() is None)
}

///|
test "mixed supplementary preedit maps directional UTF8 endpoints exactly" {
  let original = field_test_focused(
    field_test_selection(
      field_test_create("a😀bc", field_test_rect(0.0, 0.0, 160.0, 28.0)),
      4,
      1,
    ),
  )
  let preview = original
    .update_composition_utf8(
      "😀日本é", 10, 4, field_test_measure, field_test_admit,
    )
    .unwrap()
  assert_eq(preview.document().text(), "a😀日本éc")
  assert_true(preview.selection() == @text.TextSelection::new(5, 3).unwrap())
  assert_true(
    preview.marked_range() == Some(@text.TextRange::new(1, 6).unwrap()),
  )
  assert_eq(
    preview.document().utf8_offset(preview.selection().anchor()).unwrap(),
    11,
  )
  assert_eq(
    preview.document().utf8_offset(preview.selection().head()).unwrap(),
    5,
  )
  let cancelled = preview
    .cancel_composition(field_test_measure, field_test_admit)
    .unwrap()
  assert_true(cancelled.document() == original.document())
  assert_true(cancelled.selection() == @text.TextSelection::new(4, 1).unwrap())
  assert_false(cancelled.is_composing())
}

///|
test "composition commit is one original to final undo group" {
  let original = field_test_composition_original()
  let preview = field_test_preedit(
    field_test_preedit(original, "に", 1, 1),
    "にほん",
    3,
    3,
  )
  let committed = preview
    .commit_composition("日本", field_test_measure, field_test_admit)
    .unwrap()
  assert_eq(committed.document().text(), "a日本d")
  assert_true(committed.selection() == @text.TextSelection::new(3, 3).unwrap())
  assert_false(committed.is_composing())
  assert_true(committed.marked_range() is None)
  assert_true(committed.can_undo())
  assert_false(committed.can_redo())
  let undone = field_test_undo(committed)
  assert_true(undone.document() == original.document())
  assert_false(undone.can_undo())
  assert_true(undone.can_redo())
  let redone = field_test_redo(undone)
  assert_true(redone.document() == committed.document())
  assert_false(redone.is_composing())
  assert_false(redone.can_redo())
  assert_eq(preview.document().text(), "aにほんd")
  assert_true(preview.is_composing())
  assert_false(preview.can_undo())
}

///|
test "empty preedit clears display but retains the original replacement" {
  let original = field_test_composition_original()
  let empty_before = field_test_preedit(original, "", 0, 0)
  assert_eq(empty_before.revision(), original.revision())
  assert_false(empty_before.is_composing())
  let preview = field_test_preedit(original, "にほん", 3, 3)
  let cleared = field_test_preedit(preview, "", 0, 0)
  assert_true(cleared.document() == original.document())
  assert_true(cleared.is_composing())
  assert_true(cleared.marked_range() is None)
  assert_false(cleared.can_undo())
  let restarted = field_test_preedit(cleared, "日本", 2, 2)
  assert_eq(restarted.document().text(), "a日本d")
  let committed = cleared
    .commit_composition("日本", field_test_measure, field_test_admit)
    .unwrap()
  assert_eq(committed.document().text(), "a日本d")
  assert_true(field_test_undo(committed).document() == original.document())
  let deleted = cleared
    .commit_composition("", field_test_measure, field_test_admit)
    .unwrap()
  assert_eq(deleted.document().text(), "ad")
  assert_true(deleted.selection() == @text.TextSelection::new(1, 1).unwrap())
  assert_true(field_test_undo(deleted).document() == original.document())
}

///|
test "cancel and focus loss preserve exact original selection and redo" {
  let original = field_test_composition_original()
  let (edited, _) = field_test_text(original, "X")
  let undone = field_test_undo(edited)
  assert_true(undone.can_redo())
  let preview = field_test_preedit(undone, "日本", 2, 2)
  assert_false(preview.can_undo())
  assert_true(preview.can_redo())
  let cancelled = preview
    .cancel_composition(field_test_measure, field_test_admit)
    .unwrap()
  assert_true(cancelled.document() == original.document())
  assert_false(cancelled.is_composing())
  assert_false(cancelled.can_undo())
  assert_true(cancelled.can_redo())
  assert_true(field_test_redo(cancelled).document() == edited.document())

  let blurred = preview.with_focus(false).unwrap()
  assert_false(blurred.is_focused())
  assert_false(blurred.is_composing())
  assert_true(blurred.document() == original.document())
  assert_true(blurred.marked_range() is None)
  assert_true(blurred.can_redo())
  assert_true(blurred.measurement().document() == original.document())
  let focused = blurred.with_focus(true).unwrap()
  assert_true(field_test_redo(focused).document() == edited.document())
  assert_true(preview.is_composing())
  assert_true(preview.can_redo())
}

///|
test "same text composition commit preserves existing redo" {
  let original = field_test_composition_original()
  let undone = field_test_undo(field_test_text(original, "X").0)
  let preview = field_test_preedit(undone, "temporary", 9, 9)
  let committed = preview
    .commit_composition("bc", field_test_measure, field_test_admit)
    .unwrap()
  assert_eq(committed.document().text(), "abcd")
  assert_true(committed.selection() == @text.TextSelection::new(3, 3).unwrap())
  assert_false(committed.can_undo())
  assert_true(committed.can_redo())
  assert_eq(field_test_redo(committed).document().text(), "aXd")
}

///|
test "invalid UTF8 endpoints and split surrogate endpoints never start composition" {
  let original = field_test_composition_original()
  let calls = [0]
  let counted_measure = fn(document) {
    calls[0] += 1
    field_test_measure(document)
  }
  for bytes in [-1, 1, 2, 3, 5, @int.MAX_VALUE] {
    assert_true(
      original.update_composition_utf8(
        "😀", bytes, 4, counted_measure, field_test_admit,
      )
      is Err(@text_field.InvalidSelection),
    )
  }
  assert_true(
    original.update_composition(
      "😀",
      @text.TextSelection::new(1, 2).unwrap(),
      counted_measure,
      field_test_admit,
    )
    is Err(@text_field.InvalidSelection),
  )
  assert_true(
    original.update_composition(
      "",
      @text.TextSelection::new(0, 1).unwrap(),
      counted_measure,
      field_test_admit,
    )
    is Err(@text_field.InvalidSelection),
  )
  assert_eq(calls[0], 0)
  assert_false(original.is_composing())
  assert_false(original.can_undo())
  assert_true(original.document().text() == "abcd")
}

///|
test "preedit hidden grapheme cursor is rejected rather than snapped" {
  let original = field_test_focused(
    field_test_create("", field_test_rect(0.0, 0.0, 120.0, 28.0)),
  )
  assert_true(
    original.update_composition_utf8(
      "a\u{301}", 1, 1, field_test_measure, field_test_admit,
    )
    is Err(@text_field.InvalidSelection),
  )
  let preview = field_test_preedit(original, "a\u{301}", 2, 2)
  assert_eq(preview.selection().head(), 2)
  assert_false(original.is_composing())
  assert_true(
    preview.update_composition_utf8(
      "👩\u{200D}👩", 4, 4, field_test_measure, field_test_admit,
    )
    is Err(@text_field.InvalidSelection),
  )
  assert_eq(preview.document().text(), "a\u{301}")
  assert_true(preview.is_composing())

  // Joining final text with the original suffix can hide the requested final
  // caret even when the replacement itself ends at a scalar boundary.
  let combining_suffix = field_test_focused(
    field_test_create("\u{301}", field_test_rect(0.0, 0.0, 120.0, 28.0)),
  )
  let suffix_preview = field_test_preedit(combining_suffix, "b", 1, 1)
  assert_true(
    suffix_preview.commit_composition("a", field_test_measure, field_test_admit)
    is Err(@text_field.InvalidSelection),
  )
  assert_eq(suffix_preview.document().text(), "b\u{301}")
  assert_true(suffix_preview.is_composing())
}

///|
test "preview commit clear and cancel admission failures retain the whole transaction" {
  let original = field_test_composition_original()
  let rejecting_admit = fn(_document, _measurement) {
    Err(@text_field.AdmissionFailed)
  }
  assert_true(
    original.update_composition(
      "日本",
      @text.TextSelection::new(2, 2).unwrap(),
      field_test_measure,
      rejecting_admit,
    )
    is Err(@text_field.AdmissionFailed),
  )
  assert_false(original.is_composing())
  let preview = field_test_preedit(original, "日本", 2, 2)
  for preedit in ["にほん", ""] {
    assert_true(
      preview.update_composition(
        preedit,
        @text.TextSelection::new(preedit.length(), preedit.length()).unwrap(),
        field_test_measure,
        rejecting_admit,
      )
      is Err(@text_field.AdmissionFailed),
    )
  }
  assert_true(
    preview.commit_composition("X", field_test_measure, rejecting_admit)
    is Err(@text_field.AdmissionFailed),
  )
  assert_true(
    preview.cancel_composition(field_test_measure, rejecting_admit)
    is Err(@text_field.AdmissionFailed),
  )
  assert_eq(preview.document().text(), "a日本d")
  assert_true(preview.is_composing())
  assert_true(
    preview.marked_range() == Some(@text.TextRange::new(1, 3).unwrap()),
  )
  assert_false(preview.can_undo())
  assert_false(preview.can_redo())
  let committed = preview
    .commit_composition("X", field_test_measure, field_test_admit)
    .unwrap()
  assert_true(field_test_undo(committed).document() == original.document())
}

///|
test "composition keeps field bounds text and layout admission limits" {
  let original = field_test_composition_original()
  let preview = field_test_preedit(original, "日本", 2, 2)
  let measure_calls = [0]
  let counted_measure = fn(document) {
    measure_calls[0] += 1
    field_test_measure(document)
  }
  for bad_text in ["bad\nline", "\u{0}", "\u{2028}"] {
    assert_true(
      preview.update_composition(
        bad_text,
        @text.TextSelection::new(0, 0).unwrap(),
        counted_measure,
        field_test_admit,
      )
      is Err(@text_field.ForbiddenInput),
    )
    assert_true(
      preview.commit_composition(bad_text, counted_measure, field_test_admit)
      is Err(@text_field.ForbiddenInput),
    )
  }
  let malformed = "😀".unsafe_substring(start=0, end=1)
  assert_true(
    preview.update_composition_utf8(
      malformed, 0, 0, counted_measure, field_test_admit,
    )
    is Err(@text_field.MalformedText),
  )
  assert_true(
    preview.commit_composition(malformed, counted_measure, field_test_admit)
    is Err(@text_field.MalformedText),
  )
  let oversized = "a".repeat(4097)
  assert_true(
    preview.update_composition_utf8(
      oversized, 0, 0, counted_measure, field_test_admit,
    )
    is Err(@text_field.TextTooLarge),
  )
  // The preedit alone is bounded, but its retained prefix/suffix would exceed
  // the document limit. Reject it before asking for a layout.
  assert_true(
    preview.update_composition_utf8(
      "a".repeat(4095),
      0,
      0,
      counted_measure,
      field_test_admit,
    )
    is Err(@text_field.TextTooLarge),
  )
  assert_eq(measure_calls[0], 0)
  assert_true(
    preview.update_composition_utf8(
      "X",
      1,
      1,
      _ => Err(@text_field.MeasurementFailed),
      field_test_admit,
    )
    is Err(@text_field.MeasurementFailed),
  )
  let wrong_measure = fn(_document) { field_test_measure(original.document()) }
  assert_true(
    preview.commit_composition("X", wrong_measure, field_test_admit)
    is Err(@text_field.UnsupportedLayout),
  )
  let resized = preview
    .with_bounds(field_test_rect(24.0, 28.0, 150.0, 28.0))
    .unwrap()
  assert_true(resized.is_composing())
  let blurred = resized.with_focus(false).unwrap()
  assert_true(blurred.bounds() == resized.bounds())
  assert_true(blurred.document() == original.document())
  assert_false(blurred.is_composing())
}

///|
test "ordinary editing must explicitly resolve composition ownership" {
  let original = field_test_composition_original()
  let preview = field_test_preedit(original, "日本", 2, 2)
  assert_true(
    preview.replace_selection("X", field_test_measure, field_test_admit)
    is Err(@text_field.CompositionActive),
  )
  assert_true(
    preview.undo(field_test_measure, field_test_admit)
    is Err(@text_field.CompositionActive),
  )
  assert_true(
    preview.redo(field_test_measure, field_test_admit)
    is Err(@text_field.CompositionActive),
  )
  for
    event in [
      @primitives.TextInput(text="X"),
      @primitives.TextInput(text=""),
      @primitives.KeyPressed(
        key=@primitives.ArrowLeft,
        modifiers=@primitives.Modifiers::none(),
        repeat=false,
      ),
      @primitives.PointerButtonPressed(
        position=@primitives.Point::new(12.0, 12.0).unwrap(),
        button=@primitives.Primary,
        modifiers=@primitives.Modifiers::none(),
      ),
    ] {
    assert_true(
      preview.handle_input(
        event, field_test_measure, field_test_admit, field_test_hit,
      )
      is Err(@text_field.CompositionActive),
    )
  }
  assert_true(
    original.commit_composition("X", field_test_measure, field_test_admit)
    is Err(@text_field.NoComposition),
  )
  let cancelled = preview
    .cancel_composition(field_test_measure, field_test_admit)
    .unwrap()
  assert_eq(field_test_text(cancelled, "X").0.document().text(), "aXd")
  let unfocused = original.with_focus(false).unwrap()
  let ignored = field_test_preedit(unfocused, "日本", 2, 2)
  assert_true(ignored.document() == unfocused.document())
  assert_eq(ignored.revision(), unfocused.revision())
  assert_false(ignored.is_composing())
}
