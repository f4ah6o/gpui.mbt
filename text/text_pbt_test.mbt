///|
fn text_pbt_fragment(value : Int) -> String {
  let reduced = value % 7
  let index = if reduced < 0 { reduced + 7 } else { reduced }
  match index {
    0 => "a"
    1 => "日"
    2 => "\u0301"
    3 => "😀"
    4 => "é"
    5 => "\n"
    _ => "\u0000"
  }
}

///|
fn text_pbt_source(values : Array[Int]) -> (String, Array[Int]) {
  let builder = StringBuilder()
  let boundaries = [0]
  let mut offset = 0
  for value in values {
    let fragment = text_pbt_fragment(value)
    builder.write_string(fragment)
    offset += fragment.length()
    boundaries.push(offset)
  }
  (builder.to_string(), boundaries)
}

///|
fn text_pbt_scalar_slice(values : Array[Int], start : Int, end : Int) -> String {
  let builder = StringBuilder()
  for index, value in values {
    if index >= start && index < end {
      builder.write_string(text_pbt_fragment(value))
    }
  }
  builder.to_string()
}

///|
fn text_pbt_index(value : Int, limit : Int) -> Int {
  let remainder = value % limit
  if remainder < 0 {
    remainder + limit
  } else {
    remainder
  }
}

///|
// Stable suite ID: text.utf16-replacement.invariants
test "property text edits preserve exact slices, length, selection, and snapshot" {
  @quickcheck.check(
    (values : (Array[Int], Int, Int, Int, Int)) => {
      let (scalars, first_choice, second_choice, replacement_a, replacement_b) = values
      let (source, boundaries) = text_pbt_source(scalars)
      let first_index = text_pbt_index(first_choice, boundaries.length())
      let second_index = text_pbt_index(second_choice, boundaries.length())
      let start_index = if first_index <= second_index {
        first_index
      } else {
        second_index
      }
      let end_index = if first_index <= second_index {
        second_index
      } else {
        first_index
      }
      let start = boundaries[start_index]
      let end = boundaries[end_index]
      let range = match @text.TextRange::new(start, end) {
        Ok(value) => value
        Err(_) => return false
      }
      let selection = match @text.TextSelection::new(end, start) {
        Ok(value) => value
        Err(_) => return false
      }
      let original = match @text.TextDocument::new(source) {
        Ok(value) => value
        Err(_) => return false
      }
      let selected = match original.with_selection(selection) {
        Ok(value) => value
        Err(_) => return false
      }
      let replacement = text_pbt_fragment(replacement_a) +
        text_pbt_fragment(replacement_b)
      let prefix = text_pbt_scalar_slice(scalars, 0, start_index)
      let selected_reference = text_pbt_scalar_slice(
        scalars, start_index, end_index,
      )
      let suffix = text_pbt_scalar_slice(scalars, end_index, scalars.length())
      let observed_prefix = match
        selected.slice(@text.TextRange::new(0, start).unwrap()) {
        Ok(value) => value
        Err(_) => return false
      }
      let observed_selected = selected.selected_text()
      let observed_suffix = match
        selected.slice(
          @text.TextRange::new(end, selected.utf16_length()).unwrap(),
        ) {
        Ok(value) => value
        Err(_) => return false
      }
      let expected_builder = StringBuilder()
      expected_builder.write_string(prefix)
      expected_builder.write_string(replacement)
      expected_builder.write_string(suffix)
      let expected = expected_builder.to_string()
      let expected_length = selected.utf16_length() -
        range.length() +
        replacement.length()
      match selected.replace_selection(replacement) {
        Ok(edited) => {
          let caret = start + replacement.length()
          edited.text() == expected &&
          edited.utf16_length() == expected_length &&
          edited.selection() == @text.TextSelection::new(caret, caret).unwrap() &&
          observed_prefix == prefix &&
          observed_selected == selected_reference &&
          observed_suffix == suffix &&
          selected.text() == source &&
          selected.selection() == selection &&
          original.text() == source &&
          original.selection() == @text.TextSelection::new(0, 0).unwrap() &&
          (start != end || edited.text() == prefix + replacement + suffix)
        }
        Err(_) => false
      }
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=17836885540012499121,
  )
}
