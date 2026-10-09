///|
/// The reference stores ordinary rows and indices, independently of Picker's
/// scroll/element machinery. Fixed seeds make every failing trace replayable.
priv struct PaletteReference {
  rows : Array[CommandMetadata]
  query : String
  active : Int?
  start : Int
}

///|
fn palette_reference_visible(
  rows : Array[CommandMetadata],
  active : Int?,
  start : Int,
) -> Int {
  let maximum = if rows.length() > 8 { rows.length() - 8 } else { 0 }
  let candidate = match active {
    Some(index) if index < start => index
    Some(index) if index >= start + 8 => index - 7
    _ => start
  }
  if candidate < 0 {
    0
  } else if candidate > maximum {
    maximum
  } else {
    candidate
  }
}

///|
fn palette_reference_first(rows : Array[CommandMetadata]) -> Int? {
  for index in 0..<rows.length() {
    if rows[index].is_enabled() {
      return Some(index)
    }
  }
  None
}

///|
fn palette_reference_filter(
  state : PaletteReference,
  commands : Array[CommandMetadata],
  query : String,
) -> PaletteReference {
  if state.query == query {
    return state
  }
  let rows = commands.filter(command => command.label().contains(query))
  let prior = state.active.map(index => state.rows[index].id())
  let mut active = palette_reference_first(rows)
  for index in 0..<rows.length() {
    if rows[index].is_enabled() && prior == Some(rows[index].id()) {
      active = Some(index)
    }
  }
  { rows, query, active, start: palette_reference_visible(rows, active, 0), }
}

///|
fn palette_reference_navigate(
  state : PaletteReference,
  direction : Int,
) -> PaletteReference {
  if direction == 0 {
    return state
  }
  let order = if direction < 0 { -1 } else { 1 }
  let mut cursor = match state.active {
    Some(index) => index + order
    None => if order < 0 { state.rows.length() - 1 } else { 0 }
  }
  while cursor >= 0 && cursor < state.rows.length() {
    if state.rows[cursor].is_enabled() {
      return {
        ..state,
        active: Some(cursor),
        start: palette_reference_visible(state.rows, Some(cursor), state.start),
      }
    }
    cursor += order
  }
  state
}

///|
fn palette_reference_assert(
  picker : Picker,
  reference : PaletteReference,
  context : String,
) -> Unit raise {
  assert_eq(picker.query(), reference.query, msg=context)
  assert_eq(picker.match_count(), reference.rows.length(), msg=context)
  assert_eq(picker.active_index(), reference.active, msg=context)
  assert_eq(picker.visible_start(), reference.start, msg=context)
  let visible = picker.visible_commands()
  let remaining = reference.rows.length() - reference.start
  assert_eq(
    visible.length(),
    if remaining > 8 {
      8
    } else {
      remaining
    },
    msg=context,
  )
  for index in 0..<reference.rows.length() {
    let expected = reference.rows[index]
    let actual = picker.command_at(index).unwrap()
    assert_eq(actual.id(), expected.id(), msg=context)
    assert_eq(actual.label(), expected.label(), msg=context)
    assert_eq(actual.is_enabled(), expected.is_enabled(), msg=context)
  }
  assert_true(picker.command_at(-1) is None, msg=context)
  assert_true(picker.command_at(reference.rows.length()) is None, msg=context)
  for index in 0..<visible.length() {
    assert_eq(
      visible[index].id(),
      reference.rows[reference.start + index].id(),
      msg=context,
    )
  }
  assert_eq(
    picker.active_command().map(command => command.id()),
    reference.active.map(index => reference.rows[index].id()),
    msg=context,
  )
}

///|
test "palette fixed seed filter navigation traces match independent viewport oracle" {
  for count in [0, 1, 8, 9, 32, 128] {
    for seed in [1, 1777, 4242, 65535] {
      let commands = []
      for index in 0..<count {
        commands.push(
          CommandMetadata::new(
            "command.\{index}",
            if index % 3 == 0 {
              "日本 \{index}"
            } else {
              "abc \{index}"
            },
            (index + seed) % 5 != 0,
          ).unwrap(),
        )
      }
      let mut picker = Picker::new(commands).unwrap()
      let mut reference = {
        rows: commands,
        query: "",
        active: palette_reference_first(commands),
        start: 0,
      }
      let mut random = seed
      for step in 0..<256 {
        random = (random * 25173 + 13849) % 65536
        let operation = random / 256 % 12
        if operation < 7 {
          let query = ["", "日", "abc", "ABC", "missing", "1", "本"][operation]
          picker = picker.filter(query).unwrap()
          reference = palette_reference_filter(reference, commands, query)
        } else {
          let direction = [0, 1, -1, 42, -42][operation - 7]
          picker = picker.navigate(direction)
          reference = palette_reference_navigate(reference, direction)
        }
        palette_reference_assert(
          picker,
          reference,
          "count=\{count} seed=\{seed} step=\{step} operation=\{operation}",
        )
      }
    }
  }
}

