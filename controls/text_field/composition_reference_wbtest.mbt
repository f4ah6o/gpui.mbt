///|
// A deliberately separate oracle: plain strings, integer endpoints and a
// detached journal. No expected transition calls TextDocument.replace,
// TextComposition, TextField, or their selection/range accessors. The small
// fixture treats every scalar boundary as a layout cursor stop; it is not a
// font, grapheme-segmentation implementation, or formal proof.
priv struct CompositionReferenceDocument {
  text : String
  anchor : Int
  head : Int
} derive(Eq)

///|
priv struct CompositionReferenceEdit {
  prior : CompositionReferenceDocument
  next : CompositionReferenceDocument
}

///|
priv struct CompositionReferenceOwner {
  original : CompositionReferenceDocument
  visible : Bool
  marked_start : Int
  marked_end : Int
}

///|
priv struct CompositionReferenceState {
  document : CompositionReferenceDocument
  undo : Array[CompositionReferenceEdit]
  redo : Array[CompositionReferenceEdit]
  owner : CompositionReferenceOwner?
  focused : Bool
  revision : Int
}

///|
priv enum CompositionReferenceOperation {
  Preedit(String, Int, Int)
  PreeditUtf8(String, Int, Int)
  Commit(String)
  Cancel
  Focus(Bool)
  Replace(String)
  Undo
  Redo
  HomeShift
  End
}

///|
fn composition_reference_start(
  text : String,
  anchor : Int,
  head : Int,
) -> CompositionReferenceState {
  {
    document: { text, anchor, head, },
    undo: [],
    redo: [],
    owner: None,
    focused: true,
    revision: 1,
  }
}

///|
fn composition_reference_start_offset(
  document : CompositionReferenceDocument,
) -> Int {
  if document.anchor < document.head {
    document.anchor
  } else {
    document.head
  }
}

///|
fn composition_reference_end_offset(
  document : CompositionReferenceDocument,
) -> Int {
  if document.anchor > document.head {
    document.anchor
  } else {
    document.head
  }
}

///|
fn composition_reference_splice(
  original : CompositionReferenceDocument,
  insertion : String,
) -> CompositionReferenceDocument {
  let start = composition_reference_start_offset(original)
  let end = composition_reference_end_offset(original)
  let text = original.text.unsafe_substring(start=0, end=start) +
    insertion +
    original.text.unsafe_substring(start=end, end=original.text.length())
  let caret = start + insertion.length()
  { text, anchor: caret, head: caret, }
}

///|
fn composition_reference_utf8_bytes(text : String) -> Int {
  let mut bytes = 0
  for scalar in text.iter() {
    let value = scalar.to_int()
    bytes += if value <= 0x7F {
      1
    } else if value <= 0x7FF {
      2
    } else if value <= 0xFFFF {
      3
    } else {
      4
    }
  }
  bytes
}

///|
// Walk Unicode scalars rather than calling the production byte adapter.
fn composition_reference_utf16_at_byte(text : String, byte : Int) -> Int? {
  let mut consumed_bytes = 0
  let mut consumed_units = 0
  if byte == 0 {
    return Some(0)
  }
  for scalar in text.iter() {
    let value = scalar.to_int()
    consumed_bytes += if value <= 0x7F {
      1
    } else if value <= 0x7FF {
      2
    } else if value <= 0xFFFF {
      3
    } else {
      4
    }
    consumed_units += if value > 0xFFFF { 2 } else { 1 }
    if consumed_bytes == byte {
      return Some(consumed_units)
    }
  }
  None
}

///|
fn composition_reference_scalar_boundary(text : String, offset : Int) -> Bool {
  let mut units = 0
  if offset == 0 {
    return true
  }
  for scalar in text.iter() {
    units += if scalar.to_int() > 0xFFFF { 2 } else { 1 }
    if units == offset {
      return true
    }
  }
  false
}

