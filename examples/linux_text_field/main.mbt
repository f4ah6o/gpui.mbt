///|
fn[T] required(value : Result[T, @diagnostics.FrameworkError]) -> T {
  match value {
    Ok(value) => value
    Err(error) => abort("\{error.operation()}: \{error.code().label()}")
  }
}

///|
fn report(error : @diagnostics.FrameworkError) -> Unit {
  println("\{error.operation()}: \{error.code().label()}")
}

///|
fn route_input(
  field : @text_field.TextField,
  event : @primitives.InputEvent,
  width : Double,
  height : Double,
) -> Result[
  (@text_field.TextField, @text_field.TextFieldAction?),
  @text_field.TextFieldError,
] {
  let tree = field_tree(field, width, height)
  let delivered : Ref[
    Result[
      (@text_field.TextField, @text_field.TextFieldAction?),
      @text_field.TextFieldError,
    ]?,
  ] = Ref(None)
  ignore(
    tree.dispatch_input_with(event, (context, event) => {
      if context.phase() == @element.Bubble &&
        context.current_target() == field.id() {
        delivered.val = Some(field.handle_input(event, measure, admit, hit))
      }
      Ok(())
    }),
  )
  match delivered.val {
    Some(value) => value
    None => Ok((field, None))
  }
}

///|
fn native_field_bounds(
  width : Double,
  height : Double,
) -> Result[@primitives.Rect, @text_field.TextFieldError] {
  let field_width = if width > 560.0 { 512.0 } else { width - 48.0 }
  if field_width < 16.0 || height < 88.0 {
    return Err(@text_field.InvalidBounds)
  }
  match @primitives.Rect::new(24.0, 28.0, field_width, 44.0) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.InvalidBounds)
  }
}

