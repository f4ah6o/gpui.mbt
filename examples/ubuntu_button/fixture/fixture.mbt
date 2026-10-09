///|
/// Errors from building the portable model/scene fixture.
pub(all) enum ButtonDemoError {
  InvalidViewport
  ButtonError(@button.ButtonError)
  ElementError(@element.ElementError)
  PaintError(@button.ButtonPaintError)
  SceneError(@scene.SnapshotError)
  AccessibilityError(@accessibility.AccessibilityError)
  StaleFixtureState
} derive(Eq)

///|
pub extend ButtonDemoError with Eq::{not_equal, equal}

///|
/// App-owned state for the Ubuntu button example. Earlier immutable copies
/// share a freshness fence; the latest returned value owns future transitions.
/// The framework Button emits an action; the fixture owns the count and reset.
pub struct ButtonDemo {
  priv button : @button.Button
  priv tree : @element.ElementTree
  priv viewport : @primitives.Rect
  priv activations : Int
  priv button_visible : Bool
  priv accessibility_model : @accessibility.AccessibilityModel
  priv accessibility_snapshot : @accessibility.AccessibilitySnapshot
  priv fixture_revision : UInt64
  priv fixture_revision_source : Ref[UInt64?]
}

///|
fn demo_is_current(demo : ButtonDemo) -> Bool {
  demo.fixture_revision_source.val == Some(demo.fixture_revision) &&
  demo.accessibility_model.snapshot().revision() ==
  demo.accessibility_snapshot.revision()
}

///|
fn demo_require_current(demo : ButtonDemo) -> Result[Unit, ButtonDemoError] {
  if demo_is_current(demo) {
    Ok(())
  } else {
    Err(StaleFixtureState)
  }
}

///|
const DEMO_MIN_BUTTON_WIDTH : Double = 160.0

///|
const DEMO_MIN_BUTTON_HEIGHT : Double = 68.0

///|
const DEMO_MAX_FIXTURE_REVISION : UInt64 = 0xffff_ffff_ffff_ffff

///|
/// Advance the shared fixture freshness fence. Immutable ButtonDemo copies
/// share this source so an earlier copy cannot overwrite newer app/control
/// state. Exhaustion invalidates the source instead of reviving an old value.
fn demo_advance_fixture_revision(demo : ButtonDemo) -> ButtonDemo? {
  match demo.fixture_revision_source.val {
    Some(current) if current == demo.fixture_revision =>
      if current == DEMO_MAX_FIXTURE_REVISION {
        demo.fixture_revision_source.val = None
        None
      } else {
        let next = current + 1UL
        demo.fixture_revision_source.val = Some(next)
        Some({ ..demo, fixture_revision: next, })
      }
    _ => None
  }
}

///|
fn demo_advance_fixture_revision_or_stale(demo : ButtonDemo) -> ButtonDemo {
  match demo_advance_fixture_revision(demo) {
    Some(next) => next
    None => demo
  }
}

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
/// Project the current fixture into the portable semantic model. The button's
/// logical ID is the continuity key; the accessibility model supplies its
/// own owner-scoped generation for each continuous admission.
fn demo_accessibility_specs(
  button : @button.Button,
  viewport : @primitives.Rect,
  button_visible : Bool,
) -> Result[Array[@accessibility.NodeSpec], ButtonDemoError] {
  let root = @accessibility.NodeSpec::new(
    1UL,
    None,
    @accessibility.Window,
    "Ubuntu button demo",
    viewport,
  )
  if !button_visible {
    return Ok([root])
  }
  let button_spec = @accessibility.NodeSpec::new(
      button.id(),
      Some(1UL),
      @accessibility.Button,
      button.label(),
      button.bounds(),
    )
    .with_enabled(button.is_enabled())
    .with_loading(button.is_loading())
    .with_focused(button.is_focused())
  let button_spec = match button_spec.with_actions([@accessibility.Invoke]) {
    Ok(value) => value
    Err(error) => return Err(AccessibilityError(error))
  }
  Ok([root, button_spec])
}

