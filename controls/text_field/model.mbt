///|
/// Errors returned by the bounded, single-line text field model.
pub(all) enum TextFieldError {
  InvalidFontSize
  InvalidBounds
  MalformedText
  ForbiddenInput
  TextTooLarge
  UnsupportedLayout
  InvalidSelection
  MeasurementFailed
  AdmissionFailed
  HitTestFailed
  InvalidHitResult
  RevisionExhausted
} derive(Eq)

///|
pub extend TextFieldError with Eq::{not_equal, equal}

///|
/// A prepared field has passed portable geometry checks and native raster
/// admission. The clipboard owner may install the candidate only after a cut
/// write succeeds.
pub enum TextFieldAction {
  Copy(String)
  Cut(text~ : String, candidate~ : TextField)
  Paste
  Submit
  Blur
}

///|
/// Immutable bounded editing state. Text offsets and cursor stops are UTF-16
/// code-unit offsets supplied by the matching text measurement.
pub struct TextField {
  priv id : UInt64
  priv bounds : @primitives.Rect
  priv font_size : Double
  priv document : @text.TextDocument
  priv measurement : @text_layout.TextMeasurement
  priv focused : Bool
  priv scroll_offset : Double
  priv revision : Int
}

///|
const MAX_FIELD_UTF8_BYTES : Int = 4096

///|
const MAX_FIELD_FONT_SIZE : Double = 32.0

///|
const MAX_FIELD_WIDTH : Double = 2048.0

///|
const MAX_FIELD_HEIGHT : Double = 128.0

///|
const FIELD_PADDING : Double = 4.0

