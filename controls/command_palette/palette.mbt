///|
/// Actions keep the existing capability validation/policy boundary.
pub struct PaletteCommand {
  priv metadata : CommandMetadata
  priv binding : @capability.GuiBinding[Unit, Unit]
}

///|
pub fn PaletteCommand::new(
  metadata : CommandMetadata,
  binding : @capability.GuiBinding[Unit, Unit],
) -> PaletteCommand {
  { metadata, binding, }
}

///|
pub(all) enum PaletteEffect {
  None
  FieldAction(@text_field.TextFieldAction)
  CompositionCancelled
  Closed(epoch~ : Int, command_id~ : String?)
}

///|
pub struct PaletteInput {
  consumed : Bool
  effect : PaletteEffect
}

///|
priv struct Terminal {
  epoch : Int
  command : String?
  previous : @element.FocusOwner?
  modal : @element.FocusOwner
}

///|
/// Single UI-thread controller, with immutable TextField/Picker values inside.
/// Closing is terminal before exposing the effect. finish_close consumes its
/// one-shot action before entering user code, preventing reentrant submission.
pub struct CommandPalette {
  priv initial_field : @text_field.TextField
  priv commands : Array[PaletteCommand]
  priv mut field : @text_field.TextField
  priv mut picker : Picker
  priv mut opened : Bool
  priv mut epoch : Int
  priv mut previous : @element.FocusOwner?
  priv mut modal : @element.FocusOwner?
  priv mut terminal : Terminal?
  priv mut closing_key : @primitives.Key?
  priv mut composition_enter : Bool
}

///|
fn copied_metadata(commands : Array[PaletteCommand]) -> Array[CommandMetadata] {
  commands.map(command => {
    ..command.metadata,
    enabled: command.metadata.enabled && command.binding.is_enabled(),
  })
}

///|
pub fn CommandPalette::new(
  field : @text_field.TextField,
  commands : Array[PaletteCommand],
) -> Result[CommandPalette, PaletteError] {
  if commands.length() > MAX_COMMANDS {
    return Err(TooManyCommands)
  }
  if field.committed_document().text() != "" ||
    field.is_composing() ||
    field.is_focused() {
    return Err(InvalidField)
  }
  let picker = match Picker::new(copied_metadata(commands)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    initial_field: field,
    commands: commands.copy(),
    field,
    picker,
    opened: false,
    epoch: 0,
    previous: None,
    modal: None,
    terminal: None,
    closing_key: None,
    composition_enter: false,
  })
}

///|
pub fn CommandPalette::is_open(self : CommandPalette) -> Bool {
  self.opened
}

///|
pub fn CommandPalette::open_epoch(self : CommandPalette) -> Int {
  self.epoch
}

///|
pub fn CommandPalette::field(self : CommandPalette) -> @text_field.TextField {
  self.field
}

///|
pub fn CommandPalette::picker(self : CommandPalette) -> Picker {
  self.picker
}