///|
fn composition_reference_payload(
  undo : Array[CompositionReferenceEdit],
  redo : Array[CompositionReferenceEdit],
) -> Int {
  let mut bytes = 0
  for entry in undo {
    bytes += composition_reference_utf8_bytes(entry.prior.text) +
      composition_reference_utf8_bytes(entry.next.text)
  }
  for entry in redo {
    bytes += composition_reference_utf8_bytes(entry.prior.text) +
      composition_reference_utf8_bytes(entry.next.text)
  }
  bytes
}

///|
fn composition_reference_record(
  state : CompositionReferenceState,
  before : CompositionReferenceDocument,
  after : CompositionReferenceDocument,
) -> CompositionReferenceState {
  if before.text == after.text {
    return { ..state, document: after, }
  }
  let undo = state.undo.copy()
  undo.push({ prior: before, next: after, })
  while undo.length() > 64 || composition_reference_payload(undo, []) > 65536 {
    let _ = undo.remove(0)
  }
  { ..state, document: after, undo, redo: [], }
}

///|
fn composition_reference_step(
  state : CompositionReferenceState,
  operation : CompositionReferenceOperation,
) -> Result[CompositionReferenceState, TextFieldError] {
  match operation {
    PreeditUtf8(text, anchor_bytes, head_bytes) => {
      if !state.focused {
        return Ok(state)
      }
      match
        (
          composition_reference_utf16_at_byte(text, anchor_bytes),
          composition_reference_utf16_at_byte(text, head_bytes),
        ) {
        (Some(anchor), Some(head)) =>
          composition_reference_step(state, Preedit(text, anchor, head))
        _ => Err(InvalidSelection)
      }
    }
    Preedit(text, anchor, head) => {
      if !state.focused {
        return Ok(state)
      }
      if !composition_reference_scalar_boundary(text, anchor) ||
        !composition_reference_scalar_boundary(text, head) {
        return Err(InvalidSelection)
      }
      if text.length() == 0 && state.owner is None {
        return Ok(state)
      }
      let original = match state.owner {
        Some(owner) => owner.original
        None => state.document
      }
      let start = composition_reference_start_offset(original)
      let visible = text.length() != 0
      let document = if visible {
        let replacement = composition_reference_splice(original, text)
        { ..replacement, anchor: start + anchor, head: start + head, }
      } else {
        original
      }
      Ok({
        ..state,
        document,
        owner: Some({
          original,
          visible,
          marked_start: start,
          marked_end: if visible {
            start + text.length()
          } else {
            composition_reference_end_offset(original)
          },
        }),
        revision: state.revision + 1,
      })
    }
    Commit(text) => {
      if !state.focused {
        return Ok(state)
      }
      let owner = match state.owner {
        Some(value) => value
        None => return Err(NoComposition)
      }
      let after = composition_reference_splice(owner.original, text)
      let recorded = composition_reference_record(state, owner.original, after)
      Ok({ ..recorded, owner: None, revision: state.revision + 1, })
    }
    Cancel =>
      match state.owner {
        None => Ok(state)
        Some(owner) =>
          Ok({
            ..state,
            document: owner.original,
            owner: None,
            revision: state.revision + 1,
          })
      }
    Focus(focused) => {
      let document = if !focused {
        match state.owner {
          Some(owner) => owner.original
          None => state.document
        }
      } else {
        state.document
      }
      let changed = focused != state.focused ||
        (!focused && state.owner is Some(_))
      Ok({
        ..state,
        document,
        focused,
        owner: if focused {
          state.owner
        } else {
          None
        },
        revision: state.revision + (if changed { 1 } else { 0 }),
      })
    }
    Replace(text) => {
      if !state.focused {
        return Ok(state)
      }
      if state.owner is Some(_) {
        return Err(CompositionActive)
      }
      let after = composition_reference_splice(state.document, text)
      if after == state.document {
        return Ok(state)
      }
      let recorded = composition_reference_record(state, state.document, after)
      Ok({ ..recorded, revision: state.revision + 1, })
    }
    Undo | Redo => {
      if !state.focused {
        return Ok(state)
      }
      if state.owner is Some(_) {
        return Err(CompositionActive)
      }
      let undo = state.undo.copy()
      let redo = state.redo.copy()
      let document = match operation {
        Undo if undo.length() > 0 => {
          let entry = undo.remove(undo.length() - 1)
          redo.push(entry)
          entry.prior
        }
        Redo if redo.length() > 0 => {
          let entry = redo.remove(redo.length() - 1)
          undo.push(entry)
          entry.next
        }
        _ => return Ok(state)
      }
      Ok({ ..state, document, undo, redo, revision: state.revision + 1, })
    }
    HomeShift | End => {
      if !state.focused {
        return Ok(state)
      }
      if state.owner is Some(_) {
        return Err(CompositionActive)
      }
      let document = match operation {
        HomeShift => { ..state.document, head: 0, }
        _ => {
          let end = state.document.text.length()
          { ..state.document, anchor: end, head: end, }
        }
      }
      Ok({
        ..state,
        document,
        revision: state.revision +
        (if document != state.document { 1 } else { 0 }),
      })
    }
  }
}