///|
fn finite_field_metric(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn field_text_forbidden(text : String) -> Bool {
  for scalar in text.iter() {
    let value = scalar.to_int()
    if (value >= 0x0000 && value <= 0x001F) ||
      (value >= 0x007F && value <= 0x009F) ||
      value == 0x2028 ||
      value == 0x2029 {
      return true
    }
  }
  false
}

///|
fn validate_field_text(
  document : @text.TextDocument,
) -> Result[Unit, TextFieldError] {
  match document.utf8_length() {
    Ok(length) if length <= MAX_FIELD_UTF8_BYTES => ()
    _ => return Err(TextTooLarge)
  }
  if field_text_forbidden(document.text()) {
    Err(ForbiddenInput)
  } else {
    Ok(())
  }
}

///|
fn field_stops(measurement : @text_layout.TextMeasurement) -> Array[Int] {
  let stops = []
  for caret in measurement.carets() {
    if caret.is_cursor_position() {
      stops.push(caret.utf16_offset())
    }
  }
  stops
}

///|
fn contains_stop(stops : Array[Int], target : Int) -> Bool {
  for stop in stops {
    if stop == target {
      return true
    }
  }
  false
}

///|
fn previous_stop(stops : Array[Int], target : Int) -> Int {
  let mut result = stops[0]
  for stop in stops {
    if stop >= target {
      return result
    }
    result = stop
  }
  result
}

///|
fn next_stop(stops : Array[Int], target : Int) -> Int {
  for stop in stops {
    if stop > target {
      return stop
    }
  }
  stops[stops.length() - 1]
}

///|
fn first_stop_at_or_after(stops : Array[Int], target : Int) -> Int {
  for stop in stops {
    if stop >= target {
      return stop
    }
  }
  stops[stops.length() - 1]
}

///|
fn rect_width(rect : @primitives.Rect) -> Double {
  rect.size().width()
}

///|
fn rect_height(rect : @primitives.Rect) -> Double {
  rect.size().height()
}

///|
fn validate_field_measurement(
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
  validate_selection : Bool,
) -> Result[Unit, TextFieldError] {
  if measurement.document() != document ||
    measurement.line_count() != 1 ||
    measurement.unknown_glyph_count() != 0 {
    return Err(UnsupportedLayout)
  }
  let logical = measurement.logical_rect()
  let ink = measurement.ink_rect()
  if rect_width(logical) > MAX_FIELD_WIDTH ||
    rect_height(logical) > MAX_FIELD_HEIGHT ||
    rect_width(ink) > MAX_FIELD_WIDTH ||
    rect_height(ink) > MAX_FIELD_HEIGHT ||
    logical.left() != 0.0 ||
    logical.top() != 0.0 ||
    logical.right() > MAX_FIELD_WIDTH ||
    // The shared raster path anchors runs at the logical origin, so ink that
    // overhangs to the left or above it would be cropped in this first slice.
    ink.left() < 0.0 ||
    ink.right() > MAX_FIELD_WIDTH ||
    ink.top() < 0.0 ||
    ink.bottom() > MAX_FIELD_HEIGHT ||
    measurement.first_line_baseline() > MAX_FIELD_HEIGHT ||
    measurement.first_line_baseline() > logical.bottom() {
    return Err(UnsupportedLayout)
  }
  let carets = measurement.carets()
  let stops = []
  let mut previous_x : Double? = None
  for caret in carets {
    if caret.is_cursor_position() {
      let strong = caret.strong()
      let weak = caret.weak()
      if strong != weak ||
        strong.left() < 0.0 ||
        strong.right() > logical.right() ||
        strong.top() < logical.top() ||
        strong.bottom() > logical.bottom() ||
        rect_height(strong) <= 0.0 {
        return Err(UnsupportedLayout)
      }
      match previous_x {
        Some(x) if strong.left() < x => return Err(UnsupportedLayout)
        _ => ()
      }
      previous_x = Some(strong.left())
      stops.push(caret.utf16_offset())
    }
  }
  if stops.length() == 0 ||
    stops[0] != 0 ||
    stops[stops.length() - 1] != document.utf16_length() {
    return Err(UnsupportedLayout)
  }
  if !validate_selection {
    return Ok(())
  }
  let selection = document.selection()
  if !contains_stop(stops, selection.anchor()) ||
    !contains_stop(stops, selection.head()) {
    return Err(InvalidSelection)
  }
  Ok(())
}

///|
fn rebase_field_measurement(
  source : @text_layout.TextMeasurement,
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, TextFieldError] {
  match
    @text_layout.TextMeasurement::new(
      document,
      source.logical_rect(),
      source.ink_rect(),
      source.first_line_baseline(),
      source.line_count(),
      source.unknown_glyph_count(),
      source.carets(),
    ) {
    Ok(measurement) => Ok(measurement)
    Err(_) => Err(UnsupportedLayout)
  }
}

///|
fn field_content_bounds(bounds : @primitives.Rect) -> @primitives.Rect {
  let width = rect_width(bounds)
  let height = rect_height(bounds)
  let inset_x = if width < FIELD_PADDING * 2.0 {
    width / 2.0
  } else {
    FIELD_PADDING
  }
  let inset_y = if height < FIELD_PADDING * 2.0 {
    height / 2.0
  } else {
    FIELD_PADDING
  }
  @primitives.Rect::new(
    bounds.left() + inset_x,
    bounds.top() + inset_y,
    width - inset_x * 2.0,
    height - inset_y * 2.0,
  ).unwrap()
}

///|
fn max_field_extent(field : TextField) -> Double {
  let logical = field.measurement.logical_rect()
  let ink = field.measurement.ink_rect()
  let logical_extent = logical.right() - logical.left()
  let ink_extent = ink.right() - logical.left()
  let caret_extent = match
    field.measurement.caret_at(field.document.utf16_length()) {
    Ok(caret) => caret.strong().left() - logical.left()
    Err(_) => logical_extent
  }
  let mut extent = logical_extent
  if ink_extent > extent {
    extent = ink_extent
  }
  if caret_extent > extent {
    extent = caret_extent
  }
  if extent < 0.0 {
    0.0
  } else {
    extent
  }
}

///|
fn clamp_field_scroll(field : TextField, value : Double) -> Double {
  let viewport_width = rect_width(field_content_bounds(field.bounds))
  let usable_width = if viewport_width > 1.0 {
    viewport_width - 1.0
  } else {
    0.0
  }
  let maximum = max_field_extent(field) - usable_width
  let max_scroll = if maximum > 0.0 { maximum } else { 0.0 }
  if value < 0.0 {
    0.0
  } else if value > max_scroll {
    max_scroll
  } else {
    value
  }
}

///|
fn field_scroll_for_head(field : TextField, head : Int) -> Double {
  let caret = match field.measurement.caret_at(head) {
    Ok(value) => value
    Err(_) => return field.scroll_offset
  }
  let logical = field.measurement.logical_rect()
  let x = caret.strong().left() - logical.left()
  let viewport_width = rect_width(field_content_bounds(field.bounds))
  let usable_width = if viewport_width > 1.0 {
    viewport_width - 1.0
  } else {
    0.0
  }
  let mut offset = field.scroll_offset
  if x < offset {
    offset = x
  } else if x > offset + usable_width {
    offset = x - usable_width
  }
  clamp_field_scroll(field, offset)
}

///|
fn bump_field_revision(revision : Int) -> Result[Int, TextFieldError] {
  if revision < 0 || revision >= @int.MAX_VALUE {
    Err(RevisionExhausted)
  } else {
    Ok(revision + 1)
  }
}

///|
test "bounded revision rejects exhaustion" {
  assert_true(bump_field_revision(@int.MAX_VALUE) is Err(RevisionExhausted))
}

///|
fn field_without_action(
  value : Result[TextField, TextFieldError],
) -> Result[(TextField, TextFieldAction?), TextFieldError] {
  match value {
    Ok(field) => Ok((field, None))
    Err(error) => Err(error)
  }
}

///|
fn field_changed_selection(
  field : TextField,
  document : @text.TextDocument,
  focused : Bool,
) -> Result[TextField, TextFieldError] {
  let focus_changed = focused != field.focused
  let document_changed = document != field.document
  if !focus_changed && !document_changed {
    return Ok(field)
  }
  let revision = match bump_field_revision(field.revision) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let measurement = if document_changed {
    match rebase_field_measurement(field.measurement, document) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    field.measurement
  }
  let base = { ..field, document, measurement, focused, revision, }
  let scroll_offset = field_scroll_for_head(base, document.selection().head())
  Ok({ ..base, scroll_offset, })
}

///|
/// Construct a field after validating its initial text and synchronous layout
/// admission. Measurement callbacks must return a copied snapshot for the
/// exact requested document.
pub fn TextField::new(
  id : UInt64,
  bounds : @primitives.Rect,
  font_size : Double,
  document : @text.TextDocument,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  if !finite_field_metric(font_size) ||
    font_size <= 0.0 ||
    font_size > MAX_FIELD_FONT_SIZE {
    return Err(InvalidFontSize)
  }
  let content = field_content_bounds(bounds)
  if rect_width(content) < 1.0 || rect_height(content) < font_size {
    return Err(InvalidBounds)
  }
  match validate_field_text(document) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let measurement = match measure(document) {
    Ok(value) => value
    Err(_) => return Err(MeasurementFailed)
  }
  match validate_field_measurement(document, measurement, true) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match admit(document, measurement) {
    Ok(_) => ()
    Err(_) => return Err(AdmissionFailed)
  }
  let provisional : TextField = {
    id,
    bounds,
    font_size,
    document,
    measurement,
    focused: false,
    scroll_offset: 0.0,
    revision: 0,
  }
  Ok({
    ..provisional,
    scroll_offset: field_scroll_for_head(
      provisional,
      document.selection().head(),
    ),
  })
}

///|
fn prepare_field_replacement(
  field : TextField,
  range : @text.TextRange,
  replacement : String,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  let replacement_document = match @text.TextDocument::new(replacement) {
    Ok(value) => value
    Err(@text.MalformedUtf16) => return Err(MalformedText)
    Err(_) => return Err(InvalidSelection)
  }
  match validate_field_text(replacement_document) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let removed_text = match field.document.slice(range) {
    Ok(value) => value
    Err(_) => return Err(InvalidSelection)
  }
  let removed_document = match @text.TextDocument::new(removed_text) {
    Ok(value) => value
    Err(_) => return Err(InvalidSelection)
  }
  let old_bytes = match field.document.utf8_length() {
    Ok(value) => value
    Err(_) => return Err(TextTooLarge)
  }
  let removed_bytes = match removed_document.utf8_length() {
    Ok(value) => value
    Err(_) => return Err(InvalidSelection)
  }
  let inserted_bytes = match replacement_document.utf8_length() {
    Ok(value) => value
    Err(_) => return Err(TextTooLarge)
  }
  if removed_bytes > old_bytes ||
    inserted_bytes > MAX_FIELD_UTF8_BYTES ||
    old_bytes - removed_bytes > MAX_FIELD_UTF8_BYTES - inserted_bytes {
    return Err(TextTooLarge)
  }
  let intermediate = match field.document.replace(range, replacement) {
    Ok(value) => value
    Err(@text.MalformedUtf16) => return Err(MalformedText)
    Err(_) => return Err(InvalidSelection)
  }
  if intermediate == field.document {
    return Ok(field)
  }
  match validate_field_text(intermediate) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let measurement = match measure(intermediate) {
    Ok(value) => value
    Err(_) => return Err(MeasurementFailed)
  }
  match validate_field_measurement(intermediate, measurement, false) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let desired_head = range.start() + replacement.length()
  let final_head = first_stop_at_or_after(
    field_stops(measurement),
    desired_head,
  )
  let final_document = match
    intermediate.with_selection(
      @text.TextSelection::new(final_head, final_head).unwrap(),
    ) {
    Ok(value) => value
    Err(_) => return Err(InvalidSelection)
  }
  let final_measurement = if final_document == intermediate {
    measurement
  } else {
    match rebase_field_measurement(measurement, final_document) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  match validate_field_measurement(final_document, final_measurement, true) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let revision = match bump_field_revision(field.revision) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match admit(final_document, final_measurement) {
    Ok(_) => ()
    Err(_) => return Err(AdmissionFailed)
  }
  let candidate = {
    ..field,
    document: final_document,
    measurement: final_measurement,
    revision,
  }
  Ok({
    ..candidate,
    scroll_offset: field_scroll_for_head(candidate, final_head),
  })
}

///|
/// Replace the current selection with one complete committed or pasted string.
/// The whole candidate is validated and admitted before a new value is returned.
pub fn TextField::replace_selection(
  self : TextField,
  replacement : String,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  if !self.focused {
    return Ok(self)
  }
  prepare_field_replacement(
    self,
    self.document.selection().normalized_range(),
    replacement,
    measure,
    admit,
  )
}

///|
/// Change logical focus without changing document or selection. Native owners
/// should arm or disarm their input target before installing this value.
pub fn TextField::with_focus(
  self : TextField,
  focused : Bool,
) -> Result[TextField, TextFieldError] {
  field_changed_selection(self, self.document, focused)
}

///|
/// Return a copy with new viewport bounds and a scroll offset that still keeps
/// its active head caret visible.
pub fn TextField::with_bounds(
  self : TextField,
  bounds : @primitives.Rect,
) -> Result[TextField, TextFieldError] {
  if bounds == self.bounds {
    return Ok(self)
  }
  let content = field_content_bounds(bounds)
  if rect_width(content) < 1.0 || rect_height(content) < self.font_size {
    return Err(InvalidBounds)
  }
  let revision = match bump_field_revision(self.revision) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let base = { ..self, bounds, revision, }
  Ok({
    ..base,
    scroll_offset: field_scroll_for_head(base, self.document.selection().head()),
  })
}

///|
fn field_selection_at(
  field : TextField,
  anchor : Int,
  head : Int,
  focused : Bool,
) -> Result[TextField, TextFieldError] {
  let selection = match @text.TextSelection::new(anchor, head) {
    Ok(value) => value
    Err(_) => return Err(InvalidSelection)
  }
  let document = match field.document.with_selection(selection) {
    Ok(value) => value
    Err(_) => return Err(InvalidSelection)
  }
  let measurement = if document == field.document {
    field.measurement
  } else {
    match rebase_field_measurement(field.measurement, document) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  match validate_field_measurement(document, measurement, true) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  field_changed_selection({ ..field, measurement, }, document, focused)
}

///|
fn selection_left(
  field : TextField,
  shift : Bool,
) -> Result[TextField, TextFieldError] {
  let selection = field.document.selection()
  let stops = field_stops(field.measurement)
  let target = if !shift && !selection.is_collapsed() {
    selection.normalized_range().start()
  } else {
    previous_stop(stops, selection.head())
  }
  let anchor = if shift { selection.anchor() } else { target }
  field_selection_at(field, anchor, target, field.focused)
}

///|
fn selection_right(
  field : TextField,
  shift : Bool,
) -> Result[TextField, TextFieldError] {
  let selection = field.document.selection()
  let stops = field_stops(field.measurement)
  let target = if !shift && !selection.is_collapsed() {
    selection.normalized_range().end()
  } else {
    next_stop(stops, selection.head())
  }
  let anchor = if shift { selection.anchor() } else { target }
  field_selection_at(field, anchor, target, field.focused)
}

///|
fn selection_home(
  field : TextField,
  shift : Bool,
) -> Result[TextField, TextFieldError] {
  let target = field_stops(field.measurement)[0]
  let selection = field.document.selection()
  let anchor = if shift { selection.anchor() } else { target }
  field_selection_at(field, anchor, target, field.focused)
}

///|
fn selection_end(
  field : TextField,
  shift : Bool,
) -> Result[TextField, TextFieldError] {
  let stops = field_stops(field.measurement)
  let target = stops[stops.length() - 1]
  let selection = field.document.selection()
  let anchor = if shift { selection.anchor() } else { target }
  field_selection_at(field, anchor, target, field.focused)
}

///|
fn delete_field_selection(
  field : TextField,
  backward : Bool,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  let selection = field.document.selection()
  let range = if !selection.is_collapsed() {
    selection.normalized_range()
  } else {
    let stops = field_stops(field.measurement)
    let head = selection.head()
    let start = if backward { previous_stop(stops, head) } else { head }
    let end = if backward { head } else { next_stop(stops, head) }
    if start == end {
      return Ok(field)
    }
    @text.TextRange::new(start, end).unwrap()
  }
  prepare_field_replacement(field, range, "", measure, admit)
}

///|
fn is_clipboard_command(key : @primitives.Key, letter : String) -> Bool {
  match key {
    @primitives.Character(label) =>
      label == letter || label == letter.to_upper()
    _ => false
  }
}

///|
fn nearest_field_stop(field : TextField, layout_x : Double) -> Int {
  let stops = field_stops(field.measurement)
  let mut result = stops[0]
  let mut best_distance = 1.0e300
  for stop in stops {
    let caret = field.measurement.caret_at(stop).unwrap().strong()
    let x = caret.left()
    let distance = if x >= layout_x { x - layout_x } else { layout_x - x }
    if distance < best_distance {
      best_distance = distance
      result = stop
    }
  }
  result
}

///|
fn handle_field_click(
  field : TextField,
  position : @primitives.Point,
  modifiers : @primitives.Modifiers,
  hit_test : (@text.TextDocument, @primitives.Point) -> Result[
    @text_layout.TextHit,
    TextFieldError,
  ],
) -> Result[TextField, TextFieldError] {
  if !field.bounds.contains(position) {
    return Ok(field)
  }
  let content = field_content_bounds(field.bounds)
  let x = if position.x() < content.left() {
    content.left()
  } else if position.x() > content.right() {
    content.right()
  } else {
    position.x()
  }
  let y = if position.y() < content.top() {
    content.top()
  } else if position.y() > content.bottom() {
    content.bottom()
  } else {
    position.y()
  }
  let logical = field.measurement.logical_rect()
  let hit_point = match
    @primitives.Point::new(
      x - content.left() + field.scroll_offset + logical.left(),
      y - content.top() + logical.top(),
    ) {
    Ok(value) => value
    Err(_) => return Err(InvalidHitResult)
  }
  let hit = match hit_test(field.document, hit_point) {
    Ok(value) => value
    Err(_) => return Err(HitTestFailed)
  }
  if hit.document() != field.document {
    return Err(InvalidHitResult)
  }
  let resolved = hit.resolved_utf16_offset()
  let mapped_caret = match field.measurement.caret_at(resolved) {
    Ok(value) => value
    Err(_) => return Err(InvalidHitResult)
  }
  if hit.resolved_is_cursor_position() != mapped_caret.is_cursor_position() {
    return Err(InvalidHitResult)
  }
  let head = if hit.resolved_is_cursor_position() {
    resolved
  } else {
    nearest_field_stop(field, hit_point.x())
  }
  let selection = field.document.selection()
  let anchor = if modifiers.shift() { selection.anchor() } else { head }
  field_selection_at(field, anchor, head, true)
}

///|
/// Handle one platform-neutral event. Text insertion is driven exclusively by
/// TextInput. A cut returns an admitted candidate in its action; the old field
/// remains unchanged until the owner confirms its clipboard write succeeded.
pub fn TextField::handle_input(
  self : TextField,
  event : @primitives.InputEvent,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    TextFieldError,
  ],
  hit_test : (@text.TextDocument, @primitives.Point) -> Result[
    @text_layout.TextHit,
    TextFieldError,
  ],
) -> Result[(TextField, TextFieldAction?), TextFieldError] {
  match event {
    @primitives.TextInput(text~) => {
      if !self.focused || text.length() == 0 {
        return Ok((self, None))
      }
      match
        prepare_field_replacement(
          self,
          self.document.selection().normalized_range(),
          text,
          measure,
          admit,
        ) {
        Ok(candidate) => Ok((candidate, None))
        Err(error) => Err(error)
      }
    }
    @primitives.KeyPressed(key~, modifiers~, repeat=_) => {
      if !self.focused {
        return Ok((self, None))
      }
      if modifiers.control() || modifiers.meta() {
        if modifiers.alt() {
          return Ok((self, None))
        }
        if is_clipboard_command(key, "c") {
          return Ok((self, Some(Copy(self.document.selected_text()))))
        }
        if is_clipboard_command(key, "x") {
          let selection = self.document.selection()
          if selection.is_collapsed() {
            return Ok((self, None))
          }
          let selected_text = self.document.selected_text()
          let candidate = match
            prepare_field_replacement(
              self,
              selection.normalized_range(),
              "",
              measure,
              admit,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          return Ok((self, Some(Cut(text=selected_text, candidate~))))
        }
        if is_clipboard_command(key, "v") {
          return Ok((self, Some(Paste)))
        }
        return Ok((self, None))
      }
      match key {
        @primitives.ArrowLeft =>
          field_without_action(selection_left(self, modifiers.shift()))
        @primitives.ArrowRight =>
          field_without_action(selection_right(self, modifiers.shift()))
        @primitives.Home =>
          field_without_action(selection_home(self, modifiers.shift()))
        @primitives.End =>
          field_without_action(selection_end(self, modifiers.shift()))
        @primitives.Backspace =>
          field_without_action(
            delete_field_selection(self, true, measure, admit),
          )
        @primitives.Delete =>
          field_without_action(
            delete_field_selection(self, false, measure, admit),
          )
        @primitives.Enter => Ok((self, Some(Submit)))
        @primitives.Escape => Ok((self, Some(Blur)))
        _ => Ok((self, None))
      }
    }
    @primitives.PointerButtonPressed(
      position~,
      button=@primitives.Primary,
      modifiers~
    ) =>
      field_without_action(
        handle_field_click(self, position, modifiers, hit_test),
      )
    @primitives.Scroll(position~, delta~, modifiers=_) => {
      if !self.focused || !self.bounds.contains(position) || delta.x() == 0.0 {
        return Ok((self, None))
      }
      let requested_scroll = clamp_field_scroll(
        self,
        self.scroll_offset + delta.x(),
      )
      let scroll = field_scroll_for_head(
        { ..self, scroll_offset: requested_scroll, },
        self.document.selection().head(),
      )
      if scroll == self.scroll_offset {
        return Ok((self, None))
      }
      let revision = match bump_field_revision(self.revision) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(({ ..self, scroll_offset: scroll, revision, }, None))
    }
    _ => Ok((self, None))
  }
}

///|
pub fn TextField::id(self : TextField) -> UInt64 {
  self.id
}

///|
pub fn TextField::bounds(self : TextField) -> @primitives.Rect {
  self.bounds
}

///|
pub fn TextField::content_bounds(self : TextField) -> @primitives.Rect {
  field_content_bounds(self.bounds)
}

///|
pub fn TextField::font_size(self : TextField) -> Double {
  self.font_size
}

///|
pub fn TextField::document(self : TextField) -> @text.TextDocument {
  self.document
}

///|
pub fn TextField::measurement(self : TextField) -> @text_layout.TextMeasurement {
  self.measurement
}

///|
pub fn TextField::selection(self : TextField) -> @text.TextSelection {
  self.document.selection()
}

///|
pub fn TextField::selected_text(self : TextField) -> String {
  self.document.selected_text()
}

///|
pub fn TextField::is_focused(self : TextField) -> Bool {
  self.focused
}

///|
pub fn TextField::scroll_offset(self : TextField) -> Double {
  self.scroll_offset
}

///|
pub fn TextField::revision(self : TextField) -> Int {
  self.revision
}
