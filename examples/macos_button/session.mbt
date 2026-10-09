///|
/// State adapter between AppKit host events and the reusable portable Button
/// fixture. It owns no platform resources; the executable owns the Host/window.
struct MacButtonSession {
  demo : @fixture.ButtonDemo
  width : Double
  height : Double
  scale : Double
  presentable : Bool
}

///|
enum MacButtonSessionError {
  InvalidMetrics
  FixtureFailure
  Suspended
}

///|
fn mac_button_fixture_result(
  result : Result[@fixture.ButtonDemo, @fixture.ButtonDemoError],
) -> Result[@fixture.ButtonDemo, MacButtonSessionError] {
  match result {
    Ok(value) => Ok(value)
    Err(_) => Err(FixtureFailure)
  }
}

///|
fn mac_button_valid_scale(scale : Double) -> Bool {
  !scale.is_nan() && !scale.is_inf() && scale > 0.0
}

///|
fn MacButtonSession::new(
  width : Double,
  height : Double,
  scale : Double,
) -> Result[MacButtonSession, MacButtonSessionError] {
  if width.is_nan() ||
    width.is_inf() ||
    width <= 0.0 ||
    height.is_nan() ||
    height.is_inf() ||
    height <= 0.0 ||
    !mac_button_valid_scale(scale) {
    return Err(InvalidMetrics)
  }
  match @fixture.ButtonDemo::new(width, height) {
    Ok(demo) => Ok({ demo, width, height, scale, presentable: true, })
    Err(_) => Err(FixtureFailure)
  }
}

///|
fn MacButtonSession::demo(self : MacButtonSession) -> @fixture.ButtonDemo {
  self.demo
}

///|
fn MacButtonSession::is_presentable(self : MacButtonSession) -> Bool {
  self.presentable
}

///|
/// Reconcile a pending draw with the host's authoritative current metrics.
/// Exact matches are a no-op so polling cannot cancel an armed gesture.
fn MacButtonSession::sync_metrics(
  self : MacButtonSession,
  width : Double,
  height : Double,
  scale : Double,
) -> (MacButtonSession, Bool) {
  if width.is_nan() ||
    width.is_inf() ||
    width <= 0.0 ||
    height.is_nan() ||
    height.is_inf() ||
    height <= 0.0 ||
    !mac_button_valid_scale(scale) {
    return (
      { demo: self.demo.blur(), width, height, scale, presentable: false, },
      false,
    )
  }
  if self.presentable &&
    self.width == width &&
    self.height == height &&
    self.scale == scale {
    return (self, false)
  }
  if self.presentable && self.width == width && self.height == height {
    return ({ ..self, scale, }, true)
  }
  match self.demo.resize(width, height) {
    Ok(demo) => ({ demo, width, height, scale, presentable: true, }, true)
    Err(_) =>
      (
        { demo: self.demo.blur(), width, height, scale, presentable: false, },
        false,
      )
  }
}

///|
fn MacButtonSession::scene(
  self : MacButtonSession,
) -> Result[@scene.SceneSnapshot, MacButtonSessionError] {
  if !self.presentable {
    return Err(Suspended)
  }
  match self.demo.scene(self.scale) {
    Ok(value) => Ok(value)
    Err(_) => Err(FixtureFailure)
  }
}

///|
fn mac_button_route_input(
  demo : @fixture.ButtonDemo,
  input : @primitives.InputEvent,
) -> Result[@fixture.ButtonDemo, MacButtonSessionError] {
  match input {
    @primitives.KeyPressed(key=@primitives.Tab, repeat=false, ..) =>
      if demo.button().is_focused() {
        Ok(demo.blur())
      } else {
        mac_button_fixture_result(demo.focus_button())
      }
    @primitives.KeyPressed(key=@primitives.Character(key), repeat=false, ..) =>
      if key == "d" || key == "D" {
        mac_button_fixture_result(
          demo.with_enabled(!demo.button().is_enabled()),
        )
      } else if key == "l" || key == "L" {
        mac_button_fixture_result(
          demo.with_loading(!demo.button().is_loading()),
        )
      } else if key == "r" || key == "R" {
        mac_button_fixture_result(demo.reset_session())
      } else {
        Ok(demo.handle_input(input))
      }
    _ => Ok(demo.handle_input(input))
  }
}

///|
/// Consume one event for this window. Invalid or zero dimensions suspend
/// presentation and disarm input; the next positive resize reuses the fixture
/// only after that cancellation has taken effect.
fn MacButtonSession::handle_event(
  self : MacButtonSession,
  event : @platform.Event,
) -> Result[(MacButtonSession, Bool), MacButtonSessionError] {
  let mut next = { ..self, scale: event.scale(), }
  let mut repaint = false
  match event.kind() {
    @platform.Created | @platform.Wake => repaint = next.presentable
    @platform.Resized(width~, height~) =>
      if width.is_nan() ||
        width.is_inf() ||
        width <= 0.0 ||
        height.is_nan() ||
        height.is_inf() ||
        height <= 0.0 {
        next = {
          ..next,
          demo: next.demo.blur(),
          width,
          height,
          presentable: false,
        }
      } else if !mac_button_valid_scale(next.scale) {
        next = {
          ..next,
          demo: next.demo.blur(),
          width,
          height,
          presentable: false,
        }
      } else {
        match next.demo.resize(width, height) {
          Ok(demo) => {
            next = { ..next, demo, width, height, presentable: true, }
            repaint = true
          }
          Err(_) =>
            next = { ..next, demo: next.demo.blur(), presentable: false, }
        }
      }
    @platform.ScaleChanged =>
      if !mac_button_valid_scale(next.scale) {
        next = { ..next, demo: next.demo.blur(), presentable: false, }
      } else if next.presentable {
        repaint = true
      } else {
        match next.demo.resize(next.width, next.height) {
          Ok(demo) => {
            next = { ..next, demo, presentable: true, }
            repaint = true
          }
          Err(_) =>
            next = { ..next, demo: next.demo.blur(), presentable: false, }
        }
      }
    @platform.FocusChanged(false) | @platform.VisibilityChanged(false) => {
      next = { ..next, demo: next.demo.blur(), }
      repaint = next.presentable
    }
    @platform.FocusChanged(true) | @platform.VisibilityChanged(true) =>
      repaint = next.presentable
    @platform.Input(input) if next.presentable =>
      match mac_button_route_input(next.demo, input) {
        Ok(demo) => {
          next = { ..next, demo, }
          repaint = true
        }
        Err(error) => return Err(error)
      }
    @platform.CloseRequested | @platform.Destroyed | @platform.ExitRequested =>
      next = { ..next, demo: next.demo.blur(), presentable: false, }
    _ => ()
  }
  Ok((next, repaint))
}
