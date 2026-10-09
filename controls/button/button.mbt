///|
/// Errors from constructing the bounded button model.
pub(all) enum ButtonError {
  InvalidId
  InvalidBounds
} derive(Eq)

///|
pub extend ButtonError with Eq::{not_equal, equal}

///|
/// One observable result of routing an input through a button.
pub(all) enum ButtonEffect {
  None
  Activated
} derive(Eq)

///|
pub extend ButtonEffect with Eq::{not_equal, equal}

///|
/// Result of one button input. `consumed` is independent of activation so a
/// caller can keep a rejected or disabled activation key from bubbling.
pub struct ButtonInput {
  consumed : Bool
  effect : ButtonEffect
}

///|
pub fn ButtonInput::consumed(self : ButtonInput) -> Bool {
  self.consumed
}

///|
pub fn ButtonInput::effect(self : ButtonInput) -> ButtonEffect {
  self.effect
}

///|
fn button_input(consumed : Bool, effect : ButtonEffect) -> ButtonInput {
  { consumed, effect, }
}

///|
/// One reusable, platform-neutral button model. App actions and counters stay
/// with the caller; an accepted gesture emits `Activated` exactly once.
pub struct Button {
  priv id : UInt64
  priv bounds : @primitives.Rect
  priv label : String
  priv enabled : Bool
  priv loading : Bool
  priv focused : Bool
  priv hovered : Bool
  priv armed_pointer : Bool
  priv armed_key : @primitives.Key?
}

///|
const MIN_BUTTON_WIDTH : Double = 24.0

///|
const MIN_BUTTON_HEIGHT : Double = 24.0

///|
fn button_bounds_valid(bounds : @primitives.Rect) -> Bool {
  bounds.size().width() >= MIN_BUTTON_WIDTH &&
  bounds.size().height() >= MIN_BUTTON_HEIGHT
}

///|
/// Construct a button with a stable caller-owned logical ID. Native
/// accessibility roles and system semantics are deliberately outside this
/// model.
pub fn Button::new(
  id : UInt64,
  bounds : @primitives.Rect,
  label : String,
) -> Result[Button, ButtonError] {
  if id == 0UL {
    return Err(InvalidId)
  }
  if !button_bounds_valid(bounds) {
    return Err(InvalidBounds)
  }
  Ok({
    id,
    bounds,
    label,
    enabled: true,
    loading: false,
    focused: false,
    hovered: false,
    armed_pointer: false,
    armed_key: None,
  })
}

///|
pub fn Button::id(self : Button) -> UInt64 {
  self.id
}

///|
pub fn Button::bounds(self : Button) -> @primitives.Rect {
  self.bounds
}

///|
pub fn Button::label(self : Button) -> String {
  self.label
}

///|
pub fn Button::is_enabled(self : Button) -> Bool {
  self.enabled
}

///|
pub fn Button::is_loading(self : Button) -> Bool {
  self.loading
}

///|
pub fn Button::is_focused(self : Button) -> Bool {
  self.focused
}

///|
pub fn Button::is_hovered(self : Button) -> Bool {
  self.hovered
}

///|
pub fn Button::is_pressed(self : Button) -> Bool {
  self.armed_pointer || self.armed_key is Some(_)
}

///|
/// Loading keeps keyboard focus when the owner retains it, but neither
/// loading nor disabled buttons accept activation.
pub fn Button::can_activate(self : Button) -> Bool {
  self.enabled && !self.loading
}

///|
/// Build the matching hit-test/focus node using the same stable ID. Loading
/// blocks pointer routing but may retain keyboard focus; disabled removes both.
pub fn Button::element_node(
  self : Button,
  parent : UInt64?,
) -> @element.ElementNode {
  @element.ElementNode::new(self.id, parent, self.bounds)
  .with_focusable(self.enabled)
  .with_pointer_events(self.can_activate())
}

///|
fn button_clear_armed(value : Button) -> Button {
  if !value.armed_pointer && value.armed_key is None {
    value
  } else {
    { ..value, armed_pointer: false, armed_key: None, }
  }
}

///|
/// Cancel an in-flight gesture. Call on removal, window teardown, or any
/// pointer lifecycle event the host cannot deliver to the original target.
pub fn Button::cancel_press(self : Button) -> Button {
  button_clear_armed(self)
}

