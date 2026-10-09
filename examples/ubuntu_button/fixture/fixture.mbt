///|
/// Errors from building the portable model/scene fixture.
pub(all) enum ButtonDemoError {
  InvalidViewport
  ButtonError(@button.ButtonError)
  ElementError(@element.ElementError)
  PaintError(@button.ButtonPaintError)
  SceneError(@scene.SnapshotError)
} derive(Eq)

///|
pub extend ButtonDemoError with Eq::{not_equal, equal}

///|
/// App-owned state for the Ubuntu button example. The framework Button emits
/// an action; the fixture owns the count and recreates the control on reset.
pub struct ButtonDemo {
  priv button : @button.Button
  priv tree : @element.ElementTree
  priv viewport : @primitives.Rect
  priv activations : Int
  priv button_visible : Bool
}

///|
const DEMO_MIN_BUTTON_WIDTH : Double = 160.0

///|
const DEMO_MIN_BUTTON_HEIGHT : Double = 68.0

///|
fn demo_button_fits(width : Double, height : Double) -> Bool {
  width >= DEMO_MIN_BUTTON_WIDTH && height >= DEMO_MIN_BUTTON_HEIGHT
}

///|
fn demo_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Result[@primitives.Rect, ButtonDemoError] {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidViewport)
  }
}

///|
fn demo_button_bounds(
  width : Double,
  height : Double,
) -> Result[@primitives.Rect, ButtonDemoError] {
  if width < 24.0 || height < 24.0 {
    return Err(InvalidViewport)
  }
  let left = if width >= 72.0 { 24.0 } else { 0.0 }
  let top = if height >= 64.0 { 20.0 } else { 0.0 }
  let available_width = width - left * 2.0
  let available_height = height - top
  let button_width = if available_width > 240.0 {
    240.0
  } else {
    available_width
  }
  let button_height = if available_height > 48.0 {
    48.0
  } else {
    available_height
  }
  demo_rect(left, top, button_width, button_height)
}

///|
fn demo_tree(
  button : @button.Button,
  viewport : @primitives.Rect,
  button_visible : Bool,
  preserve_focus : Bool,
) -> Result[@element.ElementTree, ButtonDemoError] {
  let root = @element.ElementNode::new(1UL, None, viewport)
  let next = match
    @element.ElementTree::new(
      if button_visible {
        [root, button.element_node(Some(1UL))]
      } else {
        [root]
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(ElementError(error))
  }
  if preserve_focus && button.is_enabled() && button.is_focused() {
    match next.with_focus(button.id()) {
      Ok(value) => Ok(value)
      Err(error) => Err(ElementError(error))
    }
  } else {
    Ok(next)
  }
}

///|
/// Create a portable input/paint fixture with the same button ID on each
/// session. This does not start a window or claim Wayland acceptance.
pub fn ButtonDemo::new(
  width : Double,
  height : Double,
) -> Result[ButtonDemo, ButtonDemoError] {
  let viewport = match demo_rect(0.0, 0.0, width, height) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let button_visible = demo_button_fits(width, height)
  let bounds = if button_visible {
    match demo_button_bounds(width, height) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    match demo_rect(0.0, 0.0, 112.0, 48.0) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  let button = match @button.Button::new(42UL, bounds, "Run action") {
    Ok(value) => value
    Err(error) => return Err(ButtonError(error))
  }
  let tree = match demo_tree(button, viewport, button_visible, false) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ button, tree, viewport, activations: 0, button_visible, })
}

///|
pub fn ButtonDemo::button(self : ButtonDemo) -> @button.Button {
  self.button
}

///|
pub fn ButtonDemo::tree(self : ButtonDemo) -> @element.ElementTree {
  self.tree
}

///|
pub fn ButtonDemo::activations(self : ButtonDemo) -> Int {
  self.activations
}

///|
pub fn ButtonDemo::is_button_visible(self : ButtonDemo) -> Bool {
  self.button_visible
}

///|
pub fn ButtonDemo::focus_button(
  self : ButtonDemo,
) -> Result[ButtonDemo, ButtonDemoError] {
  if !self.button_visible || !self.button.is_enabled() {
    return Ok(self)
  }
  let tree = match self.tree.with_focus(self.button.id()) {
    Ok(value) => value
    Err(error) => return Err(ElementError(error))
  }
  Ok({ ..self, button: self.button.with_focus(true), tree, })
}

///|
pub fn ButtonDemo::blur(self : ButtonDemo) -> ButtonDemo {
  {
    ..self,
    button: self.button.with_focus(false).cancel_press(),
    tree: self.tree.clear_focus(),
  }
}

///|
fn ButtonDemo::replace_button(
  self : ButtonDemo,
  button : @button.Button,
  preserve_focus : Bool,
) -> Result[ButtonDemo, ButtonDemoError] {
  let tree = match
    demo_tree(button, self.viewport, self.button_visible, preserve_focus) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ ..self, button, tree, })
}

///|
pub fn ButtonDemo::with_enabled(
  self : ButtonDemo,
  enabled : Bool,
) -> Result[ButtonDemo, ButtonDemoError] {
  if self.button.is_enabled() == enabled {
    return Ok(self)
  }
  self.replace_button(self.button.with_enabled(enabled), false)
}

///|
pub fn ButtonDemo::with_loading(
  self : ButtonDemo,
  loading : Bool,
) -> Result[ButtonDemo, ButtonDemoError] {
  self.replace_button(
    self.button.with_loading(loading),
    self.button.is_focused(),
  )
}