///|
fn composition_reference_measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, TextFieldError] {
  let carets = []
  let mut offset = 0
  let mut index = 0
  let text = document.text()
  for scalar in text.iter() {
    let bounds = @primitives.Rect::new(index.to_double() * 8.0, 0.0, 0.0, 16.0).unwrap()
    carets.push(
      @text_layout.CaretGeometry::new(offset, true, bounds, bounds).unwrap(),
    )
    offset += if scalar.to_int() > 0xFFFF { 2 } else { 1 }
    index += 1
  }
  let end_bounds = @primitives.Rect::new(
    index.to_double() * 8.0,
    0.0,
    0.0,
    16.0,
  ).unwrap()
  carets.push(
    @text_layout.CaretGeometry::new(offset, true, end_bounds, end_bounds).unwrap(),
  )
  let bounds = @primitives.Rect::new(0.0, 0.0, index.to_double() * 8.0, 16.0).unwrap()
  match
    @text_layout.TextMeasurement::new(
      document, bounds, bounds, 12.0, 1, 0, carets,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(MeasurementFailed)
  }
}

///|
fn composition_reference_field(state : CompositionReferenceState) -> TextField {
  let document = @text.TextDocument::new(state.document.text)
    .unwrap()
    .with_selection(
      @text.TextSelection::new(state.document.anchor, state.document.head).unwrap(),
    )
    .unwrap()
  TextField::new(
    31UL,
    @primitives.Rect::new(0.0, 0.0, 320.0, 36.0).unwrap(),
    10.0,
    document,
    composition_reference_measure,
    (_, _) => Ok(()),
  )
  .unwrap()
  .with_focus(true)
  .unwrap()
}

///|
fn composition_reference_actual_step(
  field : TextField,
  operation : CompositionReferenceOperation,
) -> Result[TextField, TextFieldError] {
  let admit = fn(_, _) { Ok(()) }
  match operation {
    Preedit(text, anchor, head) =>
      field.update_composition(
        text,
        @text.TextSelection::new(anchor, head).unwrap(),
        composition_reference_measure,
        admit,
      )
    PreeditUtf8(text, anchor, head) =>
      field.update_composition_utf8(
        text, anchor, head, composition_reference_measure, admit,
      )
    Commit(text) =>
      field.commit_composition(text, composition_reference_measure, admit)
    Cancel => field.cancel_composition(composition_reference_measure, admit)
    Focus(focused) => field.with_focus(focused)
    Replace(text) =>
      field.replace_selection(text, composition_reference_measure, admit)
    Undo => field.undo(composition_reference_measure, admit)
    Redo => field.redo(composition_reference_measure, admit)
    HomeShift | End => {
      let (key, shift) = match operation {
        HomeShift => (@primitives.Home, true)
        _ => (@primitives.End, false)
      }
      field
      .handle_input(
        @primitives.KeyPressed(
          key~,
          modifiers=@primitives.Modifiers::new(
            shift~,
            control=false,
            alt=false,
            meta=false,
          ),
          repeat=false,
        ),
        composition_reference_measure,
        admit,
        (_, _) => Err(HitTestFailed),
      )
      .map(fn(result) { result.0 })
    }
  }
}

