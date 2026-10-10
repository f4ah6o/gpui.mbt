///|
const MAC_BUTTON_WIDTH : Double = 640.0

///|
const MAC_BUTTON_HEIGHT : Double = 240.0

///|
const MAC_BUTTON_ACTION_X : Double = 144.0

///|
const MAC_BUTTON_ACTION_Y : Double = 44.0

///|
struct MacButtonInkStats {
  count : Int
  first_y : Int
  last_y : Int
}

///|
fn mac_button_failure(
  operation : String,
  message : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.NativeFailure,
    operation,
    subsystem="macos-button",
    backend="appkit-metal",
    message~,
  )
}

///|
fn mac_button_session_failure(
  operation : String,
  failure : MacButtonSessionError,
) -> @diagnostics.FrameworkError {
  match failure {
    InvalidMetrics =>
      @diagnostics.FrameworkError::new(
        @diagnostics.InvalidInput,
        operation,
        subsystem="macos-button",
        backend="appkit-metal",
        message="invalid window metrics",
      )
    FixtureFailure =>
      @diagnostics.FrameworkError::new(
        @diagnostics.InvalidInput,
        operation,
        subsystem="macos-button",
        backend="appkit-metal",
        message="portable Button fixture rejected the state",
      )
    Suspended =>
      @diagnostics.FrameworkError::new(
        @diagnostics.Busy,
        operation,
        subsystem="macos-button",
        backend="appkit-metal",
        message="window is not currently presentable",
      )
  }
}

