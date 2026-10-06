///|
pub struct SemanticOption {
  id : String
  name : String
  role : String
  selected : Bool
  disabled : Bool
  index : Int
}

///|
/// Portable semantics DTO only. This does not implement Linux AT-SPI transport.
/// Visible options are bounded; index and total preserve collection position.
pub struct PaletteSemantics {
  open : Bool
  role : String
  name : String
  search_role : String
  search_name : String
  search_value : String
  search_focused : Bool
  composing : Bool
  collection_role : String
  total : Int
  active_id : String?
  options : Array[SemanticOption]
}

///|
pub fn CommandPalette::semantics(self : CommandPalette) -> PaletteSemantics {
  let options : Array[SemanticOption] = []
  if self.opened {
    let start = self.picker.visible_start()
    let visible = self.picker.visible_commands()
    for offset = 0; offset < visible.length(); offset = offset + 1 {
      let command = visible[offset]
      options.push({
        id: command.id,
        name: command.label,
        role: "option",
        selected: self.picker.active == Some(start + offset),
        disabled: !command.enabled,
        index: start + offset,
      })
    }
  }
  let active_id = match self.picker.active_command() {
    Some(command) if self.opened => Some(command.id)
    _ => None
  }
  {
    open: self.opened,
    role: "dialog",
    name: "Command palette",
    search_role: "textbox",
    search_name: "Search commands",
    search_value: self.field.committed_document().text(),
    search_focused: self.opened && self.field.is_focused(),
    composing: self.field.is_composing(),
    collection_role: "listbox",
    total: if self.opened {
      self.picker.match_count()
    } else {
      0
    },
    active_id,
    options,
  }
}
