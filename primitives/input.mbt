///|
/// Logical keyboard keys independent of a platform's scan-code values.
pub(all) enum Key {
  Character(String)
  Enter
  Escape
  Backspace
  Delete
  Tab
  Space
  ArrowLeft
  ArrowRight
  ArrowUp
  ArrowDown
  Home
  End
  PageUp
  PageDown
} derive(Eq)

///|
pub extend Key with Eq::{not_equal, equal}

///|
pub(all) enum MouseButton {
  Primary
  Secondary
  Middle
  Back
  Forward
} derive(Eq)

///|
pub extend MouseButton with Eq::{not_equal, equal}

///|
/// Modifier keys as observed with a keyboard or pointer input event.
pub struct Modifiers {
  shift : Bool
  control : Bool
  alt : Bool
  meta : Bool
} derive(Eq)

///|
pub extend Modifiers with Eq::{not_equal, equal}

///|
pub fn Modifiers::new(
  shift~ : Bool,
  control~ : Bool,
  alt~ : Bool,
  meta~ : Bool,
) -> Modifiers {
  { shift, control, alt, meta, }
}

///|
pub fn Modifiers::none() -> Modifiers {
  { shift: false, control: false, alt: false, meta: false, }
}

///|
pub fn Modifiers::shift(self : Modifiers) -> Bool {
  self.shift
}

///|
pub fn Modifiers::control(self : Modifiers) -> Bool {
  self.control
}

///|
pub fn Modifiers::alt(self : Modifiers) -> Bool {
  self.alt
}

///|
pub fn Modifiers::meta(self : Modifiers) -> Bool {
  self.meta
}

///|
pub fn Modifiers::is_empty(self : Modifiers) -> Bool {
  !self.shift && !self.control && !self.alt && !self.meta
}

///|
/// Platform-neutral input values. Dispatch order and propagation belong to
/// the later element/event system; these values carry no tree or window ID.
pub(all) enum InputEvent {
  KeyPressed(key~ : Key, modifiers~ : Modifiers, repeat~ : Bool)
  KeyReleased(key~ : Key, modifiers~ : Modifiers)
  TextInput(text~ : String)
  PointerMoved(position~ : Point)
  PointerButtonPressed(
    position~ : Point,
    button~ : MouseButton,
    modifiers~ : Modifiers
  )
  PointerButtonReleased(
    position~ : Point,
    button~ : MouseButton,
    modifiers~ : Modifiers
  )
  Scroll(position~ : Point, delta~ : Point, modifiers~ : Modifiers)
} derive(Eq)

///|
pub extend InputEvent with Eq::{not_equal, equal}
