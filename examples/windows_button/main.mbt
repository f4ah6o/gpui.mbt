///|
extern "C" fn native_button_flush_stdout() -> Unit = "gpui_windows_button_flush_stdout"

///|
const WINDOWS_BUTTON_WIDTH : Double = 640.0

///|
const WINDOWS_BUTTON_HEIGHT : Double = 240.0

///|
const WINDOWS_BUTTON_SAMPLE_X : Double = 250.0

///|
const WINDOWS_BUTTON_SAMPLE_Y : Double = 60.0

///|
struct WindowsButtonInkStats {
  count : Int
}

///|
fn[T] windows_button_required(
  result : Result[T, @diagnostics.FrameworkError],
) -> T {
  match result {
    Ok(value) => value
    Err(error) => abort("\{error.operation()}: \{error.code().label()}")
  }
}

///|
fn windows_button_log(line : String) -> Unit {
  println(line)
  native_button_flush_stdout()
}

///|
fn windows_button_report(error : @diagnostics.FrameworkError) -> Unit {
  windows_button_log("\{error.operation()}: \{error.code().label()}")
}

///|
fn windows_button_session_error(
  operation : String,
  error : WindowsButtonSessionError,
) -> @diagnostics.FrameworkError {
  match error {
    InvalidMetrics =>
      @diagnostics.FrameworkError::new(
        @diagnostics.InvalidInput,
        operation,
        subsystem="windows-button",
        backend="win32-d3d11",
        message="invalid window metrics",
      )
    FixtureFailure =>
      @diagnostics.FrameworkError::new(
        @diagnostics.InvalidInput,
        operation,
        subsystem="windows-button",
        backend="win32-d3d11",
        message="portable Button fixture rejected the state",
      )
    Suspended =>
      @diagnostics.FrameworkError::new(
        @diagnostics.Busy,
        operation,
        subsystem="windows-button",
        backend="win32-d3d11",
        message="window is not currently presentable",
      )
  }
}

///|
fn windows_button_session_error_name(
  error : WindowsButtonSessionError,
) -> String {
  match error {
    InvalidMetrics => "invalid window metrics"
    FixtureFailure => "portable Button fixture rejected the state"
    Suspended => "window is not currently presentable"
  }
}

///|
fn windows_button_is_escape(kind : @platform.EventKind) -> Bool {
  match kind {
    @platform.Input(
      @primitives.KeyPressed(key=@primitives.Escape, repeat=false, ..)
    ) => true
    _ => false
  }
}

///|
fn windows_button_pixel_matches(
  frame : @testing.FrameCapture,
  logical_x : Double,
  logical_y : Double,
  red : Int,
  green : Int,
  blue : Int,
) -> Bool {
  let x = (logical_x * frame.scale()).to_int()
  let y = (logical_y * frame.scale()).to_int()
  match frame.pixel_rgba8(x, y) {
    Err(_) => false
    Ok((actual_red, actual_green, actual_blue, alpha)) =>
      actual_red >= red - 3 &&
      actual_red <= red + 3 &&
      actual_green >= green - 3 &&
      actual_green <= green + 3 &&
      actual_blue >= blue - 3 &&
      actual_blue <= blue + 3 &&
      alpha >= 250
  }
}

///|
fn windows_button_text_ink(
  frame : @testing.FrameCapture,
  left : Double,
  top : Double,
  right : Double,
  bottom : Double,
) -> WindowsButtonInkStats {
  let scale = frame.scale()
  let x0 = (left * scale).to_int()
  let y0 = (top * scale).to_int()
  let x1 = (right * scale).to_int()
  let y1 = (bottom * scale).to_int()
  let pixels = frame.rgba8_top_left()
  let mut count = 0
  for y in y0..<y1 {
    for x in x0..<x1 {
      let offset = (y * frame.width() + x) * 4
      let red = pixels.unsafe_get(offset).to_int()
      let green = pixels.unsafe_get(offset + 1).to_int()
      let blue = pixels.unsafe_get(offset + 2).to_int()
      let alpha = pixels.unsafe_get(offset + 3).to_int()
      if red >= 150 && green >= 150 && blue >= 150 && alpha >= 220 {
        count += 1
      }
    }
  }
  { count, }
}