///|
fn run_window() -> Unit {
  let host = required(@native.Host::start())
  let window = required(
    host.create_window(
      640, 240, "gpui.mbt experimental field: direct XKB, IME unavailable",
    ),
  )
  required(host.require_capability(@platform.GrayscaleTextFrames))
  let mut width = 640.0
  let mut height = 240.0
  let mut scale = 1.0
  let mut field = make_field(
    "Hello 日本",
    native_field_bounds(width, height).unwrap(),
  ).unwrap()
  let mut shown = field
  let mut dirty = true
  let smoke = @env.get_env_var("GPUI_FIELD_SMOKE") == Some("1")
  if host.require_capability(@platform.DirectKeyboardText) is Err(_) {
    println(
      "Direct keyboard input is unavailable in this session; IME is unimplemented.",
    )
  }
  while host.state() == @native.Running {
    match host.next_event(timeout_ms=16) {
      Err(error) => {
        report(error)
        ignore(host.request_exit())
      }
      Ok(Some(event)) => {
        scale = event.scale()
        match event.kind() {
          @platform.Resized(width=w, height=h) => {
            width = w
            height = h
            match native_field_bounds(width, height) {
              Ok(bounds) =>
                match field.with_bounds(bounds) {
                  Ok(value) => field = value
                  Err(_) => println("Field bounds rejected; document retained.")
                }
              Err(_) => ()
            }
            dirty = true
          }
          @platform.ScaleChanged => dirty = true
          @platform.FocusChanged(false) => {
            ignore(host.set_direct_keyboard_text(window, false))
            match field.with_focus(false) {
              Ok(value) => field = value
              Err(_) => ()
            }
            dirty = true
          }
          @platform.CloseRequested => ignore(host.request_exit())
          @platform.FrameCompleted => if smoke { ignore(host.request_exit()) }
          @platform.Input(input) => {
            let mut allowed = true
            match input {
              @primitives.PointerButtonPressed(
                position~,
                button=@primitives.Primary,
                ..
              ) =>
                if !field.bounds().contains(position) {
                  ignore(host.set_direct_keyboard_text(window, false))
                  match field.with_focus(false) {
                    Ok(value) => {
                      field = value
                      dirty = true
                    }
                    Err(_) => ()
                  }
                }
              @primitives.KeyPressed(..)
              | @primitives.KeyReleased(..)
              | @primitives.TextInput(..) =>
                if field.is_focused() &&
                  host.direct_keyboard_text_epoch(window) is Err(_) {
                  allowed = false
                  ignore(host.set_direct_keyboard_text(window, false))
                  match field.with_focus(false) {
                    Ok(value) => {
                      field = value
                      dirty = true
                    }
                    Err(_) => ()
                  }
                }
              _ => ()
            }
            if allowed {
              let previous = field
              match route_input(field, input, width, height) {
                Err(_) =>
                  println(
                    "Field input/layout/grayscale admission rejected; document retained.",
                  )
                Ok((candidate, action)) => {
                  let focus_changed = candidate.is_focused() !=
                    previous.is_focused()
                  let armed = if focus_changed {
                    match
                      host.set_direct_keyboard_text(
                        window,
                        candidate.is_focused(),
                      ) {
                      Ok(_) => true
                      Err(error) => {
                        report(error)
                        false
                      }
                    }
                  } else {
                    true
                  }
                  if armed {
                    field = candidate
                    match action {
                      Some(@text_field.Copy(text)) =>
                        match host.write_clipboard(text) {
                          Ok(_) => ()
                          Err(error) => report(error)
                        }
                      Some(@text_field.Cut(text~, candidate~)) => {
                        let write = host.write_clipboard(text)
                        field = cut_after_write(field, candidate, write)
                        if write is Err(error) {
                          report(error)
                        }
                      }
                      Some(@text_field.Paste) => {
                        let revision = field.revision()
                        let epoch = host.direct_keyboard_text_epoch(window)
                        match host.read_clipboard() {
                          Err(error) => report(error)
                          Ok(text) =>
                            match
                              paste_if_current(
                                field,
                                revision,
                                epoch,
                                host.direct_keyboard_text_epoch(window),
                                text,
                              ) {
                              Ok(value) => field = value
                              Err(_) =>
                                println(
                                  "Paste rejected as a whole; document retained.",
                                )
                            }
                        }
                      }
                      Some(@text_field.Submit) =>
                        println(
                          "Field submitted; no persistence is configured.",
                        )
                      Some(@text_field.Blur) =>
                        match
                          apply_owner_blur(
                            field,
                            host.set_direct_keyboard_text(window, false),
                          ) {
                          Ok(value) => field = value
                          Err(Native(error)) => {
                            report(error)
                            ignore(host.request_exit())
                          }
                          Err(Field(error)) => {
                            if error is @text_field.RevisionExhausted {
                              println(
                                "Field revision exhausted; restart required.",
                              )
                            }
                            ignore(host.request_exit())
                          }
                        }
                      None => ()
                    }
                    if field.revision() != previous.revision() {
                      dirty = true
                    }
                  }
                }
              }
            }
          }
          _ => ()
        }
      }
      Ok(None) => ()
    }
    if dirty && host.state() == @native.Running {
      match field_scene(field, width, height, scale) {
        Err(_) => {
          println("Field scene failed; prior displayed frame retained.")
          ignore(host.set_direct_keyboard_text(window, false))
          dirty = false
          ignore(host.request_exit())
        }
        Ok(scene) => {
          let presented = host.present(window, scene)
          match classify_field_frame(presented) {
            Accepted => {
              shown = field
              dirty = false
            }
            BusyPending => () // Later edits build on the admitted candidate.
            RecoverPending => {
              if presented is Err(error) {
                report(error)
              }
              match host.recover_renderer(window) {
                Ok(_) => ()
                Err(error) => {
                  report(error)
                  ignore(host.request_exit())
                }
              }
            }
            RejectPending => {
              if presented is Err(error) {
                report(error)
              }
              // Native preflight rejection does not install the pending edit.
              // Re-arm advances epoch so queued edits/paste guards cannot be
              // replayed against the restored document/revision.
              let focused = field.is_focused()
              match restore_submitted_field(shown, field) {
                Ok(value) => {
                  field = value
                  match host.set_direct_keyboard_text(window, focused) {
                    Ok(_) => ()
                    Err(_) =>
                      match field.with_focus(false) {
                        Ok(value) => field = value
                        Err(_) => ignore(host.request_exit())
                      }
                  }
                }
                Err(_) => {
                  ignore(host.set_direct_keyboard_text(window, false))
                  ignore(host.request_exit())
                }
              }
              dirty = false
            }
          }
        }
      }
    }
  }
  ignore(host.destroy_window(window))
  required(host.stop())
}

///|
fn main {
  if @env.get_env_var("GPUI_FIELD_FIXTURES") == Some("1") {
    emit_fixtures()
  } else {
    run_window()
  }
}
