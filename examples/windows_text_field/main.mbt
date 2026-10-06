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
fn windows_caret_rect(
  field : @text_field.TextField,
) -> Result[@primitives.Rect, @diagnostics.FrameworkError] {
  let caret = match field.caret_rect() {
    Ok(value) => value
    Err(_) =>
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "field_caret_rect",
        ),
      )
  }
  let left = caret.left().floor()
  let top = caret.top().floor()
  let right = caret.right().ceil()
  let bottom = caret.bottom().ceil()
  for value in [left, top, right, bottom] {
    if value.is_nan() ||
      value.is_inf() ||
      value < -2147483648.0 ||
      value > 2147483647.0 {
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "field_caret_rect",
        ),
      )
    }
  }
  let width = right - left
  let height = bottom - top
  if width < 1.0 ||
    height < 1.0 ||
    width > 2147483647.0 ||
    height > 2147483647.0 {
    return Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.InvalidInput,
        "field_caret_rect",
      ),
    )
  }
  match @primitives.Rect::new(left, top, width, height) {
    Ok(value) => Ok(value)
    Err(_) =>
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "field_caret_rect",
        ),
      )
  }
}

///|
fn sync_windows_text_session(
  host : @native.Host,
  window : @platform.WindowId,
  owner_generation : Int,
  field : @text_field.TextField,
  owner : WindowsTextOwner?,
  experimental_ime : Bool,
  native_focused : Bool,
  external_edit : Bool,
) -> Result[WindowsTextOwner?, @diagnostics.FrameworkError] {
  if !windows_text_session_requested(
      experimental_ime,
      field.is_focused(),
      native_focused,
    ) {
    return Ok(owner)
  }
  match host.window_has_keyboard_focus(window) {
    Err(error) => return Err(error)
    Ok(false) => return Ok(owner)
    Ok(true) => ()
  }
  let caret = match windows_caret_rect(field) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match owner {
    None =>
      match
        host.begin_text_session(
          window,
          owner_generation,
          field.committed_document(),
          caret,
        ) {
        Ok(epoch) => Ok(Some(windows_text_owner(owner_generation, epoch)))
        Err(error) => Err(error)
      }
    Some(active) =>
      match
        host.update_text_session(
          window,
          active.epoch,
          owner_generation,
          field.committed_document(),
          caret,
          external_edit~,
        ) {
        Ok(epoch) => Ok(Some(windows_text_owner_after_update(active, epoch)))
        Err(error) => Err(error)
      }
  }
}

///|
fn windows_disarm_session(
  host : @native.Host,
  window : @platform.WindowId,
  owner : WindowsTextOwner?,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match owner {
    None => Ok(())
    Some(active) =>
      host.end_text_session(window, active.epoch, active.owner_generation)
  }
}

///|
fn windows_disarm_if_running(
  host : @native.Host,
  window : @platform.WindowId,
  owner : WindowsTextOwner?,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if host.state() == @native.Running {
    windows_disarm_session(host, window, owner)
  } else {
    // Native teardown owns any remaining IMM association after the host stops.
    Ok(())
  }
}

///|
fn windows_request_exit(
  host : @native.Host,
  window : @platform.WindowId,
  owner : WindowsTextOwner?,
) -> Unit {
  match windows_disarm_if_running(host, window, owner) {
    Ok(_) => ()
    Err(error) => report(error)
  }
  ignore(host.request_exit())
}