///|
fn mac_button_open_session(
  host : @macos.Host,
  session_number : Int,
) -> Result[(@platform.WindowId, MacButtonSession), @diagnostics.FrameworkError] {
  let title = if session_number == 1 {
    "gpui.mbt reusable Button — macOS"
  } else {
    "gpui.mbt reusable Button — macOS (reopened)"
  }
  let window = match
    host.create_window(title, MAC_BUTTON_WIDTH, MAC_BUTTON_HEIGHT) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (width, height, scale) = match host.window_metrics(window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match MacButtonSession::new(width, height, scale) {
    Ok(session) => Ok((window, session))
    Err(error) => Err(mac_button_session_failure("button_session", error))
  }
}

///|
fn mac_button_pixel_matches(
  frame : @testing.FrameCapture,
  logical_x : Double,
  logical_y : Double,
  red : Int,
  green : Int,
  blue : Int,
) -> Bool {
  let scale = frame.scale()
  let x = (logical_x * scale).to_int()
  let y = (logical_y * scale).to_int()
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
fn mac_button_text_ink(
  frame : @testing.FrameCapture,
  left : Double,
  top : Double,
  right : Double,
  bottom : Double,
) -> MacButtonInkStats {
  let scale = frame.scale()
  let x0 = (left * scale).to_int()
  let y0 = (top * scale).to_int()
  let x1 = (right * scale).to_int()
  let y1 = (bottom * scale).to_int()
  let pixels = frame.rgba8_top_left()
  let mut count = 0
  let mut first_y = frame.height()
  let mut last_y = -1
  for y in y0..<y1 {
    for x in x0..<x1 {
      let offset = (y * frame.width() + x) * 4
      let red = pixels.unsafe_get(offset).to_int()
      let green = pixels.unsafe_get(offset + 1).to_int()
      let blue = pixels.unsafe_get(offset + 2).to_int()
      let alpha = pixels.unsafe_get(offset + 3).to_int()
      if red >= 160 && green >= 160 && blue >= 160 && alpha >= 240 {
        count += 1
        if y < first_y {
          first_y = y
        }
        if y > last_y {
          last_y = y
        }
      }
    }
  }
  { count, first_y, last_y, }
}

///|
fn mac_button_text_present(stats : MacButtonInkStats) -> Bool {
  stats.count >= 4 && stats.last_y >= stats.first_y
}

///|
/// CoreText's raster mask is anchored at the TextItem top edge. Require the
/// label ink to start near that edge and occupy a plausible 16pt glyph height.
fn mac_button_label_baseline_matches(
  frame : @testing.FrameCapture,
  stats : MacButtonInkStats,
) -> Bool {
  if !mac_button_text_present(stats) {
    return false
  }
  let scale = frame.scale()
  let first = stats.first_y.to_double() / scale
  let last = (stats.last_y + 1).to_double() / scale
  first >= 22.0 && first <= 28.0 && last >= 29.0 && last <= 47.0
}

///|
fn mac_button_status_changed(
  before : @testing.FrameCapture,
  after : @testing.FrameCapture,
) -> Bool {
  if before.width() != after.width() ||
    before.height() != after.height() ||
    before.scale() != after.scale() {
    return false
  }
  let scale = before.scale()
  let x0 = (8.0 * scale).to_int()
  let y0 = (88.0 * scale).to_int()
  let x1 = (148.0 * scale).to_int()
  let y1 = (108.0 * scale).to_int()
  let before_pixels = before.rgba8_top_left()
  let after_pixels = after.rgba8_top_left()
  let mut changed = 0
  for y in y0..<y1 {
    for x in x0..<x1 {
      let offset = (y * before.width() + x) * 4
      let differs = before_pixels.unsafe_get(offset) !=
        after_pixels.unsafe_get(offset) ||
        before_pixels.unsafe_get(offset + 1) !=
        after_pixels.unsafe_get(offset + 1) ||
        before_pixels.unsafe_get(offset + 2) !=
        after_pixels.unsafe_get(offset + 2)
      if differs {
        changed += 1
      }
    }
  }
  changed >= 2
}

///|
fn mac_button_capture(
  host : @macos.Host,
  window : @platform.WindowId,
) -> Result[@testing.FrameCapture, @diagnostics.FrameworkError] {
  @testing.capture_frame(host, window)
}

///|
fn mac_button_check_initial_pixels(
  host : @macos.Host,
  window : @platform.WindowId,
) -> Result[@testing.FrameCapture, @diagnostics.FrameworkError] {
  let frame = match mac_button_capture(host, window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (width, height, scale) = match host.window_metrics(window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let width_delta = frame.width().to_double() - width * scale
  let height_delta = frame.height().to_double() - height * scale
  let label = mac_button_text_ink(frame, 33.0, 23.0, 257.0, 67.0)
  let status = mac_button_text_ink(frame, 8.0, 88.0, 148.0, 108.0)
  if width <= 0.0 ||
    height <= 0.0 ||
    scale <= 0.0 ||
    width_delta < -1.0 ||
    width_delta > 1.0 ||
    height_delta < -1.0 ||
    height_delta > 1.0 ||
    !mac_button_pixel_matches(frame, 8.0, 8.0, 24, 28, 36) ||
    !mac_button_pixel_matches(frame, 250.0, 44.0, 42, 71, 101) ||
    !mac_button_label_baseline_matches(frame, label) ||
    !mac_button_text_present(status) {
    return Err(
      mac_button_failure(
        "button_initial_pixels", "completed Metal frame did not match the expected viewport, fill, or CoreText label",
      ),
    )
  }
  Ok(frame)
}

///|
fn mac_button_check_pressed_pixels(
  host : @macos.Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let frame = match mac_button_capture(host, window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let label = mac_button_text_ink(frame, 33.0, 23.0, 257.0, 67.0)
  if !mac_button_pixel_matches(frame, 25.0, 44.0, 98, 170, 255) ||
    !mac_button_pixel_matches(frame, 250.0, 44.0, 35, 77, 119) ||
    !mac_button_label_baseline_matches(frame, label) {
    return Err(
      mac_button_failure(
        "button_pressed_pixels", "focused/pressed Button pixels or label baseline did not match",
      ),
    )
  }
  Ok(())
}

///|
fn mac_button_check_activation_pixels(
  host : @macos.Host,
  window : @platform.WindowId,
  before : @testing.FrameCapture,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let frame = match mac_button_capture(host, window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status = mac_button_text_ink(frame, 8.0, 88.0, 148.0, 108.0)
  if !mac_button_text_present(status) ||
    !mac_button_status_changed(before, frame) {
    return Err(
      mac_button_failure(
        "button_activation_pixels", "activation status text was not visibly updated in the completed Metal frame",
      ),
    )
  }
  Ok(())
}

///|
fn mac_button_e2e_failure(stage : Int) -> @diagnostics.FrameworkError {
  mac_button_failure(
    "button_native_e2e",
    "bounded native smoke timed out at stage \{stage}",
  )
}

///|
fn mac_button_queue_resize_burst(
  host : @macos.Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match host.set_size(window, 80.0, 30.0) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match host.set_size(window, 480.0, 180.0) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  host.set_size(window, 600.0, 240.0)
}

///|
fn mac_button_check_resize_burst(
  host : @macos.Host,
  window : @platform.WindowId,
) -> Result[@testing.FrameCapture, @diagnostics.FrameworkError] {
  let (width, height, _) = match host.window_metrics(window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if width != 600.0 || height != 240.0 {
    return Err(
      mac_button_failure(
        "button_resize_burst", "host did not retain the final queued content size",
      ),
    )
  }
  mac_button_check_initial_pixels(host, window)
}

///|
fn mac_button_post_test_click(
  host : @macos.Host,
  window : @platform.WindowId,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match @primitives.Point::new(MAC_BUTTON_ACTION_X, MAC_BUTTON_ACTION_Y) {
    Err(_) =>
      Err(
        mac_button_failure(
          "button_test_click", "fixed in-bounds smoke coordinate was rejected",
        ),
      )
    Ok(point) => host.post_test_click(window, point)
  }
}

///|
fn mac_button_is_escape(kind : @platform.EventKind) -> Bool {
  match kind {
    @platform.Input(
      @primitives.KeyPressed(key=@primitives.Escape, repeat=false, ..)
    ) => true
    _ => false
  }
}

///|
/// Drain no more than the native adapter's fixed 64-request queue capacity.
/// Each transport token is resolved to the retained full ActionRequest and
/// dispatched before the next token is taken.
fn mac_button_consume_accessibility_requests(
  host : @macos.Host,
  window : @platform.WindowId,
  session : MacButtonSession,
) -> Result[(MacButtonSession, Bool), @diagnostics.FrameworkError] {
  let mut next_session = session
  let mut repaint = false
  let mut drained = false
  let mut consumed = 0
  while consumed < 64 && !drained {
    match host.take_button_accessibility_request(window) {
      Err(error) => return Err(error)
      Ok(None) => drained = true
      Ok(Some(token)) => {
        consumed += 1
        let (after_dispatch, accepted) = next_session.dispatch_accessibility_token(
          token,
        )
        next_session = after_dispatch
        if accepted {
          repaint = true
          next_session = match next_session.sync_accessibility(host, window) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
        }
      }
    }
  }
  Ok((next_session, repaint))
}

///|
fn run(
  host : @macos.Host,
  e2e : Bool,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if e2e && @env.get_env_var("GPUI_NATIVE_E2E") != Some("1") {
    return Err(
      mac_button_failure(
        "button_native_e2e", "set GPUI_NATIVE_E2E=1 to enable scoped native test hooks",
      ),
    )
  }
  let (initial_window, initial_session) = match
    mac_button_open_session(host, 1) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut window = initial_window
  let mut session = match initial_session.sync_accessibility(host, window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut done = false
  let mut ticks = 0
  let mut last_sequence : Int64 = 0
  let mut dirty = true
  let mut e2e_stage = if e2e { 0 } else { -1 }
  let mut e2e_resize_events = 0
  let mut initial_frame : @testing.FrameCapture? = None
  let mut last_error : @diagnostics.FrameworkError? = None

  while !done && (!e2e || ticks < 1500) {
    if e2e {
      ticks += 1
    }
    match host.next_event(timeout_ms=16) {
      Err(error) => {
        last_error = Some(error)
        done = true
      }
      Ok(None) => {
        session = match session.sync_accessibility(host, window) {
          Ok(value) => value
          Err(error) => {
            last_error = Some(error)
            done = true
            session
          }
        }
        if !done {
          match
            mac_button_consume_accessibility_requests(host, window, session) {
            Err(error) => {
              last_error = Some(error)
              done = true
            }
            Ok((next_session, repaint)) => {
              session = next_session
              dirty = dirty || repaint
            }
          }
        }
        if !e2e && !done && dirty && session.is_presentable() {
          let snapshot = match session.scene() {
            Ok(value) => value
            Err(error) =>
              return Err(mac_button_session_failure("button_scene", error))
          }
          match host.present(window, snapshot) {
            Err(error) => {
              last_error = Some(error)
              done = true
            }
            Ok(_) => {
              dirty = false
              println(
                "macOS Button: activations=\{session.demo().activations()} enabled=\{session.demo().button().is_enabled()} loading=\{session.demo().button().is_loading()} focused=\{session.demo().button().is_focused()} hovered=\{session.demo().button().is_hovered()} pressed=\{session.demo().button().is_pressed()}",
              )
            }
          }
        }
      }
      Ok(Some(event)) => {
        let event_window = event.window()
        let kind = event.kind()
        if event_window == window {
          if event.sequence() <= last_sequence {
            last_error = Some(
              mac_button_failure(
                "button_event_order", "native event sequence did not increase for this window",
              ),
            )
            done = true
          } else {
            last_sequence = event.sequence()
            if e2e && e2e_stage == 8 {
              match kind {
                @platform.Resized(..) => e2e_resize_events += 1
                _ => ()
              }
            }
            let (next_session, repaint) = match session.handle_event(event) {
              Ok(value) => value
              Err(error) => {
                last_error = Some(
                  mac_button_session_failure("button_event", error),
                )
                done = true
                (session, false)
              }
            }
            session = next_session
            dirty = dirty || repaint

            if mac_button_is_escape(kind) {
              match host.request_close(window) {
                Ok(_) => ()
                Err(error) => {
                  last_error = Some(error)
                  done = true
                }
              }
            } else {
              match kind {
                @platform.CloseRequested => {
                  session = match session.revoke_accessibility(host, window) {
                    Ok(value) => value
                    Err(error) => {
                      last_error = Some(error)
                      done = true
                      session
                    }
                  }
                  match host.destroy_window(window) {
                    Ok(_) =>
                      if e2e && e2e_stage == 3 {
                        e2e_stage = 4
                      } else if e2e && e2e_stage == 6 {
                        e2e_stage = 7
                      } else {
                        e2e_stage = -1
                      }
                    Err(error) => {
                      last_error = Some(error)
                      done = true
                    }
                  }
                  dirty = false
                }
                @platform.Destroyed =>
                  if e2e && e2e_stage == 4 {
                    match mac_button_open_session(host, 2) {
                      Ok((next_window, next_session)) => {
                        window = next_window
                        session = next_session
                        last_sequence = 0
                        dirty = true
                        e2e_stage = 5
                      }
                      Err(error) => {
                        last_error = Some(error)
                        done = true
                      }
                    }
                  } else if e2e && e2e_stage == 7 {
                    done = true
                  } else {
                    done = true
                  }
                @platform.ExitRequested => {
                  session = match session.revoke_accessibility(host, window) {
                    Ok(value) => value
                    Err(error) => {
                      last_error = Some(error)
                      done = true
                      session
                    }
                  }
                  match host.destroy_window(window) {
                    Ok(_) => done = false
                    Err(error) => {
                      last_error = Some(error)
                      done = true
                    }
                  }
                }
                _ => ()
              }
            }

            if !done && dirty {
              match host.window_metrics(window) {
                Err(error) => {
                  last_error = Some(error)
                  done = true
                }
                Ok((width, height, scale)) => {
                  let (next_session, repaint) = session.sync_metrics(
                    width, height, scale,
                  )
                  session = next_session
                  dirty = dirty || repaint
                }
              }
            }

            if !done {
              session = match session.sync_accessibility(host, window) {
                Ok(value) => value
                Err(error) => {
                  last_error = Some(error)
                  done = true
                  session
                }
              }
            }

            if !done {
              match
                mac_button_consume_accessibility_requests(host, window, session) {
                Err(error) => {
                  last_error = Some(error)
                  done = true
                }
                Ok((next_session, repaint)) => {
                  session = next_session
                  dirty = dirty || repaint
                }
              }
            }

            if !done && dirty && session.is_presentable() {
              let snapshot = match session.scene() {
                Ok(value) => value
                Err(error) =>
                  return Err(mac_button_session_failure("button_scene", error))
              }
              match host.present(window, snapshot) {
                Err(error) => {
                  last_error = Some(error)
                  done = true
                }
                Ok(_) => {
                  dirty = false
                  if e2e {
                    if e2e_stage == 0 {
                      match mac_button_check_initial_pixels(host, window) {
                        Err(error) => {
                          last_error = Some(error)
                          done = true
                        }
                        Ok(frame) => {
                          initial_frame = Some(frame)
                          e2e_stage = 8
                          match mac_button_queue_resize_burst(host, window) {
                            Ok(_) => ()
                            Err(error) => {
                              last_error = Some(error)
                              done = true
                            }
                          }
                        }
                      }
                    } else if e2e_stage == 8 && e2e_resize_events >= 2 {
                      match mac_button_check_resize_burst(host, window) {
                        Err(error) => {
                          last_error = Some(error)
                          done = true
                        }
                        Ok(frame) => {
                          initial_frame = Some(frame)
                          e2e_stage = 1
                          match mac_button_post_test_click(host, window) {
                            Ok(_) => ()
                            Err(error) => {
                              last_error = Some(error)
                              done = true
                            }
                          }
                        }
                      }
                    } else if e2e_stage == 1 &&
                      session.demo().button().is_pressed() &&
                      session.demo().button().is_focused() {
                      match mac_button_check_pressed_pixels(host, window) {
                        Ok(_) => e2e_stage = 2
                        Err(error) => {
                          last_error = Some(error)
                          done = true
                        }
                      }
                    } else if e2e_stage == 2 &&
                      session.demo().activations() == 1 &&
                      !session.demo().button().is_pressed() {
                      let before = match initial_frame {
                        Some(frame) => frame
                        None =>
                          return Err(
                            mac_button_failure(
                              "button_activation_pixels", "initial frame was not retained",
                            ),
                          )
                      }
                      match
                        mac_button_check_activation_pixels(host, window, before) {
                        Ok(_) =>
                          if e2e_stage == 2 {
                            e2e_stage = 3
                            match host.post_test_escape(window) {
                              Ok(_) => ()
                              Err(error) => {
                                last_error = Some(error)
                                done = true
                              }
                            }
                          }
                        Err(error) => {
                          last_error = Some(error)
                          done = true
                        }
                      }
                    } else if e2e_stage == 5 &&
                      session.demo().activations() == 0 &&
                      !session.demo().button().is_pressed() {
                      match mac_button_check_initial_pixels(host, window) {
                        Ok(_) => {
                          e2e_stage = 6
                          match host.post_test_escape(window) {
                            Ok(_) => ()
                            Err(error) => {
                              last_error = Some(error)
                              done = true
                            }
                          }
                        }
                        Err(error) => {
                          last_error = Some(error)
                          done = true
                        }
                      }
                    }
                  }
                  println(
                    "macOS Button: activations=\{session.demo().activations()} enabled=\{session.demo().button().is_enabled()} loading=\{session.demo().button().is_loading()} focused=\{session.demo().button().is_focused()} hovered=\{session.demo().button().is_hovered()} pressed=\{session.demo().button().is_pressed()}",
                  )
                }
              }
            } else if !session.is_presentable() {
              dirty = false
            }
          }
        } else if kind is @platform.ExitRequested {
          session = match session.revoke_accessibility(host, window) {
            Ok(value) => value
            Err(error) => {
              last_error = Some(error)
              done = true
              session
            }
          }
          match host.destroy_window(window) {
            Ok(_) => done = false
            Err(error) => {
              last_error = Some(error)
              done = true
            }
          }
        }
      }
    }
  }

  if !done && e2e {
    return Err(mac_button_e2e_failure(e2e_stage))
  }
  match last_error {
    Some(error) => Err(error)
    None if e2e && e2e_stage != 7 => Err(mac_button_e2e_failure(e2e_stage))
    None => Ok(())
  }
}

///|
fn main {
  let e2e = @env.args().contains("--e2e")
  match @macos.Host::start() {
    Err(error) => abort("macOS host startup: " + error.code().label())
    Ok(host) => {
      let result = run(host, e2e)
      let stopped = host.stop()
      match result {
        Err(error) =>
          println(
            "macOS Button failed: \{error.operation()}: \{error.code().label()}",
          )
        Ok(_) => if e2e { println("GPUI_MACOS_BUTTON_E2E PASS") }
      }
      match stopped {
        Err(error) =>
          abort(
            "macOS host cleanup: " +
            error.operation() +
            ": " +
            error.code().label(),
          )
        Ok(_) => ()
      }
      match result {
        Err(error) => abort("macOS Button: " + error.operation())
        Ok(_) => ()
      }
    }
  }
}