///|
fn composition_reference_document_matches(
  actual : @text.TextDocument,
  expected : CompositionReferenceDocument,
) -> Bool {
  actual.text() == expected.text &&
  actual.selection().anchor() == expected.anchor &&
  actual.selection().head() == expected.head
}

///|
fn composition_reference_history_matches(
  actual : FieldHistory,
  undo : Array[CompositionReferenceEdit],
  redo : Array[CompositionReferenceEdit],
) -> Bool {
  if actual.undo.length() != undo.length() ||
    actual.redo.length() != redo.length() ||
    actual.payload_bytes != composition_reference_payload(undo, redo) {
    return false
  }
  for index in 0..<undo.length() {
    if !composition_reference_document_matches(
        actual.undo[index].before,
        undo[index].prior,
      ) ||
      !composition_reference_document_matches(
        actual.undo[index].after,
        undo[index].next,
      ) {
      return false
    }
  }
  for index in 0..<redo.length() {
    if !composition_reference_document_matches(
        actual.redo[index].before,
        redo[index].prior,
      ) ||
      !composition_reference_document_matches(
        actual.redo[index].after,
        redo[index].next,
      ) {
      return false
    }
  }
  true
}

///|
fn composition_reference_range_matches(
  actual : @text.TextRange?,
  start : Int,
  end : Int,
) -> Bool {
  match actual {
    Some(range) => range.start() == start && range.end() == end
    None => false
  }
}

///|
// Read private storage AND public observations. A broken accessor cannot
// generate the expected value, and self-consistent wrong observations cannot
// hide an altered text, directional selection, journal or saved transaction.
fn composition_reference_matches(
  field : TextField,
  state : CompositionReferenceState,
) -> Bool {
  if !composition_reference_document_matches(field.document, state.document) ||
    !composition_reference_document_matches(field.document(), state.document) ||
    !composition_reference_document_matches(
      field.measurement.document(),
      state.document,
    ) ||
    field.selection().anchor() != state.document.anchor ||
    field.selection().head() != state.document.head ||
    field.focused != state.focused ||
    field.is_focused() != state.focused ||
    field.revision != state.revision ||
    field.revision() != state.revision ||
    field.can_undo() != (state.undo.length() > 0) ||
    field.can_redo() != (state.redo.length() > 0) ||
    !composition_reference_history_matches(
      field.history,
      state.undo,
      state.redo,
    ) {
    return false
  }
  match (field.composition, state.owner) {
    (None, None) => !field.is_composing() && field.marked_range() is None
    (Some(actual), Some(expected)) => {
      if !field.is_composing() ||
        actual.preview_visible != expected.visible ||
        !composition_reference_document_matches(
          actual.original,
          expected.original,
        ) ||
        !composition_reference_document_matches(
          actual.measurement.document(),
          expected.original,
        ) ||
        !composition_reference_document_matches(
          actual.transaction.document(),
          state.document,
        ) ||
        !(actual.transaction.status() is @text.Active) ||
        !composition_reference_history_matches(
          actual.history,
          state.undo,
          state.redo,
        ) ||
        !composition_reference_range_matches(
          actual.transaction.marked_range(),
          expected.marked_start,
          expected.marked_end,
        ) {
        return false
      }
      if expected.visible {
        composition_reference_range_matches(
          field.marked_range(),
          expected.marked_start,
          expected.marked_end,
        )
      } else {
        field.marked_range() is None
      }
    }
    _ => false
  }
}

///|
fn composition_reference_run_operation(
  field : TextField,
  state : CompositionReferenceState,
  operation : CompositionReferenceOperation,
  context : String,
) -> (TextField, CompositionReferenceState) raise {
  let expected = composition_reference_step(state, operation)
  let actual = composition_reference_actual_step(field, operation)
  let (next_field, next_state) = match (actual, expected) {
    (Ok(value), Ok(reference)) => (value, reference)
    (Err(error), Err(reference_error)) => {
      assert_true(error == reference_error, msg=context)
      (field, state)
    }
    _ => {
      fail("composition reference outcome mismatch: " + context)
      (field, state)
    }
  }
  assert_true(
    composition_reference_matches(next_field, next_state),
    msg=context,
  )
  // An operation must not mutate the retained input snapshot or its stacks.
  assert_true(composition_reference_matches(field, state), msg=context)
  (next_field, next_state)
}