///|
fn windows_reject_session_edit(
  host : @native.Host,
  window : @platform.WindowId,
  owner : WindowsTextOwner,
  field : @text_field.TextField,
) -> Result[
  (@text_field.TextField, WindowsTextOwner),
  @diagnostics.FrameworkError,
] {
  let (restored, cleared) = windows_cancel_composition(owner).unwrap()
  let mut value = field
  match restored {
    Some(original) =>
      match original.with_bounds(field.bounds()) {
        Ok(bounded) =>
          match bounded.with_focus(field.is_focused()) {
            Ok(focused) => value = focused
            Err(_) =>
              return Err(
                @diagnostics.FrameworkError::new(
                  @diagnostics.InvalidInput,
                  "restore_text_session",
                ),
              )
          }
        Err(_) =>
          return Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "restore_text_session",
            ),
          )
      }
    None => ()
  }
  match host.cancel_text_session(window, owner.epoch, owner.owner_generation) {
    Ok(epoch) => Ok((value, windows_text_owner_after_update(cleared, epoch)))
    Err(error) => Err(error)
  }
}

///|
fn windows_state_line(
  frame : Int,
  field : @text_field.TextField,
  owner : WindowsTextOwner?,
) -> String {
  let selection = field.selection()
  let marked = match field.marked_range() {
    Some(range) => "{\"start\":\{range.start()},\"end\":\{range.end()}}"
    None => "null"
  }
  let epoch = match owner {
    Some(value) => value.epoch
    None => 0
  }
  let caret = match windows_caret_rect(field) {
    Ok(value) =>
      "{\"x\":\{value.left()},\"y\":\{value.top()},\"width\":\{value.size().width()},\"height\":\{value.size().height()}}"
    Err(_) => "null"
  }
  let committed = @json.to_json(field.committed_document().text()).stringify()
  let preview = @json.to_json(field.document().text()).stringify()
  "GPUI_WINDOWS_FIELD_STATE {\"frame\":\{frame},\"committed\":\{committed},\"preview\":\{preview},\"selection\":{\"anchor\":\{selection.anchor()},\"head\":\{selection.head()}},\"marked\":\{marked},\"focused\":\{field.is_focused()},\"revision\":\{field.revision()},\"epoch\":\{epoch},\"can_undo\":\{field.can_undo()},\"can_redo\":\{field.can_redo()},\"caret\":\{caret}}"
}

