///|
// The experimental Ubuntu-only path is deliberately separate from the default
// direct-keyboard example. All records share the native ordered ABI3 ingress.
fn run_ime_window() -> Unit {
  let host = required(@native.Host::start())
  let window = required(
    host.create_window(
      640, 240, "gpui.mbt experimental Japanese IME (v1 opt-in)",
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
  let mut owner : ImeOwner? = None
  let mut native_focused = false
  let mut dirty = true
  let mut external_edit = false
  let mut commits = 0
  let mut shown_commits = 0
  let mut presentation = 0
  let observe = field_state_enabled(@env.get_env_var("GPUI_FIELD_E2E_STATE"))
  while host.state() == @native.Running {
    let mut input : @primitives.InputEvent? = None
    match host.next_editor_event(timeout_ms=16) {
      Err(error) => {
        report(error)
        ignore(host.request_exit())
      }
      Ok(None) => ()
      Ok(Some(@native.Platform(event))) =>
        if event.window() == window {
          scale = event.scale()
          match event.kind() {
            @platform.Resized(width=w, height=h) => {
              width = w
              height = h
              match native_field_bounds(width, height) {
                Ok(bounds) =>
                  match field.with_bounds(bounds) {
                    Ok(value) => {
                      field = value
                      dirty = true
                    }
                    Err(_) => println("IME field bounds rejected.")
                  }
                Err(_) => ()
              }
            }
            @platform.ScaleChanged => dirty = true
            @platform.FocusChanged(focused) => {
              native_focused = focused
              if !focused {
                if owner is Some(active) {
                  ignore(
                    host.set_text_session_panel(window, active.epoch, false),
                  )
                  ignore(host.end_text_session(window, active.epoch))
                }
                owner = None
                match field.with_focus(false) {
                  Ok(value) => field = value
                  Err(_) => ignore(host.request_exit())
                }
                dirty = true
              }
            }
            @platform.CloseRequested | @platform.Destroyed =>
              ignore(host.request_exit())
            @platform.Input(event) =>
              match event {
                @primitives.KeyPressed(..)
                | @primitives.KeyReleased(..)
                | @primitives.TextInput(..) => ()
                _ => input = Some(event)
              }
            _ => ()
          }
        }
      Ok(Some(@native.TextSession(target, event))) =>
        match owner {
          Some(active) => {
            let lifecycle = event is @native.Entered || event is @native.Left
            if ime_target_current(active, window, target, lifecycle~) {
              if event is @native.Entered {
                owner = Some({
                  ..active,
                  entered: true,
                  seat: target.seat,
                  proxy_generation: target.proxy_generation,
                  sequence: target.sequence,
                })
                required(
                  host.set_text_session_panel(window, active.epoch, true),
                )
                dirty = true
              } else if event is @native.Left {
                owner = None
                native_focused = false
                match field.with_focus(false) {
                  Ok(value) => field = value
                  Err(_) => ignore(host.request_exit())
                }
                dirty = true
              } else {
                owner = Some({ ..active, sequence: target.sequence, })
                match event {
                  @native.Preedit(text~, cursor_utf16~, styles~, ..) =>
                    match ime_preedit(field, text, cursor_utf16, styles) {
                      Ok(value) => {
                        field = value
                        required(
                          host.set_text_session_panel(
                            window,
                            active.epoch,
                            text.length() != 0,
                          ),
                        )
                        dirty = true
                      }
                      Err(error) => {
                        println("GPUI_IME_REJECT preedit \{error.label()}")
                        field = field
                          .cancel_composition(measure, admit)
                          .unwrap()
                        external_edit = true
                        dirty = true
                      }
                    }
                  @native.Commit(text~, deletion~, position~) =>
                    match ime_commit(field, text, deletion, position) {
                      Ok(value) => {
                        field = value
                        commits += 1
                        required(
                          host.set_text_session_panel(
                            window,
                            active.epoch,
                            false,
                          ),
                        )
                        dirty = true
                      }
                      Err(error) => {
                        println("GPUI_IME_REJECT commit \{error.label()}")
                        field = field
                          .cancel_composition(measure, admit)
                          .unwrap()
                        external_edit = true
                        dirty = true
                      }
                    }
                  @native.ForwardedPressed(keysym~, key~, modifiers~) =>
                    match ime_command_key(keysym, key, modifiers) {
                      Some(key) =>
                        input = Some(
                          @primitives.KeyPressed(key~, modifiers~, repeat=false),
                        )
                      None => ()
                    }
                  @native.ForwardedReleased(keysym~, key~, modifiers~) =>
                    match ime_command_key(keysym, key, modifiers) {
                      Some(key) =>
                        input = Some(@primitives.KeyReleased(key~, modifiers~))
                      None => ()
                    }
                  _ => ()
                }
              }
            }
          }
          None => ()
        }
    }
    match input {
      Some(input) => {
        let previous = field
        // A command or click must explicitly cancel the original transaction
        // before changing its selection/document. Scroll only changes geometry.
        let resolve = input is @primitives.KeyPressed(..) ||
          input is @primitives.PointerButtonPressed(..)
        if resolve && field.is_composing() {
          field = field.cancel_composition(measure, admit).unwrap()
          external_edit = true
          dirty = true
        }
        let escape_cancel = resolve &&
          previous.is_composing() &&
          input is @primitives.KeyPressed(key=@primitives.Escape, ..)
        if !escape_cancel {
          if input
            is @primitives.PointerButtonPressed(
              position~,
              button=@primitives.Primary,
              ..
            ) &&
            !field.bounds().contains(position) {
            field = field.with_focus(false).unwrap()
          } else {
            match route_input(field, input, width, height) {
              Err(_) =>
                println(
                  "IME command/layout admission rejected; field retained.",
                )
              Ok((candidate, action)) => {
                field = candidate
                match action {
                  Some(@text_field.Copy(text)) =>
                    match host.write_clipboard(text) {
                      Ok(_) => ()
                      Err(error) => report(error)
                    }
                  Some(@text_field.Cut(text~, candidate~)) => {
                    let written = host.write_clipboard(text)
                    field = cut_after_write(field, candidate, written)
                    if written is Err(error) {
                      report(error)
                    }
                  }
                  Some(@text_field.Paste) => {
                    let revision = field.revision()
                    let epoch = match owner {
                      Some(value) => value.epoch
                      None => 0
                    }
                    match host.read_clipboard() {
                      Ok(text) => {
                        let current = match owner {
                          Some(value) => value.epoch
                          None => 0
                        }
                        if epoch > 0 &&
                          current == epoch &&
                          field.revision() == revision &&
                          field.is_focused() {
                          match field.replace_selection(text, measure, admit) {
                            Ok(value) => field = value
                            Err(_) => println("IME paste rejected as a whole.")
                          }
                        }
                      }
                      Err(error) => report(error)
                    }
                  }
                  Some(@text_field.Blur) =>
                    field = field.with_focus(false).unwrap()
                  Some(@text_field.Submit) =>
                    println("Field submitted; no persistence is configured.")
                  None => ()
                }
              }
            }
          }
        }
        if field.revision() != previous.revision() {
          dirty = true
          if field.committed_document() != previous.committed_document() ||
            resolve {
            external_edit = true
          }
        }
        if !field.is_focused() {
          if owner is Some(active) {
            required(host.set_text_session_panel(window, active.epoch, false))
            required(host.end_text_session(window, active.epoch))
          }
          owner = None
        }
      }
      None => ()
    }
    // Fence external edits before consuming another native record, including
    // while a renderer frame is Busy. Rejection restores and fences again.
    if external_edit && field.is_focused() && native_focused {
      if owner is Some(active) {
        match ime_sync(host, window, field, Some(active), true) {
          Ok(value) => owner = Some(value)
          Err(error) => {
            report(error)
            ignore(host.request_exit())
          }
        }
        external_edit = false
      }
    }
    if dirty && host.state() == @native.Running {
      match field_scene(field, width, height, scale) {
        Err(_) => {
          println("IME scene admission failed.")
          ignore(host.request_exit())
        }
        Ok(scene) => {
          let presented = host.present(window, scene)
          match classify_field_frame(presented) {
            Accepted => {
              // Only accepted owner state is sent as surrounding text. A preview
              // contributes caret geometry, never provisional document bytes.
              if field.is_focused() && native_focused {
                match ime_sync(host, window, field, owner, external_edit) {
                  Ok(value) => owner = Some(value)
                  Err(error) => {
                    report(error)
                    ignore(host.request_exit())
                  }
                }
              }
              external_edit = false
              shown = field
              shown_commits = commits
              if observe {
                presentation += 1
                println(ime_observer_line(presentation, shown, owner, commits))
                field_state_flush_stdout()
              }
              dirty = false
            }
            BusyPending => ()
            RecoverPending =>
              match host.recover_renderer(window) {
                Ok(_) => ()
                Err(error) => {
                  report(error)
                  ignore(host.request_exit())
                }
              }
            RejectPending => {
              if presented is Err(error) {
                report(error)
              }
              match restore_rejected_ime_field(shown, field) {
                Ok(value) => {
                  field = value
                  commits = shown_commits
                  if owner is Some(active) {
                    match ime_sync(host, window, field, Some(active), true) {
                      Ok(value) => owner = Some(value)
                      Err(error) => {
                        report(error)
                        ignore(host.request_exit())
                      }
                    }
                  }
                  external_edit = false
                  dirty = true
                }
                Err(_) => ignore(host.request_exit())
              }
            }
          }
        }
      }
    }
  }
  if owner is Some(active) {
    ignore(host.set_text_session_panel(window, active.epoch, false))
    ignore(host.end_text_session(window, active.epoch))
  }
  ignore(host.destroy_window(window))
  required(host.stop())
}