///|
/// Resize the logical hit target and scene together. A changed button bounds
/// value disarms any gesture accepted against the previous geometry.
pub fn ButtonDemo::resize(
  self : ButtonDemo,
  width : Double,
  height : Double,
) -> Result[ButtonDemo, ButtonDemoError] {
  let viewport = match demo_rect(0.0, 0.0, width, height) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let button_visible = demo_button_fits(width, height)
  let button = if button_visible {
    let bounds = match demo_button_bounds(width, height) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match self.button.with_bounds(bounds) {
      Ok(value) => value
      Err(error) => return Err(ButtonError(error))
    }
  } else {
    self.button.with_focus(false).cancel_press()
  }
  let tree = match
    demo_tree(
      button,
      viewport,
      button_visible,
      button_visible && self.button.is_focused(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ ..self, button, tree, viewport, button_visible, })
}

///|
/// Recreate a user session with the same logical ID, a fresh unarmed control,
/// no focus and a reset app-owned activation count.
pub fn ButtonDemo::reset_session(
  self : ButtonDemo,
) -> Result[ButtonDemo, ButtonDemoError] {
  ButtonDemo::new(self.viewport.size().width(), self.viewport.size().height())
}

///|
fn demo_effect_count(activations : Int, effect : @button.ButtonEffect) -> Int {
  match effect {
    @button.Activated if activations < 2147483647 => activations + 1
    _ => activations
  }
}

///|
/// Route pointer/key inputs through ElementTree first. An already-armed button
/// also receives an in-window pointer release outside its bounds so it can
/// cancel without pointer-capture or platform-backend changes.
pub fn ButtonDemo::handle_input(
  self : ButtonDemo,
  event : @primitives.InputEvent,
) -> ButtonDemo {
  if !self.button_visible {
    return self
  }
  let target = self.tree.dispatch_input(event).target()
  let is_release = match event {
    @primitives.PointerButtonReleased(button=@primitives.Primary, ..) => true
    _ => false
  }
  let is_leave_move = match event {
    @primitives.PointerMoved(..) => self.button.is_hovered()
    _ => false
  }
  if target != Some(self.button.id()) &&
    !(is_release && self.button.is_pressed()) &&
    !is_leave_move {
    return self
  }
  let (next_button, result) = self.button.handle_input(event)
  let mut button = next_button
  let mut tree = self.tree
  match event {
    @primitives.PointerButtonPressed(button=@primitives.Primary, ..) if target ==
      Some(self.button.id()) &&
      result.consumed() =>
      if !button.is_focused() && button.is_enabled() {
        match tree.with_focus(button.id()) {
          Ok(next) => {
            tree = next
            button = button.with_focus(true)
          }
          Err(_) => ()
        }
      }
    _ => ()
  }
  {
    ..self,
    button,
    tree,
    activations: demo_effect_count(self.activations, result.effect()),
  }
}

///|
/// Compose a button and real scene text into an immutable snapshot. Ubuntu's
/// grayscale-text renderer handles these copied `TextItem`s when the native
/// example is run; this function itself remains window-free and testable.
pub fn ButtonDemo::scene(
  self : ButtonDemo,
  scale : Double,
) -> Result[@scene.SceneSnapshot, ButtonDemoError] {
  let background = match
    @scene.SceneItem::quad(
      1UL,
      self.viewport,
      @primitives.Color::rgba(24, 28, 36, 255).unwrap(),
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(value) => value
    Err(error) => return Err(SceneError(error))
  }
  let items : Array[@scene.SceneItem] = [background]
  if self.button_visible {
    let painted = match self.button.paint_items(100UL) {
      Ok(value) => value
      Err(error) => return Err(PaintError(error))
    }
    for item in painted {
      items.push(item)
    }
    if self.viewport.size().width() >= 160.0 &&
      self.viewport.size().height() >= 108.0 {
      let enabled = if self.button.is_enabled() { "on" } else { "off" }
      let loading = if self.button.is_loading() { "on" } else { "off" }
      let status_bounds = match
        demo_rect(8.0, 88.0, self.viewport.size().width() - 16.0, 20.0) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let status = match
        @scene.SceneItem::text(
          200UL,
          status_bounds,
          "Activations: \{self.activations}   Enabled: \{enabled}   Loading: \{loading}",
          14.0,
          @primitives.Color::rgba(220, 226, 234, 255).unwrap(),
          @scene.AffineTransform::identity(),
          1.0,
          None,
        ) {
        Ok(value) => value
        Err(error) => return Err(SceneError(error))
      }
      items.push(status)
    }
    if self.viewport.size().width() >= 400.0 &&
      self.viewport.size().height() >= 144.0 {
      let help_bounds = match
        demo_rect(8.0, 116.0, self.viewport.size().width() - 16.0, 18.0) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let help = match
        @scene.SceneItem::text(
          201UL,
          help_bounds,
          "Tab focus  D disabled  L loading  R reset  Esc close",
          12.0,
          @primitives.Color::rgba(170, 182, 196, 255).unwrap(),
          @scene.AffineTransform::identity(),
          1.0,
          None,
        ) {
        Ok(value) => value
        Err(error) => return Err(SceneError(error))
      }
      items.push(help)
    }
  }
  match @scene.SceneSnapshot::new(self.viewport, scale, [], [], items) {
    Ok(value) => Ok(value)
    Err(error) => Err(SceneError(error))
  }
}
