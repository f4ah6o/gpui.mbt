///|
/// The JS-only adapter owns no rendering or application behavior.
priv struct BrowserAdapter {
  demo : @browser_app.BrowserDemo
}

///|
let adapter_runtime : Ref[BrowserAdapter?] = Ref(None)

///|
fn ok_json(payload : String) -> String {
  "{\"ok\":true,\"value\":\{payload}}"
}

///|
fn error_json(error : @diagnostics.FrameworkError) -> String {
  let code = @browser_app.json_quote(error.code().label())
  let operation = @browser_app.json_quote(error.operation())
  let subsystem = match error.subsystem() {
    None => "null"
    Some(value) => @browser_app.json_quote(value)
  }
  let backend = match error.backend() {
    None => "null"
    Some(value) => @browser_app.json_quote(value)
  }
  let message = match error.message() {
    None => "null"
    Some(value) => @browser_app.json_quote(value)
  }
  "{\"ok\":false,\"error\":{\"code\":\{code},\"operation\":\{operation},\"subsystem\":\{subsystem},\"backend\":\{backend},\"message\":\{message}}}"
}

///|
fn host_error(kind : Int) -> @diagnostics.FrameworkError {
  let (code, operation, message) = match kind {
    0 =>
      (
        @diagnostics.WindowUnavailable,
        "BrowserBackend::create_window",
        "the browser host page has no canvas viewport",
      )
    1 =>
      (
        @diagnostics.UnsupportedCapability,
        "BrowserBackend::create_renderer",
        "Canvas 2D is unavailable in this browser context",
      )
    2 =>
      (
        @diagnostics.InvalidInput,
        "BrowserBackend::set_size",
        "the browser reported an invalid logical size or device scale",
      )
    3 =>
      (
        @diagnostics.HostStopping,
        "BrowserBackend::enqueue_event",
        "the logical browser viewport has been destroyed",
      )
    4 =>
      (
        @diagnostics.ConversionFailed,
        "BrowserBackend::present",
        "the SceneSnapshot is invalid or unsupported by the Canvas 2D slice",
      )
    _ =>
      (
        @diagnostics.SurfaceLost,
        "BrowserBackend::present",
        "the browser Canvas 2D context failed while presenting the frame",
      )
  }
  @diagnostics.FrameworkError::new(
    code,
    operation,
    subsystem="browser",
    backend="js/canvas-2d",
    message~,
  )
}

///|
#export_name("gpui_browser_host_error")
pub fn browser_host_error(kind : Int) -> String {
  error_json(host_error(kind))
}

///|
#export_name("gpui_browser_capabilities")
pub fn browser_capabilities() -> String {
  "{\"logicalViewport\":true,\"nativeWindow\":false,\"quadFrames\":true,\"frameScheduling\":\"requestAnimationFrame\",\"pointerKeyboard\":true,\"clipboard\":false,\"cursor\":false,\"textInputIme\":false,\"accessibility\":false,\"rendererRecovery\":false,\"crossThreadCommands\":false,\"renderer\":\"Canvas 2D\"}"
}

///|
#export_name("gpui_browser_start")
pub fn browser_start() -> String {
  match adapter_runtime.val {
    Some(_) => ok_json("true")
    None =>
      match @browser_app.BrowserDemo::new() {
        Err(error) => error_json(error)
        Ok(demo) => {
          adapter_runtime.val = Some({ demo, })
          ok_json("true")
        }
      }
  }
}

///|
#export_name("gpui_browser_set_viewport")
pub fn browser_set_viewport(
  width : Double,
  height : Double,
  scale : Double,
) -> String {
  match adapter_runtime.val {
    None => error_json(host_error(3))
    Some(adapter) =>
      match
        @browser_app.BrowserDemo::set_viewport(
          adapter.demo,
          width,
          height,
          scale,
        ) {
        Err(@browser_app.InvalidViewport) => error_json(host_error(2))
        Err(@browser_app.Stopped) => error_json(host_error(3))
        Err(_) => error_json(host_error(2))
        Ok(_) => ok_json("true")
      }
  }
}

///|
fn enqueue_event(event : @platform.EventKind) -> String {
  match adapter_runtime.val {
    None => error_json(host_error(3))
    Some(adapter) =>
      match @browser_app.BrowserDemo::enqueue_event(adapter.demo, event) {
        Err(_) => error_json(host_error(3))
        Ok(_) => ok_json("true")
      }
  }
}