///|
fn run_window() -> Unit {
  let host = required(@native.Host::start())
  let window = required(
    host.create_window(720, 180, "gpui.mbt — Windows single-line field"),
  )
  let mut width = 720.0
  let mut height = 180.0
  let mut scale = 1.0
  let mut field = make_field(
      "Click and type here",
      native_field_bounds(width, height).unwrap(),
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let mut shown = field
  let mut owner : WindowsTextOwner? = None
  let owner_generation = 2
  let experimental_ime = @env.get_env_var("GPUI_WINDOWS_FIELD_IME") == Some("1")
  let smoke = @env.get_env_var("GPUI_WINDOWS_FIELD_SMOKE") == Some("1")
  let observe = @env.get_env_var("GPUI_WINDOWS_FIELD_STATE") == Some("1")
  let mut native_focused = match host.window_has_keyboard_focus(window) {
    Ok(value) => value
    Err(error) => {
      report(error)
      false
    }
  }
  let mut dirty = true
  let mut has_accepted_frame = false
  let mut frame_completions = 0
  let mut presentation = 0

  if !experimental_ime {
    println(
      "IMM32 text sessions are off; committed WM_CHAR input remains enabled.",
    )
  } else {
    println(
      "Experimental private IMM32 session enabled (not a Japanese IME qualification).",
    )
  }

  while host.state() == @native.Running {
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
                    Err(_) => println("Resize rejected; field value retained.")
                  }
                Err(_) => ()
              }
            }
            @platform.ScaleChanged => dirty = true
            @platform.FocusChanged(focused) => {
              native_focused = focused
              if !focused {
                match
                  windows_restore_owner_snapshot(owner, field, measure, admit) {
                  Ok(value) => field = value
                  Err(_) => ignore(host.request_exit())
                }
                if windows_disarm_if_running(host, window, owner) is Err(error) {
                  report(error)
                }
                owner = None
                match field.with_focus(false) {
                  Ok(value) => field = value
                  Err(_) => ignore(host.request_exit())
                }
                dirty = true
              }
            }
            @platform.CloseRequested | @platform.ExitRequested => {
              windows_request_exit(host, window, owner)
              owner = None
            }
            @platform.Destroyed => {
              owner = None
              ignore(host.request_exit())
            }
            @platform.FrameCompleted => {
              frame_completions += 1
              if smoke && has_accepted_frame {
                println("GPUI_WINDOWS_FIELD_SMOKE accepted FrameCompleted")
                windows_request_exit(host, window, owner)
                owner = None
              }
            }
            @platform.Input(input) => {
              let previous = field
              let composition_active = match owner {
                Some(active) => active.composition is Some(_)
                None => false
              }
              let escape_cancel = composition_active &&
                (match input {
                  @primitives.KeyPressed(key=@primitives.Escape, ..) => true
                  _ => false
                })
              let resolves_preedit = windows_resolves_preedit(
                composition_active, input,
              )
              if resolves_preedit && composition_active && owner is Some(active) {
                match windows_reject_session_edit(host, window, active, field) {
                  Ok((restored, next_owner)) => {
                    field = restored
                    owner = Some(next_owner)
                    dirty = true
                  }
                  Err(error) => {
                    report(error)
                    ignore(host.request_exit())
                  }
                }
              }
              let native_owns_key = composition_active &&
                !resolves_preedit &&
                input is @primitives.KeyPressed(..)
              let outside_click = if escape_cancel || native_owns_key {
                false
              } else {
                match input {
                  @primitives.PointerButtonPressed(
                    position~,
                    button=@primitives.Primary,
                    ..
                  ) => !field.bounds().contains(position)
                  _ => false
                }
              }
              if escape_cancel || native_owns_key {
                if escape_cancel {
                  dirty = true
                }
              } else if outside_click {
                match windows_disarm_if_running(host, window, owner) {
                  Err(error) => report(error)
                  Ok(_) => ()
                }
                owner = None
                match field.with_focus(false) {
                  Ok(value) => field = value
                  Err(_) => ignore(host.request_exit())
                }
                dirty = true
              } else {
                // Clipboard rollback must start from the field after any
                // preedit was resolved above. `previous` may still contain
                // a preview whose native epoch has already been cancelled.
                let action_base = field
                match route_input(field, input, width, height) {
                  Err(_) =>
                    println("Field input rejected; shown value retained.")
                  Ok((candidate, action)) => {
                    field = candidate
                    match action {
                      Some(@text_field.Copy(text)) => {
                        let focus_before = host.window_has_keyboard_focus(
                          window,
                        )
                        match focus_before {
                          Ok(true) =>
                            match host.write_clipboard(text) {
                              Ok(_) => ()
                              Err(error) => report(error)
                            }
                          Ok(false) => ()
                          Err(error) => report(error)
                        }
                      }
                      Some(@text_field.Cut(text~, candidate~)) => {
                        let revision_before = action_base.revision()
                        let epoch_before = match owner {
                          Some(value) => Some(value.epoch)
                          None => None
                        }
                        let focus_before = match
                          host.window_has_keyboard_focus(window) {
                          Ok(value) => value
                          Err(error) => {
                            report(error)
                            false
                          }
                        }
                        let written = if focus_before {
                          host.write_clipboard(text)
                        } else {
                          Err(
                            @diagnostics.FrameworkError::new(
                              @diagnostics.InvalidInput,
                              "cut_focus_changed",
                            ),
                          )
                        }
                        let focus_after = match
                          host.window_has_keyboard_focus(window) {
                          Ok(value) => value
                          Err(error) => {
                            report(error)
                            false
                          }
                        }
                        let epoch_after = match owner {
                          Some(value) => Some(value.epoch)
                          None => None
                        }
                        field = cut_after_write(
                          action_base, candidate, epoch_before, epoch_after, focus_before,
                          focus_after, written,
                        )
                        if written is Err(error) {
                          report(error)
                        }
                        if field.revision() != revision_before {
                          dirty = true
                        }
                      }
                      Some(@text_field.Paste) => {
                        let revision = field.revision()
                        let epoch_before = match owner {
                          Some(value) => Some(value.epoch)
                          None => None
                        }
                        let focus_before = match
                          host.window_has_keyboard_focus(window) {
                          Ok(value) => value
                          Err(error) => {
                            report(error)
                            false
                          }
                        }
                        match host.read_clipboard() {
                          Err(error) => report(error)
                          Ok(text) => {
                            let focus_after = match
                              host.window_has_keyboard_focus(window) {
                              Ok(value) => value
                              Err(error) => {
                                report(error)
                                false
                              }
                            }
                            let epoch_after = match owner {
                              Some(value) => Some(value.epoch)
                              None => None
                            }
                            match
                              paste_if_current(
                                field, revision, epoch_before, epoch_after, focus_before,
                                focus_after, text, measure, admit,
                              ) {
                              Ok(value) => {
                                field = value
                                if field.revision() != revision {
                                  dirty = true
                                }
                              }
                              Err(_) => println("Paste rejected atomically.")
                            }
                          }
                        }
                      }
                      Some(@text_field.Submit) =>
                        println(
                          "Field submitted; no persistence is configured.",
                        )
                      Some(@text_field.Blur) => {
                        match
                          windows_restore_owner_snapshot(
                            owner, field, measure, admit,
                          ) {
                          Ok(value) => field = value
                          Err(_) => ignore(host.request_exit())
                        }
                        if windows_disarm_if_running(host, window, owner)
                          is Err(error) {
                          report(error)
                        }
                        owner = None
                        field = field.with_focus(false).unwrap()
                        dirty = true
                      }
                      None => ()
                    }
                    if field.revision() != previous.revision() ||
                      field.is_focused() != previous.is_focused() {
                      dirty = true
                    }
                  }
                }
              }
              let editing_input = input is @primitives.TextInput(..) ||
                input is @primitives.PointerButtonPressed(..) ||
                input is @primitives.KeyPressed(..)
              if editing_input && field.revision() != previous.revision() {
                match
                  sync_windows_text_session(
                    host, window, owner_generation, field, owner, experimental_ime,
                    native_focused, true,
                  ) {
                  Ok(value) => owner = value
                  Err(error) => {
                    report(error)
                    ignore(host.request_exit())
                  }
                }
              }
            }
            _ => ()
          }
        }
      Ok(Some(@native.TextSession(target, event))) =>
        match owner {
          Some(active) if experimental_ime &&
            windows_session_target_current(active, window, target) => {
            let accepted = windows_text_owner_accept_event(active, target)
            match event {
              @native.CompositionStarted(replacement_range~) =>
                match
                  windows_start_composition(accepted, field, replacement_range) {
                  Some(value) => owner = Some(value)
                  None =>
                    match
                      windows_reject_session_edit(host, window, accepted, field) {
                      Ok((restored, value)) => {
                        field = restored
                        owner = Some(value)
                        dirty = true
                      }
                      Err(error) => {
                        report(error)
                        ignore(host.request_exit())
                      }
                    }
                }
              @native.Marked(
                text~,
                cursor_utf16~,
                attributes~,
                replacement_range~
              ) =>
                match
                  windows_update_mark(
                    accepted, text, cursor_utf16, attributes, replacement_range,
                    measure, admit,
                  ) {
                  Ok((value, next_owner)) => {
                    field = value
                    owner = Some(next_owner)
                    dirty = true
                  }
                  Err(_) =>
                    match
                      windows_reject_session_edit(host, window, accepted, field) {
                      Ok((restored, value)) => {
                        field = restored
                        owner = Some(value)
                        dirty = true
                        println(
                          "IMM32 preedit rejected by the bounded field profile.",
                        )
                      }
                      Err(error) => {
                        report(error)
                        ignore(host.request_exit())
                      }
                    }
                }
              @native.Inserted(text~, replacement_range~) =>
                match
                  windows_append_result(
                    accepted, field, text, replacement_range, measure, admit,
                  ) {
                  Ok((next_owner, value)) => {
                    field = value
                    owner = Some(next_owner)
                    dirty = true
                  }
                  Err(_) =>
                    match
                      windows_reject_session_edit(host, window, accepted, field) {
                      Ok((restored, value)) => {
                        field = restored
                        owner = Some(value)
                        dirty = true
                        println(
                          "IMM32 result rejected; the last admitted field is retained.",
                        )
                      }
                      Err(error) => {
                        report(error)
                        ignore(host.request_exit())
                      }
                    }
                }
              @native.CompositionEnded =>
                match windows_end_composition(accepted) {
                  Ok((Some(value), next_owner)) => {
                    field = value
                    owner = Some(next_owner)
                    dirty = true
                  }
                  Ok((None, next_owner)) => owner = Some(next_owner)
                  Err(_) => ()
                }
              @native.Cancelled =>
                match windows_cancel_composition(accepted) {
                  Ok((Some(value), next_owner)) => {
                    field = value
                    owner = Some(next_owner)
                    dirty = true
                  }
                  Ok((None, next_owner)) => owner = Some(next_owner)
                  Err(_) => ()
                }
            }
          }
          _ => ()
        }
    }

    if dirty && host.state() == @native.Running {
      match field_scene(field, width, height, scale) {
        Err(_) => {
          println(
            "Text layout or scene rejected; the last presented frame remains visible.",
          )
          ignore(host.request_exit())
        }
        Ok(scene) => {
          let presented = host.present(window, scene)
          match classify_field_frame(presented) {
            Accepted => {
              shown = field
              has_accepted_frame = true
              if experimental_ime && native_focused && field.is_focused() {
                match
                  sync_windows_text_session(
                    host, window, owner_generation, field, owner, experimental_ime,
                    native_focused, false,
                  ) {
                  Ok(value) => owner = value
                  Err(error) => {
                    report(error)
                    ignore(host.request_exit())
                  }
                }
              }
              if observe {
                presentation += 1
                println(windows_state_line(presentation, shown, owner))
              }
              dirty = false
            }
            BusyPending => ()
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
              let focused = field.is_focused()
              let mut restored = match restore_submitted_field(shown, field) {
                Ok(value) => value
                Err(_) => {
                  ignore(host.request_exit())
                  shown
                }
              }
              // Restore the exact last submitted TextField/history first.
              // Never substitute the native transaction's newer original:
              // a committed result may have been processed locally while its
              // frame was still pending. If the submitted snapshot itself
              // contained preedit, cancel only that snapshot's composition.
              if restored.is_composing() {
                match restored.cancel_composition(measure, admit) {
                  Ok(value) => restored = value
                  Err(_) => {
                    ignore(host.request_exit())
                    restored = shown
                  }
                }
              }
              field = restored
              match owner {
                Some(active) => owner = Some({ ..active, composition: None, })
                None => ()
              }
              if experimental_ime && native_focused && focused {
                match
                  sync_windows_text_session(
                    host, window, owner_generation, field, owner, experimental_ime,
                    native_focused, true,
                  ) {
                  Ok(value) => owner = value
                  Err(error) => {
                    report(error)
                    ignore(host.request_exit())
                  }
                }
              }
              dirty = field.revision() != shown.revision()
            }
          }
        }
      }
    }
  }

  if windows_disarm_if_running(host, window, owner) is Err(error) {
    report(error)
  }
  ignore(host.destroy_window(window))
  required(host.stop())
  if smoke && frame_completions == 0 {
    abort("Windows field smoke exited without FrameCompleted")
  }
}

///|
fn main {
  run_window()
}