///|
test "composition reference exhaustive short traces keep ownership and redo" {
  let operations : Array[CompositionReferenceOperation] = [
    Preedit("", 0, 0),
    Preedit("xy", 2, 0),
    PreeditUtf8("😀é", 6, 4),
    Commit("bc"),
    Commit(""),
    Cancel,
    Focus(false),
    Focus(true),
    Undo,
    Redo,
  ]
  // Every length-three trace begins with an independently known redo branch.
  // This enumerates 1,000 traces, including clear-then-commit/cancel/blur and
  // unfocused event sequences, rather than relying on a random seed to hit it.
  let initial = composition_reference_start("abcd", 3, 1)
  let (edited_field, edited_state) = composition_reference_run_operation(
    composition_reference_field(initial),
    initial,
    Replace("X"),
    "trace setup edit",
  )
  let (base_field, base_state) = composition_reference_run_operation(
    edited_field,
    edited_state,
    Undo,
    "trace setup undo",
  )
  for first in 0..<operations.length() {
    let (field1, state1) = composition_reference_run_operation(
      base_field,
      base_state,
      operations[first],
      "trace first=\{first}",
    )
    for second in 0..<operations.length() {
      let (field2, state2) = composition_reference_run_operation(
        field1,
        state1,
        operations[second],
        "trace first=\{first} second=\{second}",
      )
      for third in 0..<operations.length() {
        let _ = composition_reference_run_operation(
          field2,
          state2,
          operations[third],
          "trace first=\{first} second=\{second} third=\{third}",
        )
      }
    }
  }
}

///|
test "composition reference fixed seed state machines match independent journals" {
  let operations : Array[CompositionReferenceOperation] = [
    Preedit("", 0, 0),
    Preedit("p", 0, 1),
    Preedit("pq", 2, 0),
    PreeditUtf8("😀日本é", 10, 4),
    PreeditUtf8("😀", 1, 4),
    Commit(""),
    Commit("bc"),
    Commit("é😀"),
    Cancel,
    Focus(false),
    Focus(true),
    Replace("x"),
    Replace(""),
    Undo,
    Redo,
    HomeShift,
    End,
  ]
  for seed in [1, 1777, 4242, 65535] {
    let initial = composition_reference_start("a😀bc", 4, 1)
    let mut state = initial
    let mut field = composition_reference_field(initial)
    let mut random = seed
    let seen = Array::make(operations.length(), 0)
    for step in 0..<256 {
      random = (random * 25173 + 13849) % 65536
      let index = random / 256 % operations.length()
      seen[index] += 1
      let (next_field, next_state) = composition_reference_run_operation(
        field,
        state,
        operations[index],
        "seed=\{seed} step=\{step} operation=\{index}",
      )
      field = next_field
      state = next_state
    }
    for index in 0..<operations.length() {
      assert_true(seen[index] > 0, msg="seed=\{seed} missed operation=\{index}")
    }
    // Resolve ownership and replay every retained undo/redo endpoint against
    // plain reference snapshots, so checking only stack counts is inadequate.
    let (resolved_field, resolved_state) = composition_reference_run_operation(
      field,
      state,
      Cancel,
      "seed=\{seed} resolve",
    )
    let (focused_field, focused_state) = composition_reference_run_operation(
      resolved_field,
      resolved_state,
      Focus(true),
      "seed=\{seed} refocus",
    )
    field = focused_field
    state = focused_state
    while state.undo.length() > 0 {
      let (next_field, next_state) = composition_reference_run_operation(
        field,
        state,
        Undo,
        "seed=\{seed} replay undo",
      )
      field = next_field
      state = next_state
    }
    while state.redo.length() > 0 {
      let (next_field, next_state) = composition_reference_run_operation(
        field,
        state,
        Redo,
        "seed=\{seed} replay redo",
      )
      field = next_field
      state = next_state
    }
  }
}