///|
pub fn CommandPalette::open(
  self : CommandPalette,
  tree : Ref[@element.ElementTree],
) -> Result[Unit, PaletteError] {
  if self.opened || self.terminal is Some(_) {
    return Err(AlreadyOpen)
  }
  if self.epoch >= @int.MAX_VALUE {
    return Err(EpochExhausted)
  }
  let focused = match tree.val.with_focus(self.initial_field.id()) {
    Ok(value) => value
    Err(error) => return Err(Focus(error))
  }
  let field = match self.initial_field.with_focus(true) {
    Ok(value) => value
    Err(error) => return Err(Field(error))
  }
  let picker = match Picker::new(copied_metadata(self.commands)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.previous = tree.val.focus_owner()
  self.modal = focused.focus_owner()
  tree.val = focused
  self.field = field
  self.picker = picker
  self.epoch += 1
  self.opened = true
  self.composition_enter = false
  Ok(())
}

///|
/// Owner installs a prepared native composition/edit value atomically. Preview,
/// caret, selection and revision alone never cause filter/selection work.
pub fn CommandPalette::install_field(
  self : CommandPalette,
  candidate : @text_field.TextField,
) -> Result[Unit, PaletteError] {
  if !self.opened ||
    candidate.id() != self.field.id() ||
    !candidate.is_focused() {
    return Err(InvalidField)
  }
  if !bounded_text(candidate.document().text(), MAX_QUERY_BYTES, false) {
    return Err(QueryTooLarge)
  }
  let picker = match self.picker.filter(candidate.committed_document().text()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.field = candidate
  self.picker = picker
  Ok(())
}

///|
fn CommandPalette::close(
  self : CommandPalette,
  command : String?,
  key : @primitives.Key?,
) -> Result[PaletteEffect, PaletteError] {
  let field = match self.field.with_focus(false) {
    Ok(value) => value
    Err(error) => return Err(Field(error))
  }
  let modal = match self.modal {
    Some(value) => value
    None => return Err(InvalidField)
  }
  self.opened = false
  self.field = field
  if key is Some(_) {
    self.closing_key = key
  }
  self.terminal = Some({
    epoch: self.epoch,
    command,
    previous: self.previous,
    modal,
  })
  Ok(Closed(epoch=self.epoch, command_id=command))
}

///|
/// Caller first ends/fences its native owner, then calls this once. The saved
/// action is consumed before callback. A callback's deliberate newer focus is
/// preserved, and a removed/rebuilt prior owner is never restored by bare ID.
pub fn CommandPalette::finish_close(
  self : CommandPalette,
  epoch : Int,
  tree : Ref[@element.ElementTree],
) -> Result[Unit, PaletteError] {
  let terminal = match self.terminal {
    Some(value) if value.epoch == epoch => value
    _ => return Ok(())
  }
  self.terminal = None
  let mut result : Result[Unit, PaletteError] = Ok(())
  if terminal.command is Some(id) {
    for command in self.commands {
      if command.metadata.id == id {
        result = match command.binding.trigger(()) {
          Ok(_) => Ok(())
          Err(error) => Err(Command(error))
        }
        break
      }
    }
  }
  tree.val = tree.val.restore_focus(terminal.previous, terminal.modal)
  result
}

///|
pub fn CommandPalette::blur(
  self : CommandPalette,
) -> Result[PaletteEffect, PaletteError] {
  if self.opened {
    self.close(None, None)
  } else {
    Ok(None)
  }
}

///|
/// All input is contained while open. Home/End remain search-field keys.
/// Enter during composition is reserved for the engine; it never activates.
/// Escape cancels composition first, and dismisses only on a later press.
pub fn CommandPalette::handle_input(
  self : CommandPalette,
  event : @primitives.InputEvent,
  measure : (@text.TextDocument) -> Result[
    @text_layout.TextMeasurement,
    @text_field.TextFieldError,
  ],
  admit : (@text.TextDocument, @text_layout.TextMeasurement) -> Result[
    Unit,
    @text_field.TextFieldError,
  ],
  hit : (@text.TextDocument, @primitives.Point) -> Result[
    @text_layout.TextHit,
    @text_field.TextFieldError,
  ],
) -> Result[PaletteInput, PaletteError] {
  if event is @primitives.KeyReleased(key~, ..) && self.closing_key == Some(key) {
    self.closing_key = None
    return Ok({ consumed: true, effect: None, })
  }
  if event is @primitives.KeyPressed(key~, ..) && self.closing_key == Some(key) {
    return Ok({ consumed: true, effect: None, })
  }
  if !self.opened {
    return Ok({ consumed: false, effect: None, })
  }
  if event is @primitives.KeyReleased(key=@primitives.Enter, ..) {
    self.composition_enter = false
  }
  if event is @primitives.KeyPressed(key~, modifiers~, repeat~) {
    if key == @primitives.Escape && repeat {
      return Ok({ consumed: true, effect: None, })
    }
    if key == @primitives.Enter &&
      (self.field.is_composing() || self.composition_enter || repeat) {
      self.composition_enter = true
      return Ok({ consumed: true, effect: None, })
    }
    if self.field.is_composing() {
      if key == @primitives.Escape && !repeat {
        let field = match self.field.cancel_composition(measure, admit) {
          Ok(value) => value
          Err(error) => return Err(Field(error))
        }
        match self.install_field(field) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        self.closing_key = Some(@primitives.Escape)
        return Ok({ consumed: true, effect: CompositionCancelled, })
      }
      return Ok({ consumed: true, effect: None, })
    }
    if modifiers.is_empty() {
      match key {
        @primitives.ArrowUp => {
          self.picker = self.picker.navigate(-1)
          return Ok({ consumed: true, effect: None, })
        }
        @primitives.ArrowDown => {
          self.picker = self.picker.navigate(1)
          return Ok({ consumed: true, effect: None, })
        }
        @primitives.Enter if !repeat =>
          match self.picker.active_command() {
            Some(command) =>
              return match self.close(Some(command.id), Some(key)) {
                Ok(effect) => Ok({ consumed: true, effect, })
                Err(error) => Err(error)
              }
            None => return Ok({ consumed: true, effect: None, })
          }
        @primitives.Escape if !repeat =>
          return match self.close(None, Some(key)) {
            Ok(effect) => Ok({ consumed: true, effect, })
            Err(error) => Err(error)
          }
        _ => ()
      }
    }
  }
  match self.field.handle_input(event, measure, admit, hit) {
    Err(error) => Err(Field(error))
    Ok((candidate, action)) => {
      if action is Some(@text_field.Blur) {
        return match
          self.close(
            None,
            match event {
              @primitives.KeyPressed(key~, ..) => Some(key)
              _ => None
            },
          ) {
          Ok(effect) => Ok({ consumed: true, effect, })
          Err(error) => Err(error)
        }
      }
      match self.install_field(candidate) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let effect = match action {
        Some(@text_field.Submit) => None
        Some(action) => FieldAction(action)
        None => None
      }
      Ok({ consumed: true, effect, })
    }
  }
}

///|
/// Asynchronous/native owners capture the open epoch before preparing an edit.
/// A prior-open candidate is rejected even when its numeric field ID matches.
pub fn CommandPalette::install_field_at(
  self : CommandPalette,
  epoch : Int,
  candidate : @text_field.TextField,
) -> Result[Unit, PaletteError] {
  if !self.opened || epoch != self.epoch {
    return Err(InvalidField)
  }
  self.install_field(candidate)
}

///|
/// A native host may retire a quarantined key when it has synchronously revoked
/// every old-owner keyboard record and successfully armed a fresh keyboard
/// generation. This is not a synthetic key release. Generic owners should
/// deliver the actual release instead; a stale epoch cannot retire a new guard.
pub fn CommandPalette::retire_key_guard(
  self : CommandPalette,
  epoch : Int,
) -> Unit {
  if !self.opened && self.epoch == epoch && self.terminal is None {
    self.closing_key = None
  }
}