///|
test "palette retained command and equal query preserve viewport after caret change" {
  let values = []
  for index in 0..<12 {
    values.push(
      CommandMetadata::new(
        "id\{index}",
        if index < 4 {
          "old"
        } else {
          "keep"
        },
        index != 8,
      ).unwrap(),
    )
  }
  let mut picker = Picker::new(values).unwrap()
  for _ in 0..<10 {
    picker = picker.navigate(1)
  }
  assert_eq(picker.active_command().unwrap().id(), "id11")
  assert_eq(picker.visible_start(), 4)
  picker = picker.filter("keep").unwrap()
  assert_eq(picker.active_index(), Some(7))
  assert_eq(picker.active_command().unwrap().id(), "id11")
  picker = picker.navigate(-1)
  let start = picker.visible_start()
  let active = picker.active_index()
  picker = picker.filter("keep").unwrap()
  assert_eq(picker.active_index(), active)
  assert_eq(picker.visible_start(), start)
  assert_true(picker.filter("\u{7f}") is Err(QueryTooLarge))
  assert_eq(picker.query(), "keep")
}

///|
test "palette terminal stale epoch deferred action and reopening regression trace" {
  let calls = Ref(0)
  let palette = palette_test_component(() => calls.val += 1)
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  let epoch = palette.open_epoch()
  assert_true(palette.open(tree) is Err(AlreadyOpen))
  let close = palette_test_input(palette, palette_test_key(@primitives.Enter))
  assert_true(
    close.effect is Closed(epoch=value, command_id=Some("open.japanese")) &&
    value == epoch,
  )
  assert_false(palette.field().is_focused())
  assert_eq(calls.val, 0)
  assert_true(palette.open(tree) is Err(AlreadyOpen))
  palette.finish_close(epoch + 1, tree).unwrap()
  assert_eq(calls.val, 0)
  assert_true(palette.open(tree) is Err(AlreadyOpen))
  assert_true(
    palette_test_input(
      palette,
      palette_test_key(@primitives.Enter, repeat=true),
    ).consumed,
  )
  assert_false(
    palette_test_input(palette, palette_test_key(@primitives.ArrowDown)).consumed,
  )
  assert_false(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Escape,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Enter,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  assert_false(
    palette_test_input(palette, palette_test_key(@primitives.Enter)).consumed,
  )
  palette.finish_close(epoch, tree).unwrap()
  assert_eq(calls.val, 1)
  palette.open(tree).unwrap()
  let next = palette.open_epoch()
  assert_eq(next, epoch + 1)
  palette.finish_close(epoch, tree).unwrap()
  assert_true(palette.is_open())
  assert_true(
    palette.blur().unwrap() is Closed(epoch=value, command_id=None) &&
    value == next,
  )
  palette.finish_close(epoch, tree).unwrap()
  assert_true(palette.open(tree) is Err(AlreadyOpen))
  palette.finish_close(next, tree).unwrap()
  palette.finish_close(next, tree).unwrap()
  assert_eq(calls.val, 1)
  assert_eq(tree.val.focused(), Some(9))
}

///|
test "palette empty and disabled Enter never closes and blur Escape never dispatch" {
  for empty in [false, true] {
    let calls = Ref(0)
    let metadata = CommandMetadata::new("disabled", "disabled", false).unwrap()
    let commands = if empty {
      []
    } else {
      [
        PaletteCommand::new(
          metadata,
          palette_test_binding("disabled", () => calls.val += 1),
        ),
      ]
    }
    let palette = CommandPalette::new(palette_test_field(), commands).unwrap()
    let tree = palette_test_tree()
    palette.open(tree).unwrap()
    for key in [@primitives.ArrowDown, @primitives.ArrowUp, @primitives.Enter] {
      assert_true(palette_test_input(palette, palette_test_key(key)).consumed)
      assert_true(palette.is_open())
    }
    let closed = palette_test_input(
      palette,
      palette_test_key(@primitives.Escape),
    )
    assert_true(closed.consumed)
    let effect = closed.effect
    assert_true(effect is Closed(command_id=None, ..))
    palette.finish_close(palette.open_epoch(), tree).unwrap()
    assert_eq(calls.val, 0)
  }
}

///|
test "palette rejected install is atomic and constructor enforces initial ownership" {
  let palette = palette_test_component(() => ())
  let tree = palette_test_tree()
  assert_true(palette.install_field(palette_test_field()) is Err(InvalidField))
  assert_true(
    CommandPalette::new(palette_test_field().with_focus(true).unwrap(), [])
    is Err(InvalidField),
  )
  palette.open(tree).unwrap()
  let original = palette.field()
  assert_true(
    palette.install_field(original.with_focus(false).unwrap())
    is Err(InvalidField),
  )
  let wrong = @text_field.TextField::new(
      3,
      palette_test_rect(0.0, 0.0, 400.0, 36.0),
      18.0,
      palette_test_document(""),
      palette_test_measure,
      palette_test_admit,
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  assert_true(palette.install_field(wrong) is Err(InvalidField))
  let oversized = original
    .handle_input(
      @primitives.TextInput(text="日".repeat(86)),
      palette_test_measure,
      palette_test_admit,
      palette_test_hit,
    )
    .unwrap().0
  assert_true(palette.install_field(oversized) is Err(QueryTooLarge))
  assert_true(palette.field().document() == original.document())
  assert_eq(palette.field().revision(), original.revision())
  assert_eq(palette.picker().query(), "")
  palette.epoch = @int.MAX_VALUE
  ignore(palette.blur().unwrap())
  palette.finish_close(palette.open_epoch(), tree).unwrap()
  assert_true(palette.open(tree) is Err(EpochExhausted))
  assert_eq(tree.val.focused(), Some(9))
}

///|
fn palette_property_matches(
  picker : Picker,
  expected : PaletteReference,
) -> Bool {
  if picker.query() != expected.query ||
    picker.match_count() != expected.rows.length() ||
    picker.active_index() != expected.active ||
    picker.visible_start() != expected.start {
    return false
  }
  if picker.command_at(-1) is Some(_) ||
    picker.command_at(expected.rows.length()) is Some(_) {
    return false
  }
  for index in 0..<expected.rows.length() {
    if picker.command_at(index).map(command => command.id()) !=
      Some(expected.rows[index].id()) {
      return false
    }
  }
  let visible = picker.visible_commands()
  let remaining = expected.rows.length() - expected.start
  if visible.length() != (if remaining > 8 { 8 } else { remaining }) {
    return false
  }
  for index in 0..<visible.length() {
    if visible[index].id() != expected.rows[expected.start + index].id() {
      return false
    }
  }
  picker.active_command().map(command => command.id()) ==
  expected.active.map(index => expected.rows[index].id())
}

///|
// Stable suite ID: command-palette.reference-filter-selection-v1
// QuickCheck preserves minimized operation/candidate arrays in turtles' real
// Property attribution and generated regression trace artifacts.
test "property palette filter selection and visible list match shrinkable traces" {
  @quickcheck.check(
    (trace : (Array[Bool], Array[Int])) => {
      let (enabled, operations) = trace
      let commands = []
      for index in 0..<enabled.length() {
        commands.push(
          CommandMetadata::new(
            "id\{index}",
            if index % 2 == 0 {
              "日本 \{index}"
            } else {
              "abc \{index}"
            },
            enabled[index],
          ).unwrap(),
        )
      }
      let mut picker = Picker::new(commands).unwrap()
      let first = palette_reference_first(commands)
      let mut expected = {
        rows: commands,
        query: "",
        active: first,
        start: palette_reference_visible(commands, first, 0),
      }
      if !palette_property_matches(picker, expected) {
        return false
      }
      for value in operations {
        let operation = value & 15
        if operation < 7 {
          let query = ["", "日", "abc", "ABC", "missing", "1", "本"][operation]
          picker = picker.filter(query).unwrap()
          expected = palette_reference_filter(expected, commands, query)
        } else {
          let direction = if operation == 7 {
            0
          } else if operation % 2 == 0 {
            1
          } else {
            -1
          }
          picker = picker.navigate(direction)
          expected = palette_reference_navigate(expected, direction)
        }
        if !palette_property_matches(picker, expected) {
          return false
        }
      }
      true
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=8367235218704275144,
  )
}

///|
// Regressions found by the first actual turtles run, not invented kills.
test "mutation regression metadata rejects empty malformed and every separator boundary" {
  let broken_high = "😀".unsafe_substring(start=0, end=1)
  let broken_low = "😀".unsafe_substring(start=1, end=2)
  for
    invalid in [
      "", broken_high, broken_low, "\u{0000}", "\u{001f}", "\u{007f}", "\u{0080}",
      "\u{009f}", "\u{2028}", "\u{2029}",
    ] {
    assert_true(
      CommandMetadata::new(invalid, "valid", true) is Err(InvalidMetadata),
    )
    assert_true(
      CommandMetadata::new("valid", invalid, true) is Err(InvalidMetadata),
    )
  }
  let picker = Picker::new([]).unwrap()
  for
    invalid in [
      broken_high, broken_low, "\u{001f}", "\u{007f}", "\u{009f}", "\u{2028}", "\u{2029}",
    ] {
    assert_true(picker.filter(invalid) is Err(QueryTooLarge))
  }
  assert_true(CommandMetadata::new(" ", " ", true) is Ok(_))
  assert_true(CommandMetadata::new("valid", "\u{00a0}", true) is Ok(_))
  assert_true(picker.filter("") is Ok(_))
  let nonempty = @text_field.TextField::new(
    2,
    palette_test_rect(0.0, 0.0, 400.0, 36.0),
    18.0,
    palette_test_document("old query"),
    palette_test_measure,
    palette_test_admit,
  ).unwrap()
  assert_true(CommandPalette::new(nonempty, []) is Err(InvalidField))
}

///|
// The first real mutation run exposed missing observations for these public
// paths: exact callback lookup, modifier containment, preview byte admission,
// repeated/composing-key consumption, field Blur and already-closed Blur.
test "mutation regression lifecycle input containment and exact command dispatch matrix" {
  let calls = Array::make(3, 0)
  let commands = []
  for index in 0..<3 {
    let id = ["first", "disabled", "third"][index]
    let row = CommandMetadata::new(id, id + " 日本", index != 1).unwrap()
    commands.push(
      PaletteCommand::new(
        row,
        palette_test_binding(id, () => calls[index] += 1),
      ),
    )
  }
  let palette = CommandPalette::new(palette_test_field(), commands).unwrap()
  let tree = palette_test_tree()
  assert_true(palette.blur().unwrap() is None)
  palette.open(tree).unwrap()
  let held_escape = palette_test_input(
    palette,
    palette_test_key(@primitives.Escape, repeat=true),
  )
  assert_true(held_escape.consumed)
  assert_true(held_escape.effect is None)
  assert_true(palette.is_open())
  let held_down = palette_test_input(
    palette,
    palette_test_key(@primitives.ArrowDown, repeat=true),
  )
  assert_true(held_down.consumed)
  assert_eq(palette.picker().active_command().unwrap().id(), "third")
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.ArrowUp)).consumed,
  )
  let control = @primitives.Modifiers::new(
    shift=false,
    control=true,
    alt=false,
    meta=false,
  )
  for key in [@primitives.ArrowDown, @primitives.Enter] {
    let input = palette_test_input(
      palette,
      @primitives.KeyPressed(key~, modifiers=control, repeat=false),
    )
    assert_true(input.consumed)
    assert_true(input.effect is None)
    assert_true(palette.is_open())
    assert_eq(palette.picker().active_command().unwrap().id(), "first")
  }
  let preview = palette
    .field()
    .update_composition(
      "に",
      @text.TextSelection::new(1, 1).unwrap(),
      palette_test_measure,
      palette_test_admit,
    )
    .unwrap()
  palette.install_field_at(palette.open_epoch(), preview).unwrap()
  for
    key in [@primitives.ArrowDown, @primitives.Home, @primitives.Character("x")] {
    let input = palette_test_input(palette, palette_test_key(key))
    assert_true(input.consumed)
    assert_true(input.effect is None)
    assert_true(palette.field().is_composing())
    assert_eq(palette.picker().query(), "")
  }
  let repeated_escape = palette_test_input(
    palette,
    palette_test_key(@primitives.Escape, repeat=true),
  )
  assert_true(repeated_escape.consumed)
  assert_true(repeated_escape.effect is None)
  assert_true(palette.field().is_composing())
  let reserved_enter = palette_test_input(
    palette,
    palette_test_key(@primitives.Enter),
  )
  assert_true(reserved_enter.consumed)
  assert_true(reserved_enter.effect is None)
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Enter,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  let oversized = palette
    .field()
    .update_composition(
      "日".repeat(86),
      @text.TextSelection::new(86, 86).unwrap(),
      palette_test_measure,
      palette_test_admit,
    )
    .unwrap()
  assert_true(
    palette.install_field_at(palette.open_epoch(), oversized)
    is Err(QueryTooLarge),
  )
  assert_true(palette.field().document() == preview.document())
  assert_eq(palette.picker().query(), "")
  let cancelled = palette_test_input(
    palette,
    palette_test_key(@primitives.Escape),
  )
  assert_true(cancelled.consumed)
  assert_true(cancelled.effect is CompositionCancelled)
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Escape,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  let typed = palette_test_input(palette, @primitives.TextInput(text="third"))
  assert_true(typed.consumed)
  assert_true(typed.effect is None)
  assert_eq(palette.picker().active_command().unwrap().id(), "third")
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Home,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  let closed = palette_test_input(palette, palette_test_key(@primitives.Enter))
  assert_true(closed.consumed)
  assert_true(closed.effect is Closed(command_id=Some("third"), ..))
  palette.finish_close(palette.open_epoch(), tree).unwrap()
  assert_eq(calls[0], 0)
  assert_eq(calls[1], 0)
  assert_eq(calls[2], 1)
  assert_true(palette.blur().unwrap() is None)
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Enter,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  palette.open(tree).unwrap()
  let alt = @primitives.Modifiers::new(
    shift=false,
    control=false,
    alt=true,
    meta=false,
  )
  let blur = palette_test_input(
    palette,
    @primitives.KeyPressed(key=@primitives.Escape, modifiers=alt, repeat=false),
  )
  assert_true(blur.consumed)
  assert_true(blur.effect is Closed(command_id=None, ..))
  assert_false(palette.is_open())
  palette.finish_close(palette.open_epoch(), tree).unwrap()
  assert_eq(calls[2], 1)
}

