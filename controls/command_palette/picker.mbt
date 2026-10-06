///|
pub const MAX_COMMANDS : Int = 128

///|
pub const MAX_COMMAND_ID_BYTES : Int = 64

///|
pub const MAX_COMMAND_LABEL_BYTES : Int = 128

///|
pub const MAX_QUERY_BYTES : Int = 256

///|
pub const VISIBLE_ROWS : Int = 8

///|
pub(all) enum PaletteError {
  InvalidMetadata
  TooManyCommands
  DuplicateCommand
  QueryTooLarge
  InvalidField
  AlreadyOpen
  EpochExhausted
  Field(@text_field.TextFieldError)
  Focus(@element.ElementError)
  Command(@diagnostics.FrameworkError)
}

///|
pub struct CommandMetadata {
  priv id : String
  priv label : String
  priv enabled : Bool
}

///|
fn bounded_text(text : String, maximum : Int, nonempty : Bool) -> Bool {
  if nonempty && text.length() == 0 {
    return false
  }
  let document = match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => return false
  }
  if document.utf8_length() is Ok(length) && length <= maximum {
    for scalar in text.iter() {
      let value = scalar.to_int()
      if value <= 0x1f ||
        (value >= 0x7f && value <= 0x9f) ||
        value == 0x2028 ||
        value == 0x2029 {
        return false
      }
    }
    true
  } else {
    false
  }
}

///|
pub fn CommandMetadata::new(
  id : String,
  label : String,
  enabled : Bool,
) -> Result[CommandMetadata, PaletteError] {
  if !bounded_text(id, MAX_COMMAND_ID_BYTES, true) ||
    !bounded_text(label, MAX_COMMAND_LABEL_BYTES, true) {
    Err(InvalidMetadata)
  } else {
    Ok({ id, label, enabled, })
  }
}

///|
pub fn CommandMetadata::id(self : CommandMetadata) -> String {
  self.id
}

///|
pub fn CommandMetadata::label(self : CommandMetadata) -> String {
  self.label
}

///|
pub fn CommandMetadata::is_enabled(self : CommandMetadata) -> Bool {
  self.enabled
}

///|
/// Copied metadata, exact case-sensitive substring matching, original order.
/// All loops are bounded by 128 commands and 128-byte labels; no fuzzy work.
pub struct Picker {
  priv commands : Array[CommandMetadata]
  priv matches : Array[Int]
  priv query : String
  priv active : Int?
  priv scroll : @element.ScrollState
}

///|
fn picker_scroll(count : Int) -> @element.ScrollState {
  @element.ScrollState::new(
    @primitives.Size::new(1.0, VISIBLE_ROWS.to_double()).unwrap(),
    @primitives.Size::new(1.0, count.to_double()).unwrap(),
  )
}

///|
pub fn Picker::new(
  commands : Array[CommandMetadata],
) -> Result[Picker, PaletteError] {
  if commands.length() > MAX_COMMANDS {
    return Err(TooManyCommands)
  }
  let owned : Array[CommandMetadata] = []
  let indices : Array[Int] = []
  let mut active : Int? = None
  for command in commands {
    for prior in owned {
      if prior.id == command.id {
        return Err(DuplicateCommand)
      }
    }
    if active is None && command.enabled {
      active = Some(owned.length())
    }
    indices.push(owned.length())
    owned.push(command)
  }
  Ok(
    {
      commands: owned,
      matches: indices,
      query: "",
      active,
      scroll: picker_scroll(owned.length()),
    }.ensure_active_visible(),
  )
}

///|
pub fn Picker::query(self : Picker) -> String {
  self.query
}

///|
pub fn Picker::match_count(self : Picker) -> Int {
  self.matches.length()
}

///|
pub fn Picker::active_index(self : Picker) -> Int? {
  self.active
}

///|
pub fn Picker::active_command(self : Picker) -> CommandMetadata? {
  match self.active {
    Some(index) => Some(self.commands[self.matches[index]])
    None => None
  }
}

///|
pub fn Picker::command_at(
  self : Picker,
  filtered_index : Int,
) -> CommandMetadata? {
  if filtered_index < 0 || filtered_index >= self.matches.length() {
    None
  } else {
    Some(self.commands[self.matches[filtered_index]])
  }
}

///|
/// Query equality preserves selection and scrolling, including caret-only
/// changes in the search field. A changed query retains the active command when still enabled/matched,
/// otherwise selects the first enabled row.
pub fn Picker::filter(
  self : Picker,
  query : String,
) -> Result[Picker, PaletteError] {
  if !bounded_text(query, MAX_QUERY_BYTES, false) {
    return Err(QueryTooLarge)
  }
  if query == self.query {
    return Ok(self)
  }
  let matches : Array[Int] = []
  let previous = self.active_command()
  let mut active : Int? = None
  let mut retained : Int? = None
  for index = 0; index < self.commands.length(); index = index + 1 {
    let command = self.commands[index]
    if command.label.contains(query) {
      if active is None && command.enabled {
        active = Some(matches.length())
      }
      if command.enabled && previous is Some(prior) && prior.id == command.id {
        retained = Some(matches.length())
      }
      matches.push(index)
    }
  }
  let active = match retained {
    Some(index) => Some(index)
    None => active
  }
  let value = {
    commands: self.commands,
    matches,
    query,
    active,
    scroll: picker_scroll(matches.length()),
  }
  Ok(value.ensure_active_visible())
}

///|
fn Picker::ensure_active_visible(self : Picker) -> Picker {
  match self.active {
    None => self
    Some(index) =>
      {
        ..self,
        scroll: self.scroll.ensure_visible(
          @primitives.Rect::new(0.0, index.to_double(), 1.0, 1.0).unwrap(),
        ),
      }
  }
}

///|
/// Clamp at the first/last enabled row; disabled rows remain visible.
pub fn Picker::navigate(self : Picker, direction : Int) -> Picker {
  if direction == 0 {
    return self
  }
  let step = if direction < 0 { -1 } else { 1 }
  let mut index = match self.active {
    Some(index) => index + step
    None => if step > 0 { 0 } else { self.matches.length() - 1 }
  }
  while index >= 0 && index < self.matches.length() {
    if self.commands[self.matches[index]].enabled {
      return { ..self, active: Some(index), }.ensure_active_visible()
    }
    index += step
  }
  self
}

///|
pub fn Picker::visible_start(self : Picker) -> Int {
  self.scroll.offset().y().to_int()
}

///|
pub fn Picker::visible_commands(self : Picker) -> Array[CommandMetadata] {
  let values : Array[CommandMetadata] = []
  let start = self.visible_start()
  let end = if start + VISIBLE_ROWS < self.matches.length() {
    start + VISIBLE_ROWS
  } else {
    self.matches.length()
  }
  for index = start; index < end; index = index + 1 {
    values.push(self.commands[self.matches[index]])
  }
  values
}