///|
test "composition reference exhausts exact UTF8 endpoints including boundaries" {
  let initial = composition_reference_start("a😀bc", 4, 1)
  let base = composition_reference_field(initial)
  for text in ["", "a", "é", "日", "😀", "😀日本é"] {
    let bytes = composition_reference_utf8_bytes(text)
    for anchor in -1..<=(bytes + 1) {
      for head in -1..<=(bytes + 1) {
        let _ = composition_reference_run_operation(
          base,
          initial,
          PreeditUtf8(text, anchor, head),
          "utf8 text=\{text} anchor=\{anchor} head=\{head}",
        )
      }
    }
  }
  let (preview, preview_state) = composition_reference_run_operation(
    base,
    initial,
    Preedit("xy", 2, 0),
    "utf8 active setup",
  )
  for (anchor, head) in [(0, 0), (4, 4), (4, 0), (0, 4), (1, 4), (4, 3)] {
    let _ = composition_reference_run_operation(
      preview,
      preview_state,
      PreeditUtf8("😀", anchor, head),
      "utf8 active \{anchor},\{head}",
    )
  }
}

///|
test "composition reference rejects self consistent corruptions" {
  let initial = composition_reference_start("abcd", 3, 1)
  let (edited, edited_state) = composition_reference_run_operation(
    composition_reference_field(initial),
    initial,
    Replace("X"),
    "negative edit setup",
  )
  let (undone, undone_state) = composition_reference_run_operation(
    edited,
    edited_state,
    Undo,
    "negative redo setup",
  )
  let (preview, state) = composition_reference_run_operation(
    undone,
    undone_state,
    Preedit("pq", 2, 0),
    "negative preview setup",
  )
  let owner = preview.composition.unwrap()
  // Corrupt both document and matching geometry, so accessor agreement alone
  // would pass. The independent text and endpoint oracle still rejects it.
  let wrong_text = @text.TextDocument::new("aZZd")
    .unwrap()
    .with_selection(@text.TextSelection::new(3, 1).unwrap())
    .unwrap()
  let text_corruption = {
    ..preview,
    document: wrong_text,
    measurement: composition_reference_measure(wrong_text).unwrap(),
  }
  assert_false(composition_reference_matches(text_corruption, state))
  let wrong_selection = @text.TextDocument::new("apqd")
    .unwrap()
    .with_selection(@text.TextSelection::new(1, 3).unwrap())
    .unwrap()
  let selection_corruption = {
    ..preview,
    document: wrong_selection,
    measurement: composition_reference_measure(wrong_selection).unwrap(),
  }
  assert_false(composition_reference_matches(selection_corruption, state))
  assert_false(
    composition_reference_matches(
      { ..preview, history: FieldHistory::empty(), },
      state,
    ),
  )
  // Same counts and payload, but a changed directional history endpoint.
  let wrong_before = @text.TextDocument::new("abcd")
    .unwrap()
    .with_selection(@text.TextSelection::new(1, 3).unwrap())
    .unwrap()
  let entry = preview.history.redo[0]
  let wrong_history : FieldHistory = {
    ..preview.history,
    redo: [{ ..entry, before: wrong_before, }],
  }
  assert_false(
    composition_reference_matches({ ..preview, history: wrong_history, }, state),
  )
  assert_false(
    composition_reference_matches({ ..preview, composition: None, }, state),
  )
  assert_false(
    composition_reference_matches(
      { ..preview, composition: Some({ ..owner, preview_visible: false, }), },
      state,
    ),
  )
  assert_false(
    composition_reference_matches(
      { ..preview, composition: Some({ ..owner, original: wrong_before, }), },
      state,
    ),
  )
  assert_false(
    composition_reference_matches(
      {
        ..preview,
        composition: Some({ ..owner, history: FieldHistory::empty(), }),
      },
      state,
    ),
  )
  // Altered model expectations are rejected too, including normalized versus
  // original directional selection and a retained transaction after commit.
  assert_false(
    composition_reference_matches(preview, {
      ..state,
      document: { ..state.document, anchor: 1, head: 3, },
    }),
  )
  assert_false(
    composition_reference_matches(preview, { ..state, owner: None, }),
  )
  assert_true(composition_reference_matches(preview, state))
}

