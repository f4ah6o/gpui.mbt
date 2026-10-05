///|
fn text_composition_pbt_index(value : Int, limit : Int) -> Int {
  let remainder = value % limit
  if remainder < 0 {
    remainder + limit
  } else {
    remainder
  }
}

///|
fn text_composition_pbt_source(values : Array[Int]) -> (String, Array[Int]) {
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
fn text_composition_pbt_reference_slice(
  values : Array[Int],
  start : Int,
  end : Int,
) -> String {
  let builder = StringBuilder()
  for index, value in values {
    if index >= start && index < end {
      builder.write_string(text_pbt_fragment(value))
    }
  }
  builder.to_string()
}

///|
fn text_composition_pbt_boundary(boundaries : Array[Int], choice : Int) -> Int {
  boundaries[text_composition_pbt_index(choice, boundaries.length())]
}

///|
fn text_composition_pbt_selection(
  values : Array[Int],
  anchor_choice : Int,
  head_choice : Int,
) -> @text.TextSelection {
  let (_, boundaries) = text_composition_pbt_source(values)
  @text.TextSelection::new(
    text_composition_pbt_boundary(boundaries, anchor_choice),
    text_composition_pbt_boundary(boundaries, head_choice),
  ).unwrap()
}

///|
fn text_composition_pbt_matches_preview(
  composition : @text.TextComposition,
  expected_text : String,
  expected_anchor : Int,
  expected_head : Int,
  mark_start : Int,
  mark_end : Int,
) -> Bool {
  composition.status() is @text.Active &&
  composition.document().text() == expected_text &&
  composition.document().selection() ==
  @text.TextSelection::new(expected_anchor, expected_head).unwrap() &&
  composition.marked_range() ==
  Some(@text.TextRange::new(mark_start, mark_end).unwrap())
}

///|
// Stable suite ID: text.utf16-composition.invariants
test "property composition previews replace the original and terminate exactly" {
  @quickcheck.check(
    (
      values : (
        Array[Int],
        Int,
        Int,
        Array[Int],
        Array[Int],
        Array[Int],
        Array[Int],
        Bool,
      ),
    ) => {
      let (
        scalars,
        first_range_choice,
        second_range_choice,
        preview_a_values,
        preview_b_values,
        preview_c_values,
        final_values,
        should_commit,
      ) = values
      let (source, source_boundaries) = text_composition_pbt_source(scalars)
      let first = text_composition_pbt_index(
        first_range_choice,
        source_boundaries.length(),
      )
      let second = text_composition_pbt_index(
        second_range_choice,
        source_boundaries.length(),
      )
      let start_index = if first <= second { first } else { second }
      let end_index = if first <= second { second } else { first }
      let range_start = source_boundaries[start_index]
      let range_end = source_boundaries[end_index]
      let range = @text.TextRange::new(range_start, range_end).unwrap()
      let original_selection = @text.TextSelection::new(range_end, range_start).unwrap()
      let original = @text.TextDocument::new(source)
        .unwrap()
        .with_selection(original_selection)
        .unwrap()
      let started = match @text.TextComposition::begin(original, range) {
        Ok(value) => value
        Err(_) => return false
      }

      let prefix = text_composition_pbt_reference_slice(scalars, 0, start_index)
      let suffix = text_composition_pbt_reference_slice(
        scalars,
        end_index,
        scalars.length(),
      )
      let preview_a_selection = text_composition_pbt_selection(
        preview_a_values, first_range_choice, second_range_choice,
      )
      let (preview_a_text, preview_a_boundaries) = text_composition_pbt_source(
        preview_a_values,
      )
      let expected_a_text = prefix + preview_a_text + suffix
      let expected_a_anchor = range_start + preview_a_selection.anchor()
      let expected_a_head = range_start + preview_a_selection.head()
      let expected_a_mark_end = range_start +
        preview_a_boundaries[preview_a_boundaries.length() - 1]
      let preview_a = match
        started.update(preview_a_text, preview_a_selection) {
        Ok(value) => value
        Err(_) => return false
      }
      if !text_composition_pbt_matches_preview(
          preview_a, expected_a_text, expected_a_anchor, expected_a_head, range_start,
          expected_a_mark_end,
        ) {
        return false
      }

      let preview_b_selection = text_composition_pbt_selection(
        preview_b_values, second_range_choice, first_range_choice,
      )
      let (preview_b_text, preview_b_boundaries) = text_composition_pbt_source(
        preview_b_values,
      )
      let expected_b_text = prefix + preview_b_text + suffix
      let expected_b_anchor = range_start + preview_b_selection.anchor()
      let expected_b_head = range_start + preview_b_selection.head()
      let expected_b_mark_end = range_start +
        preview_b_boundaries[preview_b_boundaries.length() - 1]
      let preview_b = match
        preview_a.update(preview_b_text, preview_b_selection) {
        Ok(value) => value
        Err(_) => return false
      }
      if !text_composition_pbt_matches_preview(
          preview_b, expected_b_text, expected_b_anchor, expected_b_head, range_start,
          expected_b_mark_end,
        ) ||
        !text_composition_pbt_matches_preview(
          preview_a, expected_a_text, expected_a_anchor, expected_a_head, range_start,
          expected_a_mark_end,
        ) {
        return false
      }

      let preview_c_selection = text_composition_pbt_selection(
        preview_c_values,
        first_range_choice,
        first_range_choice + second_range_choice,
      )
      let (preview_c_text, preview_c_boundaries) = text_composition_pbt_source(
        preview_c_values,
      )
      let expected_c_text = prefix + preview_c_text + suffix
      let expected_c_anchor = range_start + preview_c_selection.anchor()
      let expected_c_head = range_start + preview_c_selection.head()
      let expected_c_mark_end = range_start +
        preview_c_boundaries[preview_c_boundaries.length() - 1]
      let preview_c = match
        preview_b.update(preview_c_text, preview_c_selection) {
        Ok(value) => value
        Err(_) => return false
      }
      if !text_composition_pbt_matches_preview(
          preview_c, expected_c_text, expected_c_anchor, expected_c_head, range_start,
          expected_c_mark_end,
        ) ||
        !text_composition_pbt_matches_preview(
          preview_a, expected_a_text, expected_a_anchor, expected_a_head, range_start,
          expected_a_mark_end,
        ) ||
        !text_composition_pbt_matches_preview(
          preview_b, expected_b_text, expected_b_anchor, expected_b_head, range_start,
          expected_b_mark_end,
        ) ||
        started.document().text() != source ||
        started.document().selection() != original_selection ||
        original.text() != source ||
        original.selection() != original_selection {
        return false
      }

      let (final_text, final_boundaries) = text_composition_pbt_source(
        final_values,
      )
      if should_commit {
        let expected_text = prefix + final_text + suffix
        let expected_caret = range_start +
          final_boundaries[final_boundaries.length() - 1]
        match preview_c.commit(final_text) {
          Err(_) => false
          Ok(committed) =>
            committed.status() is @text.Committed &&
            committed.document().text() == expected_text &&
            committed.document().selection() ==
            @text.TextSelection::new(expected_caret, expected_caret).unwrap() &&
            committed.marked_range() is None &&
            text_composition_pbt_matches_preview(
              preview_a, expected_a_text, expected_a_anchor, expected_a_head, range_start,
              expected_a_mark_end,
            ) &&
            text_composition_pbt_matches_preview(
              preview_b, expected_b_text, expected_b_anchor, expected_b_head, range_start,
              expected_b_mark_end,
            ) &&
            text_composition_pbt_matches_preview(
              preview_c, expected_c_text, expected_c_anchor, expected_c_head, range_start,
              expected_c_mark_end,
            )
        }
      } else {
        match preview_c.cancel() {
          Err(_) => false
          Ok(cancelled) =>
            cancelled.status() is @text.Cancelled &&
            cancelled.document().text() == source &&
            cancelled.document().selection() == original_selection &&
            cancelled.marked_range() is None &&
            text_composition_pbt_matches_preview(
              preview_a, expected_a_text, expected_a_anchor, expected_a_head, range_start,
              expected_a_mark_end,
            ) &&
            text_composition_pbt_matches_preview(
              preview_b, expected_b_text, expected_b_anchor, expected_b_head, range_start,
              expected_b_mark_end,
            ) &&
            text_composition_pbt_matches_preview(
              preview_c, expected_c_text, expected_c_anchor, expected_c_head, range_start,
              expected_c_mark_end,
            )
        }
      }
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=4169804048700389933,
  )
}
