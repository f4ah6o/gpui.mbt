///|
/// Adapter between Win32 host events and the shared portable Button fixture.
/// It owns no HWND or GPU resources; the executable owns those lifetimes.
struct WindowsButtonSession {
  demo : @fixture.ButtonDemo
  width : Double
  height : Double
  scale : Double
  presentable : Bool
  repeat_keydowns : Int
  unmatched_key_releases : Int
  unmatched_pointer_releases : Int
}

///|
enum WindowsButtonSessionError {
  InvalidMetrics
  FixtureFailure
  Suspended
}

///|
fn windows_button_fixture_result(
  result : Result[@fixture.ButtonDemo, @fixture.ButtonDemoError],
) -> Result[@fixture.ButtonDemo, WindowsButtonSessionError] {
  match result {
    Ok(value) => Ok(value)
    Err(_) => Err(FixtureFailure)
  }
}

///|
fn windows_button_valid_scale(scale : Double) -> Bool {
  !scale.is_nan() && !scale.is_inf() && scale > 0.0
}

///|
fn WindowsButtonSession::new(
  width : Double,
  height : Double,
  scale : Double,
) -> Result[WindowsButtonSession, WindowsButtonSessionError] {
  if width.is_nan() ||
    width.is_inf() ||
    width <= 0.0 ||
    height.is_nan() ||
    height.is_inf() ||
    height <= 0.0 ||
    !windows_button_valid_scale(scale) {
    return Err(InvalidMetrics)
  }
  match @fixture.ButtonDemo::new(width, height) {
    Ok(demo) =>
      Ok({
        demo,
        width,
        height,
        scale,
        presentable: true,
        repeat_keydowns: 0,
        unmatched_key_releases: 0,
        unmatched_pointer_releases: 0,
      })
    Err(_) => Err(FixtureFailure)
  }
}

///|
fn WindowsButtonSession::demo(
  self : WindowsButtonSession,
) -> @fixture.ButtonDemo {
  self.demo
}

///|
fn WindowsButtonSession::is_presentable(self : WindowsButtonSession) -> Bool {
  self.presentable
}

///|
/// Reconcile a pending draw with the HWND's current client metrics. Exact
/// matches are a no-op so a metrics poll cannot cancel an armed gesture.
fn WindowsButtonSession::sync_metrics(
  self : WindowsButtonSession,
  width : Double,
  height : Double,
  scale : Double,
) -> (WindowsButtonSession, Bool) {
  if width.is_nan() ||
    width.is_inf() ||
    width <= 0.0 ||
    height.is_nan() ||
    height.is_inf() ||
    height <= 0.0 ||
    !windows_button_valid_scale(scale) {
    return (
      {
        ..self,
        demo: self.demo.blur(),
        width,
        height,
        scale,
        presentable: false,
      },
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
    Ok(demo) =>
      ({ ..self, demo, width, height, scale, presentable: true, }, true)
    Err(_) =>
      (
        {
          ..self,
          demo: self.demo.blur(),
          width,
          height,
          scale,
          presentable: false,
        },
        false,
      )
  }
}

///|
fn WindowsButtonSession::scene(
  self : WindowsButtonSession,
) -> Result[@scene.SceneSnapshot, WindowsButtonSessionError] {
  if !self.presentable {
    return Err(Suspended)
  }
  match self.demo.scene(self.scale) {
    Ok(value) => Ok(value)
    Err(_) => Err(FixtureFailure)
  }
}

///|
fn windows_button_route_input(
  demo : @fixture.ButtonDemo,
  input : @primitives.InputEvent,
) -> Result[@fixture.ButtonDemo, WindowsButtonSessionError] {
  match input {
    @primitives.KeyPressed(key=@primitives.Tab, repeat=false, ..) =>
      if demo.button().is_focused() {
        Ok(demo.blur())
      } else {
        windows_button_fixture_result(demo.focus_button())
      }
    // Win32 reports printable keys as committed TextInput records, separate
    // from WM_KEYDOWN. These sample-only controls keep the shared Button model
    // platform neutral while still exercising disable/loading/reset natively.
    @primitives.TextInput(text~) if text == "d" || text == "D" =>
      windows_button_fixture_result(
        demo.with_enabled(!demo.button().is_enabled()),
      )
    @primitives.TextInput(text~) if text == "l" || text == "L" =>
      windows_button_fixture_result(
        demo.with_loading(!demo.button().is_loading()),
      )
    @primitives.TextInput(text~) if text == "r" || text == "R" =>
      windows_button_fixture_result(demo.reset_session())
    _ => Ok(demo.handle_input(input))
  }
}

///|
/// Consume one event for the fixture's HWND. Invalid/zero sizes suspend
/// presentation and disarm input; a later valid size starts from a canceled
/// session. The host still owns DPI and event ordering.
fn WindowsButtonSession::handle_event(
  self : WindowsButtonSession,
  event : @platform.Event,
) -> Result[(WindowsButtonSession, Bool), WindowsButtonSessionError] {
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
        height <= 0.0 ||
        !windows_button_valid_scale(next.scale) {
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
      if !windows_button_valid_scale(next.scale) {
        next = { ..next, demo: next.demo.blur(), presentable: false, }
      } else if next.presentable {
        repaint = true
      } else if next.width > 0.0 && next.height > 0.0 {
        match next.demo.resize(next.width, next.height) {
          Ok(demo) => {
            next = { ..next, demo, presentable: true, }
            repaint = true
          }
          Err(_) => next = { ..next, demo: next.demo.blur(), }
        }
      }
    @platform.FocusChanged(false) | @platform.VisibilityChanged(false) => {
      next = { ..next, demo: next.demo.blur(), }
      repaint = next.presentable
    }
    @platform.FocusChanged(true) | @platform.VisibilityChanged(true) =>
      repaint = next.presentable
    @platform.Input(input) if next.presentable => {
      let repeat_keydowns = match input {
        @primitives.KeyPressed(repeat=true, ..) => next.repeat_keydowns + 1
        _ => next.repeat_keydowns
      }
      let button_was_pressed = next.demo.button().is_pressed()
      let unmatched_key_releases = match input {
        @primitives.KeyReleased(key=@primitives.Enter, ..) if !button_was_pressed =>
          next.unmatched_key_releases + 1
        @primitives.KeyReleased(key=@primitives.Space, ..) if !button_was_pressed =>
          next.unmatched_key_releases + 1
        _ => next.unmatched_key_releases
      }
      let unmatched_pointer_releases = match input {
        @primitives.PointerButtonReleased(button=@primitives.Primary, ..) if !button_was_pressed =>
          next.unmatched_pointer_releases + 1
        _ => next.unmatched_pointer_releases
      }
      next = {
        ..next,
        repeat_keydowns,
        unmatched_key_releases,
        unmatched_pointer_releases,
      }
      match windows_button_route_input(next.demo, input) {
        Ok(demo) => {
          next = { ..next, demo, }
          repaint = true
        }
        Err(error) => return Err(error)
      }
    }
    @platform.CloseRequested | @platform.Destroyed | @platform.ExitRequested =>
      next = { ..next, demo: next.demo.blur(), presentable: false, }
    _ => ()
  }
  Ok((next, repaint))
}