///|
test "composition reference long trace preserves directional originals and same text redo" {
  let mut state = composition_reference_start("abcd", 3, 1)
  let mut field = composition_reference_field(state)
  let operations : Array[CompositionReferenceOperation] = [
    Replace("X"),
    Undo,
    Preedit("temporary", 9, 0),
    PreeditUtf8("😀日本é", 10, 4),
    Preedit("", 0, 0),
    Preedit("pq", 0, 2),
    Preedit("", 0, 0),
    Commit("bc"),
    Redo,
    Undo,
    Preedit("p", 1, 0),
    Preedit("", 0, 0),
    Commit(""),
    Undo,
    Preedit("pq", 2, 0),
    Preedit("", 0, 0),
    Cancel,
    Preedit("p", 0, 1),
    Focus(false),
    PreeditUtf8("😀", -1, 3),
    Commit("ignored"),
    Focus(true),
    Redo,
    Undo,
  ]
  for index in 0..<operations.length() {
    let (next_field, next_state) = composition_reference_run_operation(
      field,
      state,
      operations[index],
      "long trace operation=\{index}",
    )
    field = next_field
    state = next_state
  }
}

///|
test "composition reference zero length and boundary selections preserve original ranges" {
  for
    (text, anchor, head) in [
      ("", 0, 0),
      ("abc", 0, 0),
      ("abc", 3, 3),
      ("abc", 0, 3),
      ("abc", 3, 0),
      ("a😀bc", 5, 0),
      ("a😀bc", 0, 5),
    ] {
    let initial = composition_reference_start(text, anchor, head)
    let base = composition_reference_field(initial)
    let (preview, preview_state) = composition_reference_run_operation(
      base,
      initial,
      PreeditUtf8("😀é", 6, 0),
      "boundary preview \{text} \{anchor},\{head}",
    )
    let (repeated, repeated_state) = composition_reference_run_operation(
      preview,
      preview_state,
      Preedit("q", 0, 1),
      "boundary repeated preview",
    )
    let (cleared, cleared_state) = composition_reference_run_operation(
      repeated,
      repeated_state,
      Preedit("", 0, 0),
      "boundary clear",
    )
    for resolution in [Cancel, Focus(false), Commit(""), Commit("😀")] {
      let (resolved, resolved_state) = composition_reference_run_operation(
        cleared, cleared_state, resolution, "boundary resolution",
      )
      let _ = composition_reference_run_operation(
        resolved,
        resolved_state,
        Undo,
        "boundary resolution undo",
      )
    }
  }
}

///|
test "composition reference unfocused wrappers ignore invalid input without callbacks" {
  let initial = composition_reference_start("abcd", 3, 1)
  let field = composition_reference_field(initial).with_focus(false).unwrap()
  let expected = composition_reference_step(initial, Focus(false)).unwrap()
  let measured = [0]
  let admitted = [0]
  let measure = fn(document) {
    measured[0] += 1
    composition_reference_measure(document)
  }
  let admit = fn(_, _) {
    admitted[0] += 1
    Ok(())
  }
  let malformed = "😀".unsafe_substring(start=0, end=1)
  for
    (text, anchor, head) in [
      (malformed, -1, @int.MAX_VALUE),
      ("😀", 1, 3),
      ("", -1, 1),
      ("\n", 0, 1),
      ("x".repeat(4097), 0, 0),
    ] {
    let actual = field.update_composition_utf8(
      text, anchor, head, measure, admit,
    )
    assert_true(actual is Ok(_))
    assert_true(composition_reference_matches(actual.unwrap(), expected))
  }
  for text in [malformed, "", "\n", "x".repeat(4097), "final"] {
    // An unfocused field without an owner returns itself even for a commit.
    let actual = field.commit_composition(text, measure, admit)
    assert_true(actual is Ok(_))
    assert_true(composition_reference_matches(actual.unwrap(), expected))
  }
  assert_eq(measured[0], 0)
  assert_eq(admitted[0], 0)
  assert_true(composition_reference_matches(field, expected))
}