///|
fn demo_publish_accessibility(
  model : @accessibility.AccessibilityModel,
  button : @button.Button,
  viewport : @primitives.Rect,
  button_visible : Bool,
) -> Result[@accessibility.AccessibilitySnapshot, ButtonDemoError] {
  let specs = match demo_accessibility_specs(button, viewport, button_visible) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match model.publish(specs) {
    Ok(snapshot) => Ok(snapshot)
    Err(error) => Err(AccessibilityError(error))
  }
}

///|
fn demo_sync_accessibility_or_abort(demo : ButtonDemo) -> ButtonDemo {
  match
    demo_publish_accessibility(
      demo.accessibility_model,
      demo.button,
      demo.viewport,
      demo.button_visible,
    ) {
    Ok(snapshot) =>
      demo_advance_fixture_revision_or_stale({
        ..demo,
        accessibility_snapshot: snapshot,
      })
    Err(AccessibilityError(@accessibility.ModelClosed)) => demo
    Err(_) => abort("Ubuntu button semantic fixture invariant")
  }
}

///|
fn demo_new_with_model(
  width : Double,
  height : Double,
  accessibility_model : @accessibility.AccessibilityModel,
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
  let accessibility_snapshot = match
    demo_publish_accessibility(
      accessibility_model, button, viewport, button_visible,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let demo = {
    button,
    tree,
    viewport,
    activations: 0,
    button_visible,
    accessibility_model,
    accessibility_snapshot,
    fixture_revision: 1UL,
    fixture_revision_source: Ref(Some(1UL)),
  }
  Ok(demo)
}

///|
/// Create a portable input/paint fixture with the same button ID on each
/// session. This does not start a window or claim Wayland acceptance.
pub fn ButtonDemo::new(
  width : Double,
  height : Double,
) -> Result[ButtonDemo, ButtonDemoError] {
  let _ = match demo_rect(0.0, 0.0, width, height) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let accessibility_model = match @accessibility.AccessibilityModel::new() {
    Ok(value) => value
    Err(error) => return Err(AccessibilityError(error))
  }
  demo_new_with_model(width, height, accessibility_model)
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
/// Return this fixture value's immutable semantic snapshot. This is a headless
/// projection, not an operating-system accessibility object.
pub fn ButtonDemo::accessibility_snapshot(
  self : ButtonDemo,
) -> @accessibility.AccessibilitySnapshot {
  self.accessibility_snapshot
}

///|
/// Validate an accessibility request without running the application action.
/// The returned intent is a repeatable validation receipt, not a one-shot
/// token or a command that executes by itself.
pub fn ButtonDemo::validate_accessibility_request(
  self : ButtonDemo,
  request : @accessibility.ActionRequest,
) -> Result[@accessibility.ActionIntent, @accessibility.ActionError] {
  match self.accessibility_model.resolve_action(request) {
    Err(error) => Err(error)
    Ok(intent) =>
      if demo_is_current(self) &&
        intent.revision() == self.accessibility_snapshot.revision() {
        Ok(intent)
      } else {
        Err(@accessibility.StaleNode)
      }
  }
}

///|
/// Synchronously validate a request owned by this fixture, then route an
/// accepted Invoke through the same app-owned activation counter as input.
pub fn ButtonDemo::dispatch_accessibility_request(
  self : ButtonDemo,
  request : @accessibility.ActionRequest,
) -> Result[ButtonDemo, @accessibility.ActionError] {
  match self.validate_accessibility_request(request) {
    Err(error) => Err(error)
    Ok(intent) =>
      if intent.action() == @accessibility.Invoke &&
        intent.node_id().key() == self.button.id() &&
        self.button_visible {
        match
          demo_advance_fixture_revision(
            ButtonDemo::apply_effect(self, @button.Activated),
          ) {
          Some(next) => Ok(next)
          None => Err(@accessibility.StaleNode)
        }
      } else {
        Err(@accessibility.StaleNode)
      }
  }
}

///|
/// Revoke the current live semantic tree. A later reopen receives a distinct
/// owner, so IDs from this session remain foreign to the replacement.
pub fn ButtonDemo::close(self : ButtonDemo) -> Unit {
  if demo_is_current(self) ||
    (
      self.fixture_revision_source.val is None &&
      self.fixture_revision == DEMO_MAX_FIXTURE_REVISION
    ) {
    self.accessibility_model.close()
  }
}

///|
/// Open a fresh fixture model with the same viewport and stable button key.
pub fn ButtonDemo::reopen(
  self : ButtonDemo,
) -> Result[ButtonDemo, ButtonDemoError] {
  ButtonDemo::new(self.viewport.size().width(), self.viewport.size().height())
}

///|
pub fn ButtonDemo::focus_button(
  self : ButtonDemo,
) -> Result[ButtonDemo, ButtonDemoError] {
  match demo_require_current(self) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !self.button_visible || !self.button.is_enabled() {
    return Ok(self)
  }
  let tree = match self.tree.with_focus(self.button.id()) {
    Ok(value) => value
    Err(error) => return Err(ElementError(error))
  }
  let next = { ..self, button: self.button.with_focus(true), tree, }
  demo_publish_fixture(next)
}

///|
pub fn ButtonDemo::blur(self : ButtonDemo) -> ButtonDemo {
  if !demo_is_current(self) {
    return self
  }
  demo_sync_accessibility_or_abort({
    ..self,
    button: self.button.with_focus(false).cancel_press(),
    tree: self.tree.clear_focus(),
  })
}

///|
fn ButtonDemo::replace_button(
  self : ButtonDemo,
  button : @button.Button,
  preserve_focus : Bool,
) -> Result[ButtonDemo, ButtonDemoError] {
  match demo_require_current(self) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let tree = match
    demo_tree(button, self.viewport, self.button_visible, preserve_focus) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let next = { ..self, button, tree, }
  demo_publish_fixture(next)
}

///|
fn demo_publish_fixture(
  demo : ButtonDemo,
) -> Result[ButtonDemo, ButtonDemoError] {
  match
    demo_publish_accessibility(
      demo.accessibility_model,
      demo.button,
      demo.viewport,
      demo.button_visible,
    ) {
    Ok(snapshot) =>
      match
        demo_advance_fixture_revision({
          ..demo,
          accessibility_snapshot: snapshot,
        }) {
        Some(next) => Ok(next)
        None => Err(StaleFixtureState)
      }
    Err(error) => Err(error)
  }
}

///|
pub fn ButtonDemo::with_enabled(
  self : ButtonDemo,
  enabled : Bool,
) -> Result[ButtonDemo, ButtonDemoError] {
  match demo_require_current(self) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
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
  match demo_require_current(self) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
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
  let next = { ..self, button, tree, viewport, button_visible, }
  demo_publish_fixture(next)
}

///|
/// Recreate a user session with the same logical ID, a fresh unarmed control,
/// no focus and a reset app-owned activation count.
pub fn ButtonDemo::reset_session(
  self : ButtonDemo,
) -> Result[ButtonDemo, ButtonDemoError] {
  match demo_require_current(self) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.accessibility_model.reset() {
    Ok(_) => ()
    Err(error) => return Err(AccessibilityError(error))
  }
  demo_new_with_model(
    self.viewport.size().width(),
    self.viewport.size().height(),
    self.accessibility_model,
  )
}

///|
fn demo_effect_count(activations : Int, effect : @button.ButtonEffect) -> Int {
  match effect {
    @button.Activated if activations < 2147483647 => activations + 1
    _ => activations
  }
}

///|
/// One app-owned effect path shared by physical input and validated semantic
/// Invoke. Semantic dispatch deliberately leaves focus and press state alone.
fn ButtonDemo::apply_effect(
  self : ButtonDemo,
  effect : @button.ButtonEffect,
) -> ButtonDemo {
  { ..self, activations: demo_effect_count(self.activations, effect), }
}

///|
/// Route pointer/key inputs through ElementTree first. An already-armed button
/// also receives an in-window pointer release outside its bounds so it can
/// cancel without pointer-capture or platform-backend changes.
pub fn ButtonDemo::handle_input(
  self : ButtonDemo,
  event : @primitives.InputEvent,
) -> ButtonDemo {
  if !demo_is_current(self) {
    return self
  }
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
  let next = { ..self, button, tree, }
  let next = ButtonDemo::apply_effect(next, result.effect())
  if next.button.is_focused() != self.button.is_focused() {
    demo_sync_accessibility_or_abort(next)
  } else {
    demo_advance_fixture_revision_or_stale(next)
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