///|
/// Update the enabled state. Disabling cancels pending activation, hover and
/// focus; enabling does not silently restore either.
pub fn Button::with_enabled(self : Button, enabled : Bool) -> Button {
  if self.enabled == enabled {
    return self
  }
  if enabled {
    { ..self, enabled, armed_pointer: false, armed_key: None, hovered: false, }
  } else {
    {
      ..self,
      enabled,
      focused: false,
      hovered: false,
      armed_pointer: false,
      armed_key: None,
    }
  }
}

///|
/// Update the loading gate. A transition in either direction cancels an
/// in-flight gesture so its later release cannot activate.
pub fn Button::with_loading(self : Button, loading : Bool) -> Button {
  if self.loading == loading {
    return self
  }
  {
    ..self,
    loading,
    hovered: if loading {
      false
    } else {
      self.hovered
    },
    armed_pointer: false,
    armed_key: None,
  }
}

///|
/// Synchronize the model with the owning element tree. Losing focus cancels
/// keyboard and pointer activation; gaining focus does not arm a key.
pub fn Button::with_focus(self : Button, focused : Bool) -> Button {
  if self.focused == focused {
    return self
  }
  if focused {
    if self.enabled {
      { ..self, focused, }
    } else {
      self
    }
  } else {
    { ..self, focused, armed_pointer: false, armed_key: None, }
  }
}

///|
/// Update logical bounds. A resize cancels gestures accepted against the old
/// hit area. The caller should rebuild/update its element tree at the same time.
pub fn Button::with_bounds(
  self : Button,
  bounds : @primitives.Rect,
) -> Result[Button, ButtonError] {
  if !button_bounds_valid(bounds) {
    return Err(InvalidBounds)
  }
  if bounds == self.bounds {
    return Ok(self)
  }
  Ok({ ..self, bounds, hovered: false, armed_pointer: false, armed_key: None, })
}

///|
/// Handle one platform-neutral input routed to this button. Enter activates
/// on its first non-repeat key-down; Space activates on the matching key-up.
/// Primary pointer activation requires an in-bounds down and in-bounds up.
pub fn Button::handle_input(
  self : Button,
  event : @primitives.InputEvent,
) -> (Button, ButtonInput) {
  match event {
    @primitives.PointerMoved(position~) => {
      let hovered = self.can_activate() && self.bounds.contains(position)
      ({ ..self, hovered, }, button_input(false, None))
    }
    @primitives.PointerButtonPressed(position~, button=@primitives.Primary, ..) =>
      if !self.bounds.contains(position) {
        (self, button_input(false, None))
      } else if !self.can_activate() {
        (self, button_input(true, None))
      } else if self.is_pressed() {
        (self, button_input(true, None))
      } else {
        (
          { ..self, armed_pointer: true, hovered: true, },
          button_input(true, None),
        )
      }
    @primitives.PointerButtonPressed(..) => (self, button_input(false, None))
    @primitives.PointerButtonReleased(position~, button=@primitives.Primary, ..) =>
      if !self.armed_pointer {
        (self, button_input(false, None))
      } else {
        let inside = self.bounds.contains(position)
        let next = {
          ..self,
          armed_pointer: false,
          hovered: self.can_activate() && inside,
        }
        let effect = if inside && self.can_activate() {
          Activated
        } else {
          None
        }
        (next, button_input(true, effect))
      }
    @primitives.PointerButtonReleased(..) => (self, button_input(false, None))
    @primitives.KeyPressed(key~, repeat~, ..) if self.focused &&
      (key == @primitives.Enter || key == @primitives.Space) =>
      match self.armed_key {
        Some(_) => (self, button_input(true, None))
        None if !self.can_activate() || repeat =>
          (self, button_input(true, None))
        None if key == @primitives.Enter =>
          (
            { ..self, armed_key: Some(@primitives.Enter), },
            button_input(true, Activated),
          )
        None =>
          (
            { ..self, armed_key: Some(@primitives.Space), },
            button_input(true, None),
          )
      }
    @primitives.KeyReleased(key~, ..) if self.focused &&
      (key == @primitives.Enter || key == @primitives.Space) =>
      match self.armed_key {
        Some(armed) if armed == key => {
          let effect = if armed == @primitives.Space && self.can_activate() {
            Activated
          } else {
            None
          }
          ({ ..self, armed_key: None, }, button_input(true, effect))
        }
        _ => (self, button_input(true, None))
      }
    _ => (self, button_input(false, None))
  }
}
