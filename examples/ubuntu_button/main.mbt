///|
fn[T] ubuntu_button_required(
  result : Result[T, @diagnostics.FrameworkError],
) -> T {
  match result {
    Ok(value) => value
    Err(error) => abort("\{error.operation()}: \{error.code().label()}")
  }
}

///|
fn ubuntu_button_report(error : @diagnostics.FrameworkError) -> Unit {
  println("\{error.operation()}: \{error.code().label()}")
}

///|
fn ubuntu_button_escape_key(event : @primitives.InputEvent) -> Bool {
  match event {
    @primitives.KeyPressed(key=@primitives.Escape, ..) => true
    _ => false
  }
}

///|
fn ubuntu_button_activation_toggle(event : @primitives.InputEvent) -> String? {
  match event {
    @primitives.KeyPressed(key=@primitives.Character(key), repeat=false, ..) =>
      if key == "d" || key == "D" {
        Some("disabled")
      } else if key == "l" || key == "L" {
        Some("loading")
      } else if key == "r" || key == "R" {
        Some("reset")
      } else {
        None
      }
    _ => None
  }
}

///|
fn ubuntu_button_tab(event : @primitives.InputEvent) -> Bool {
  match event {
    @primitives.KeyPressed(key=@primitives.Tab, repeat=false, ..) => true
    _ => false
  }
}

///|
fn ubuntu_button_scene_error(error : @fixture.ButtonDemoError) -> String {
  match error {
    @fixture.InvalidViewport => "invalid viewport"
    @fixture.ButtonError(_) => "button rejected"
    @fixture.ElementError(_) => "element tree rejected"
    @fixture.PaintError(_) => "button paint rejected"
    @fixture.SceneError(_) => "scene snapshot rejected"
    @fixture.AccessibilityError(_) => "accessibility model rejected"
    @fixture.StaleFixtureState => "fixture state is stale"
  }
}

///|
fn ubuntu_button_run() -> Unit {
  let host = ubuntu_button_required(@native.Host::start())
  let window = ubuntu_button_required(
    host.create_window(640, 240, "gpui.mbt Ubuntu button foundation"),
  )
  ubuntu_button_required(host.require_capability(@platform.GrayscaleTextFrames))

  let mut width = 640.0
  let mut height = 240.0
  let mut scale = 1.0
  let mut demo = match @fixture.ButtonDemo::new(width, height) {
    Ok(value) => value
    Err(error) => abort(ubuntu_button_scene_error(error))
  }
  let mut dirty = true
  let mut presentable = true
  let mut frames = 0
  let smoke = @env.get_env_var("GPUI_UBUNTU_BUTTON_SMOKE") == Some("1")

  while host.state() == @native.Running {
    match host.next_event(timeout_ms=16) {
      Err(error) => {
        ubuntu_button_report(error)
        ignore(host.request_exit())
      }
      Ok(Some(event)) => {
        scale = event.scale()
        match event.kind() {
          @platform.Resized(width=new_width, height=new_height) => {
            width = new_width
            height = new_height
            if width <= 0.0 || height <= 0.0 {
              demo = demo.blur()
              presentable = false
              dirty = false
            } else {
              match demo.resize(width, height) {
                Ok(value) => {
                  demo = value
                  presentable = true
                  dirty = true
                }
                Err(error) => {
                  println(ubuntu_button_scene_error(error))
                  demo = demo.blur()
                  presentable = false
                  dirty = false
                }
              }
            }
          }
          @platform.ScaleChanged => dirty = true
          @platform.FocusChanged(false) | @platform.VisibilityChanged(false) => {
            demo = demo.blur()
            dirty = true
          }
          @platform.CloseRequested => ignore(host.request_exit())
          @platform.FrameCompleted => {
            frames += 1
            if smoke {
              ignore(host.request_exit())
            }
          }
          @platform.Input(input) =>
            if !presentable {
              if ubuntu_button_escape_key(input) {
                ignore(host.request_exit())
              }
            } else if ubuntu_button_escape_key(input) {
              ignore(host.request_exit())
            } else if ubuntu_button_tab(input) {
              if demo.button().is_focused() {
                demo = demo.blur()
              } else {
                match demo.focus_button() {
                  Ok(value) => demo = value
                  Err(error) => println(ubuntu_button_scene_error(error))
                }
              }
              dirty = true
            } else {
              match ubuntu_button_activation_toggle(input) {
                Some("disabled") => {
                  match demo.with_enabled(!demo.button().is_enabled()) {
                    Ok(value) => demo = value
                    Err(error) => println(ubuntu_button_scene_error(error))
                  }
                  dirty = true
                }
                Some("loading") => {
                  match demo.with_loading(!demo.button().is_loading()) {
                    Ok(value) => demo = value
                    Err(error) => println(ubuntu_button_scene_error(error))
                  }
                  dirty = true
                }
                Some("reset") => {
                  match demo.reset_session() {
                    Ok(value) => demo = value
                    Err(error) => println(ubuntu_button_scene_error(error))
                  }
                  dirty = true
                }
                _ => {
                  demo = demo.handle_input(input)
                  dirty = true
                }
              }
            }
          _ => ()
        }
      }
      Ok(None) => ()
    }

    if dirty && presentable && host.state() == @native.Running {
      match demo.scene(scale) {
        Err(error) => {
          println(ubuntu_button_scene_error(error))
          ignore(host.request_exit())
        }
        Ok(snapshot) =>
          match host.present(window, snapshot) {
            Ok(_) => dirty = false
            Err(error) =>
              if error.code() is @diagnostics.Busy {
                ()
              } else {
                ubuntu_button_report(error)
                ignore(host.request_exit())
              }
          }
      }
    }
  }

  ignore(host.destroy_window(window))
  ubuntu_button_required(host.stop())
  if smoke && frames == 0 {
    abort("no Ubuntu button frame completed")
  }
}

///|
fn main {
  ubuntu_button_run()
}
