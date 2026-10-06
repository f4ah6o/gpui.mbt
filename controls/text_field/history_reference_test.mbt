///|
priv struct FieldReferenceEdit {
  before : @text.TextDocument
  after : @text.TextDocument
}

///|
priv struct FieldReferenceSnapshot {
  field : @text_field.TextField
  current : @text.TextDocument
  undo : Array[FieldReferenceEdit]
  redo : Array[FieldReferenceEdit]
}

///|
fn field_reference_next(state : Int) -> Int {
  (state * 25173 + 13849) % 65536
}

///|
fn field_reference_replace(
  document : @text.TextDocument,
  replacement : String,
) -> @text.TextDocument {
  match document.replace(document.selection().normalized_range(), replacement) {
    Ok(value) => value
    Err(_) => abort("reference replacement should be valid")
  }
}

///|
fn field_reference_backspace(
  document : @text.TextDocument,
) -> @text.TextDocument {
  let selection = document.selection()
  if !selection.is_collapsed() {
    match document.replace(selection.normalized_range(), "") {
      Ok(value) => value
      Err(_) => abort("reference selection deletion should be valid")
    }
  } else if selection.head() > 0 {
    let range = @text.TextRange::new(selection.head() - 1, selection.head()).unwrap()
    match document.replace(range, "") {
      Ok(value) => value
      Err(_) => abort("reference backspace should be valid")
    }
  } else {
    document
  }
}

///|
fn field_reference_selection(
  document : @text.TextDocument,
  anchor : Int,
  head : Int,
) -> @text.TextDocument {
  document
  .with_selection(@text.TextSelection::new(anchor, head).unwrap())
  .unwrap()
}

///|
fn field_reference_assert_state(
  field : @text_field.TextField,
  expected : @text.TextDocument,
  undo_count : Int,
  redo_count : Int,
) -> Unit raise {
  assert_true(field.document() == expected)
  assert_eq(field.selection().anchor(), expected.selection().anchor())
  assert_eq(field.selection().head(), expected.selection().head())
  assert_eq(field.can_undo(), undo_count > 0)
  assert_eq(field.can_redo(), redo_count > 0)
}

///|
test "fixed-seed ASCII edit histories match an independent reference journal" {
  let seeds = [1, 1777, 4242]
  for seed in seeds {
    let initial_length = seed % 4 + 1
    let initial_builder = StringBuilder()
    for index = 0; index < initial_length; index = index + 1 {
      initial_builder.write_string(
        if (seed + index) % 2 == 0 {
          "a"
        } else {
          "b"
        },
      )
    }
    let initial_text = initial_builder.to_string()
    let anchor = initial_length
    let head = if seed == 1777 {
      initial_length
    } else {
      seed % (initial_length + 1)
    }
    let expected_start = @text.TextDocument::new(initial_text)
      .unwrap()
      .with_selection(@text.TextSelection::new(anchor, head).unwrap())
      .unwrap()
    let mut field = field_test_focused(
      field_test_selection(
        field_test_create(initial_text, field_test_rect(0.0, 0.0, 160.0, 28.0)),
        anchor,
        head,
      ),
    )
    let mut current = expected_start
    let undo : Array[FieldReferenceEdit] = []
    let mut redo : Array[FieldReferenceEdit] = []
    let snapshots : Array[FieldReferenceSnapshot] = []
    let mut rng = seed

    for step = 0; step < 256; step = step + 1 {
      rng = field_reference_next(rng)
      let operation = rng % 6
      rng = field_reference_next(rng)
      let inserted = if rng % 2 == 0 { "a" } else { "b" }

      match operation {
        0 => {
          let projected_length = current.text().length() -
            current.selection().normalized_range().length() +
            inserted.length()
          if projected_length <= 12 {
            let before = current
            let after = field_reference_replace(before, inserted)
            field = field_test_text(field, inserted).0
            current = after
            if before.text() != after.text() {
              undo.push({ before, after, })
              redo = []
              while undo.length() > 64 {
                let _ = undo.remove(0)
              }
            }
          } else {
            // Keep the scripted geometry within its small ASCII admission
            // domain while still exercising an empty TextInput no-op.
            field = field_test_text(field, "").0
          }
        }
        1 => {
          let before = current
          let after = field_reference_backspace(before)
          field = field_test_key(
              field,
              @primitives.Backspace,
              @primitives.Modifiers::none(),
            ).0
          current = after
          if before.text() != after.text() {
            undo.push({ before, after, })
            redo = []
            while undo.length() > 64 {
              let _ = undo.remove(0)
            }
          }
        }
        2 => {
          field = field_test_undo(field)
          if undo.length() > 0 {
            let edit = undo.remove(undo.length() - 1)
            current = edit.before
            redo.push(edit)
          }
        }
        3 => {
          field = field_test_redo(field)
          if redo.length() > 0 {
            let edit = redo.remove(redo.length() - 1)
            current = edit.after
            undo.push(edit)
          }
        }
        4 => {
          field = field_test_key(
              field,
              @primitives.Home,
              @primitives.Modifiers::new(
                shift=true,
                control=false,
                alt=false,
                meta=false,
              ),
            ).0
          current = field_reference_selection(
            current,
            current.selection().anchor(),
            0,
          )
        }
        _ => {
          field = field_test_key(
              field,
              @primitives.End,
              @primitives.Modifiers::none(),
            ).0
          let end = current.text().length()
          current = field_reference_selection(current, end, end)
        }
      }

      field_reference_assert_state(field, current, undo.length(), redo.length())
      if step % 32 == 31 {
        snapshots.push({ field, current, undo: undo.copy(), redo: redo.copy(), })
      }
    }

    // Replay both branches from detached reference snapshots only after all
    // later edits, undos, redos, and navigation have run.
    for snapshot in snapshots {
      let mut replay_field = snapshot.field
      let mut replay_current = snapshot.current
      let mut replay_undo = snapshot.undo.copy()
      let mut replay_redo = snapshot.redo.copy()
      while replay_undo.length() > 0 {
        let edit = replay_undo.remove(replay_undo.length() - 1)
        replay_field = field_test_undo(replay_field)
        replay_current = edit.before
        replay_redo.push(edit)
        field_reference_assert_state(
          replay_field,
          replay_current,
          replay_undo.length(),
          replay_redo.length(),
        )
      }

      replay_field = snapshot.field
      replay_current = snapshot.current
      replay_undo = snapshot.undo.copy()
      replay_redo = snapshot.redo.copy()
      while replay_redo.length() > 0 {
        let edit = replay_redo.remove(replay_redo.length() - 1)
        replay_field = field_test_redo(replay_field)
        replay_current = edit.after
        replay_undo.push(edit)
        field_reference_assert_state(
          replay_field,
          replay_current,
          replay_undo.length(),
          replay_redo.length(),
        )
      }
    }
  }
}