///|
#export_name("gpui_browser_pointer_move")
pub fn browser_pointer_move(x : Double, y : Double) -> String {
  match @primitives.Point::new(x, y) {
    Err(_) => error_json(host_error(2))
    Ok(position) =>
      enqueue_event(@platform.Input(@primitives.PointerMoved(position~)))
  }
}

///|
#export_name("gpui_browser_pointer_button")
pub fn browser_pointer_button(
  x : Double,
  y : Double,
  button : Int,
  pressed : Bool,
  shift : Bool,
  control : Bool,
  alt : Bool,
  meta : Bool,
) -> String {
  match (@primitives.Point::new(x, y), mouse_button(button)) {
    (Err(_), _) => error_json(host_error(2))
    (_, None) => error_json(host_error(2))
    (Ok(position), Some(button)) => {
      let modifiers = @primitives.Modifiers::new(shift~, control~, alt~, meta~)
      let event = if pressed {
        @platform.Input(
          @primitives.PointerButtonPressed(position~, button~, modifiers~),
        )
      } else {
        @platform.Input(
          @primitives.PointerButtonReleased(position~, button~, modifiers~),
        )
      }
      enqueue_event(event)
    }
  }
}

///|
fn mouse_button(button : Int) -> @primitives.MouseButton? {
  match button {
    0 => Some(@primitives.Primary)
    1 => Some(@primitives.Middle)
    2 => Some(@primitives.Secondary)
    3 => Some(@primitives.Back)
    4 => Some(@primitives.Forward)
    _ => None
  }
}

///|
fn key_from_browser(key : String) -> @primitives.Key {
  match key {
    "Enter" => @primitives.Enter
    "Escape" => @primitives.Escape
    "Backspace" => @primitives.Backspace
    "Delete" => @primitives.Delete
    "Tab" => @primitives.Tab
    " " => @primitives.Space
    "ArrowLeft" => @primitives.ArrowLeft
    "ArrowRight" => @primitives.ArrowRight
    "ArrowUp" => @primitives.ArrowUp
    "ArrowDown" => @primitives.ArrowDown
    "Home" => @primitives.Home
    "End" => @primitives.End
    "PageUp" => @primitives.PageUp
    "PageDown" => @primitives.PageDown
    _ => @primitives.Character(key)
  }
}

///|
#export_name("gpui_browser_key")
pub fn browser_key(
  key : String,
  pressed : Bool,
  repeat : Bool,
  shift : Bool,
  control : Bool,
  alt : Bool,
  meta : Bool,
) -> String {
  let modifiers = @primitives.Modifiers::new(shift~, control~, alt~, meta~)
  let logical_key = key_from_browser(key)
  let event = if pressed {
    @platform.Input(
      @primitives.KeyPressed(key=logical_key, modifiers~, repeat~),
    )
  } else {
    @platform.Input(@primitives.KeyReleased(key=logical_key, modifiers~))
  }
  enqueue_event(event)
}

///|
#export_name("gpui_browser_focus")
pub fn browser_focus(focused : Bool) -> String {
  enqueue_event(@platform.FocusChanged(focused))
}

///|
#export_name("gpui_browser_visibility")
pub fn browser_visibility(visible : Bool) -> String {
  enqueue_event(@platform.VisibilityChanged(visible))
}

///|
#export_name("gpui_browser_render_frame")
pub fn browser_render_frame() -> String {
  match adapter_runtime.val {
    None => error_json(host_error(3))
    Some(adapter) =>
      match @browser_app.BrowserDemo::render_frame(adapter.demo) {
        Err(@browser_app.Stopped) => error_json(host_error(3))
        Err(@browser_app.InvalidViewport) => error_json(host_error(2))
        Err(_) => error_json(host_error(4))
        Ok(snapshot) => ok_json(snapshot.canonical_json())
      }
  }
}

///|
#export_name("gpui_browser_status")
pub fn browser_status() -> String {
  match adapter_runtime.val {
    None => "{\"active\":false}"
    Some(adapter) => @browser_app.BrowserDemo::status_json(adapter.demo)
  }
}

///|
#export_name("gpui_browser_destroy")
pub fn browser_destroy() -> Unit {
  match adapter_runtime.val {
    None => ()
    Some(adapter) => {
      @browser_app.BrowserDemo::dispose(adapter.demo)
      adapter_runtime.val = None
    }
  }
}