///|
fn windows_button_check_initial_frame(
  frame : @testing.FrameCapture,
  width : Double,
  height : Double,
) -> Bool {
  let width_delta = frame.width().to_double() - width * frame.scale()
  let height_delta = frame.height().to_double() - height * frame.scale()
  let label = windows_button_text_ink(frame, 32.0, 22.0, 256.0, 68.0)
  let status = windows_button_text_ink(frame, 8.0, 88.0, 148.0, 108.0)
  width > 0.0 &&
  height > 0.0 &&
  frame.scale() > 0.0 &&
  width_delta >= -1.0 &&
  width_delta <= 1.0 &&
  height_delta >= -1.0 &&
  height_delta <= 1.0 &&
  windows_button_pixel_matches(frame, 8.0, 8.0, 24, 28, 36) &&
  windows_button_pixel_matches(
    frame,
    WINDOWS_BUTTON_SAMPLE_X,
    WINDOWS_BUTTON_SAMPLE_Y,
    42,
    71,
    101,
  ) &&
  label.count >= 4 &&
  status.count >= 4
}

///|
fn windows_button_json_bool(value : Bool) -> String {
  if value {
    "true"
  } else {
    "false"
  }
}

///|
fn windows_button_state_line(
  presentation : Int,
  event_sequence : Int64,
  session : WindowsButtonSession,
) -> String {
  let demo = session.demo()
  let button = demo.button()
  let nodes = demo.accessibility_snapshot().nodes()
  let semantic_button = if nodes.length() > 1 { Some(nodes[1]) } else { None }
  let semantic = match semantic_button {
    None => "null"
    Some(node) =>
      "{\"key\":\{node.id().key()},\"name\":\{@json.to_json(node.name()).stringify()},\"enabled\":\{windows_button_json_bool(node.is_enabled())},\"loading\":\{windows_button_json_bool(node.is_loading())},\"focused\":\{windows_button_json_bool(node.is_focused())}}"
  }
  "GPUI_WINDOWS_BUTTON_STATE {\"presentation\":\{presentation},\"event_sequence\":\{event_sequence},\"width\":\{session.width},\"height\":\{session.height},\"scale\":\{session.scale},\"presentable\":\{windows_button_json_bool(session.is_presentable())},\"visible\":\{windows_button_json_bool(demo.is_button_visible())},\"activations\":\{demo.activations()},\"enabled\":\{windows_button_json_bool(button.is_enabled())},\"loading\":\{windows_button_json_bool(button.is_loading())},\"focused\":\{windows_button_json_bool(button.is_focused())},\"hovered\":\{windows_button_json_bool(button.is_hovered())},\"pressed\":\{windows_button_json_bool(button.is_pressed())},\"repeat_keydowns\":\{session.repeat_keydowns},\"unmatched_key_releases\":\{session.unmatched_key_releases},\"unmatched_pointer_releases\":\{session.unmatched_pointer_releases},\"semantic_revision\":\{demo.accessibility_snapshot().revision()},\"semantic_nodes\":\{nodes.length()},\"semantic_button\":\{semantic}}"
}

///|
fn windows_button_rgba(
  frame : @testing.FrameCapture,
  logical_x : Double,
  logical_y : Double,
) -> String {
  let x = (logical_x * frame.scale()).to_int()
  let y = (logical_y * frame.scale()).to_int()
  match frame.pixel_rgba8(x, y) {
    Err(_) => "null"
    Ok((red, green, blue, alpha)) => "[\{red},\{green},\{blue},\{alpha}]"
  }
}

///|
fn windows_button_frame_line(
  presentation : Int,
  event_sequence : Int64,
  session : WindowsButtonSession,
  frame : @testing.FrameCapture,
) -> String {
  let label = windows_button_text_ink(frame, 32.0, 22.0, 256.0, 68.0)
  let status = windows_button_text_ink(frame, 8.0, 88.0, 148.0, 108.0)
  "GPUI_WINDOWS_BUTTON_FRAME {\"presentation\":\{presentation},\"event_sequence\":\{event_sequence},\"pixel_width\":\{frame.width()},\"pixel_height\":\{frame.height()},\"scale\":\{frame.scale()},\"background\":\{windows_button_rgba(frame, 8.0, 8.0)},\"button\":\{windows_button_rgba(frame, WINDOWS_BUTTON_SAMPLE_X, WINDOWS_BUTTON_SAMPLE_Y)},\"label_ink\":\{label.count},\"status_ink\":\{status.count},\"focused\":\{windows_button_json_bool(session.demo().button().is_focused())},\"pressed\":\{windows_button_json_bool(session.demo().button().is_pressed())},\"enabled\":\{windows_button_json_bool(session.demo().button().is_enabled())},\"loading\":\{windows_button_json_bool(session.demo().button().is_loading())}}"
}