///|
test "native key retirement requires exact closed and fully finished epoch" {
  let palette = palette_test_component(() => ())
  let tree = palette_test_tree()
  palette.open(tree).unwrap()
  let epoch = palette.open_epoch()
  ignore(palette_test_input(palette, palette_test_key(@primitives.Escape)))
  palette.retire_key_guard(epoch)
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Escape)).consumed,
  )
  palette.finish_close(epoch, tree).unwrap()
  palette.retire_key_guard(epoch + 1)
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Escape)).consumed,
  )
  palette.open(tree).unwrap()
  palette.retire_key_guard(palette.open_epoch())
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Escape)).consumed,
  )
  assert_true(palette.is_open())
  assert_true(
    palette_test_input(
      palette,
      @primitives.KeyReleased(
        key=@primitives.Escape,
        modifiers=@primitives.Modifiers::none(),
      ),
    ).consumed,
  )
  ignore(palette_test_input(palette, palette_test_key(@primitives.Escape)))
  let current = palette.open_epoch()
  palette.finish_close(current, tree).unwrap()
  palette.retire_key_guard(epoch)
  assert_true(
    palette_test_input(palette, palette_test_key(@primitives.Escape)).consumed,
  )
  palette.retire_key_guard(current)
  assert_false(
    palette_test_input(palette, palette_test_key(@primitives.Escape)).consumed,
  )
}

///|
// Real surviving mutant m-845a9112ed789d3b recomputed an equal query. Moving
// upward within a scrolled viewport must preserve the earlier window start.
test "mutation regression equal query preserves an upward navigated scroll window" {
  let rows = []
  for index in 0..<32 {
    rows.push(
      CommandMetadata::new("row\{index}", "row \{index}", true).unwrap(),
    )
  }
  let mut picker = Picker::new(rows).unwrap()
  for _ in 0..<24 {
    picker = picker.navigate(1)
  }
  assert_eq(picker.active_index(), Some(24))
  assert_eq(picker.visible_start(), 17)
  picker = picker.navigate(-1)
  assert_eq(picker.active_index(), Some(23))
  assert_eq(picker.visible_start(), 17)
  let equal = picker.filter("").unwrap()
  assert_eq(equal.active_index(), Some(23))
  assert_eq(equal.visible_start(), 17)
  assert_eq(equal.visible_commands()[0].id(), "row17")
}