///|
fn composition_reference_tall_measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, TextFieldError] {
  let base = composition_reference_measure(document).unwrap()
  let height = if document.text() == "abcd" { 24.0 } else { 16.0 }
  let bounds = @primitives.Rect::new(
    0.0,
    0.0,
    base.logical_rect().size().width(),
    height,
  ).unwrap()
  match
    @text_layout.TextMeasurement::new(
      document,
      bounds,
      bounds,
      12.0,
      1,
      0,
      base.carets(),
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(MeasurementFailed)
  }
}

///|
test "composition reference failed resize retains independent original geometry and redo" {
  let initial = composition_reference_start("abcd", 3, 1)
  let admit = fn(_, _) { Ok(()) }
  let document = @text.TextDocument::new("abcd")
    .unwrap()
    .with_selection(@text.TextSelection::new(3, 1).unwrap())
    .unwrap()
  let original = TextField::new(
      32UL,
      @primitives.Rect::new(0.0, 0.0, 160.0, 36.0).unwrap(),
      10.0,
      document,
      composition_reference_tall_measure,
      admit,
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let edited = original
    .replace_selection("X", composition_reference_tall_measure, admit)
    .unwrap()
  let edited_state = composition_reference_step(initial, Replace("X")).unwrap()
  assert_true(composition_reference_matches(edited, edited_state))
  let undone = edited.undo(composition_reference_tall_measure, admit).unwrap()
  let undone_state = composition_reference_step(edited_state, Undo).unwrap()
  assert_true(composition_reference_matches(undone, undone_state))
  let preview = undone
    .update_composition_utf8(
      "pq", 2, 0, composition_reference_tall_measure, admit,
    )
    .unwrap()
  let preview_state = composition_reference_step(
    undone_state,
    PreeditUtf8("pq", 2, 0),
  ).unwrap()
  assert_true(composition_reference_matches(preview, preview_state))
  assert_eq(preview.measurement().logical_rect().size().height(), 16.0)
  assert_eq(
    preview.composition.unwrap().measurement.logical_rect().size().height(),
    24.0,
  )
  // Preview height 16 fits content height 20, original height 24 does not.
  let narrow_height = @primitives.Rect::new(12.0, 16.0, 160.0, 28.0).unwrap()
  assert_true(preview.with_bounds(narrow_height) is Err(UnsupportedLayout))
  assert_true(composition_reference_matches(preview, preview_state))
  assert_eq(preview.bounds().left(), 0.0)
  assert_eq(preview.bounds().top(), 0.0)
  assert_eq(preview.bounds().size().height(), 36.0)
  let accepted_bounds = @primitives.Rect::new(12.0, 16.0, 200.0, 40.0).unwrap()
  let resized = preview.with_bounds(accepted_bounds).unwrap()
  let resized_state = { ..preview_state, revision: preview_state.revision + 1, }
  assert_true(composition_reference_matches(resized, resized_state))
  let blurred = resized.with_focus(false).unwrap()
  let blurred_state = composition_reference_step(resized_state, Focus(false)).unwrap()
  assert_true(composition_reference_matches(blurred, blurred_state))
  assert_true(blurred.bounds() == accepted_bounds)
  assert_eq(blurred.measurement().logical_rect().size().height(), 24.0)
  // The independent original retains its reverse selection and redo endpoint.
  assert_eq(blurred.selection().anchor(), 3)
  assert_eq(blurred.selection().head(), 1)
  let refocused = blurred.with_focus(true).unwrap()
  let refocused_state = composition_reference_step(blurred_state, Focus(true)).unwrap()
  let redone = refocused
    .redo(composition_reference_tall_measure, admit)
    .unwrap()
  let redone_state = composition_reference_step(refocused_state, Redo).unwrap()
  assert_true(composition_reference_matches(redone, redone_state))
  assert_true(composition_reference_matches(preview, preview_state))
}