///|
fn windows_button_run() -> Unit {
  let host = windows_button_required(@native.Host::start())
  let window = windows_button_required(
    host.create_window(
      WINDOWS_BUTTON_WIDTH.to_int(),
      WINDOWS_BUTTON_HEIGHT.to_int(),
      "gpui.mbt — Windows reusable Button",
    ),
  )
  let (width, height, scale) = windows_button_required(
    host.window_metrics(window),
  )
  let mut session = match WindowsButtonSession::new(width, height, scale) {
    Ok(value) => value
    Err(error) =>
      abort("button_session: \{windows_button_session_error_name(error)}")
  }
  let smoke = @env.get_env_var("GPUI_WINDOWS_BUTTON_SMOKE") == Some("1")
  let observe = @env.get_env_var("GPUI_WINDOWS_BUTTON_OBSERVE") == Some("1")
  let mut dirty = true
  let mut has_accepted_frame = false
  let mut presentations = 0
  let mut completions = 0
  let mut captured_readbacks = 0
  let mut readback_failed = false
  let mut last_sequence : Int64 = 0
  let mut done = false

  if smoke || observe {
    windows_button_log(
      "Windows Button Stage A started; semantics use the shared headless snapshot. UI Automation is unsupported.",
    )
  }

  while !done && host.state() == @native.Running {
    match host.dispatch(16) {
      Err(error) => {
        windows_button_report(error)
        ignore(host.request_exit())
      }
      Ok(events) =>
        for event in events {
          if event.window() == window {
            if event.sequence() <= last_sequence {
              abort("Windows button event sequence did not increase")
            }
            last_sequence = event.sequence()
            let kind = event.kind()
            if kind is @platform.FrameCompleted {
              completions += 1
              if (smoke || observe) && has_accepted_frame {
                match @testing.capture_frame(host, window) {
                  Err(error) => {
                    readback_failed = true
                    windows_button_report(error)
                    ignore(host.request_exit())
                  }
                  Ok(frame) => {
                    captured_readbacks += 1
                    windows_button_log(
                      windows_button_frame_line(
                        presentations,
                        event.sequence(),
                        session,
                        frame,
                      ),
                    )
                    if smoke &&
                      completions == 1 &&
                      !windows_button_check_initial_frame(
                        frame,
                        session.width,
                        session.height,
                      ) {
                      abort(
                        "Windows Button first completed GPU frame failed viewport, color, or text-pixel checks",
                      )
                    }
                  }
                }
              }
              if smoke && has_accepted_frame && !readback_failed {
                windows_button_log("GPUI_WINDOWS_BUTTON_SMOKE PASS")
                done = true
              }
            } else {
              let (next_session, repaint) = match session.handle_event(event) {
                Ok(value) => value
                Err(error) => {
                  windows_button_report(
                    windows_button_session_error("button_event", error),
                  )
                  ignore(host.request_exit())
                  (session, false)
                }
              }
              session = next_session
              dirty = dirty || repaint
              if windows_button_is_escape(kind) {
                ignore(host.request_exit())
                done = true
              }
              match kind {
                @platform.CloseRequested | @platform.ExitRequested =>
                  ignore(host.request_exit())
                @platform.Destroyed => done = true
                _ => ()
              }
            }
          }
        }
    }

    if !done && dirty && host.state() == @native.Running {
      match host.window_metrics(window) {
        Err(error) => {
          windows_button_report(error)
          ignore(host.request_exit())
          done = true
        }
        Ok((current_width, current_height, current_scale)) => {
          let (current_session, repaint) = session.sync_metrics(
            current_width, current_height, current_scale,
          )
          session = current_session
          dirty = dirty || repaint
          if session.is_presentable() {
            match session.scene() {
              Err(error) => {
                windows_button_report(
                  windows_button_session_error("button_scene", error),
                )
                ignore(host.request_exit())
                done = true
              }
              Ok(snapshot) =>
                match host.present(window, snapshot) {
                  Ok(_) => {
                    dirty = false
                    presentations += 1
                    has_accepted_frame = true
                    if observe || smoke {
                      windows_button_log(
                        windows_button_state_line(
                          presentations, last_sequence, session,
                        ),
                      )
                    }
                  }
                  Err(error) =>
                    if error.code() is @diagnostics.Busy {
                      ()
                    } else {
                      windows_button_report(error)
                      ignore(host.request_exit())
                      done = true
                    }
                }
            }
          } else {
            dirty = false
          }
        }
      }
    } else if !session.is_presentable() {
      dirty = false
    }
  }

  session.demo().close()
  windows_button_required(host.destroy_window(window))
  windows_button_required(host.stop())
  if smoke && (completions == 0 || captured_readbacks == 0 || readback_failed) {
    abort(
      "Windows Button smoke exited without a successful completed-frame readback",
    )
  }
}

///|
fn main {
  windows_button_run()
}
