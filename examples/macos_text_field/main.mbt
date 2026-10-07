///|
fn[T] required(value : Result[T, @diagnostics.FrameworkError]) -> T {
  match value {
    Ok(result) => result
    Err(error) => abort("\{error.operation()}: \{error.code().label()}")
  }
}

///|
fn report(error : @diagnostics.FrameworkError) -> Unit {
  println("\{error.operation()}: \{error.code().label()}")
}

///|
fn mac_owner_sync_should_defer(
  error : @diagnostics.FrameworkError,
  has_pending_ack : Bool,
) -> Bool {
  !has_pending_ack && error.code() is @diagnostics.Busy
}

///|
fn mac_paste_session_current(
  host : @macos.Host,
  owner : MacTextOwner?,
  epoch_before : Int?,
) -> Bool {
  match (epoch_before, owner) {
    (Some(before), Some(value)) => {
      let generation_current = match host.generation() {
        Ok(generation) => generation == value.host_epoch
        Err(_) => false
      }
      value.active && value.epoch == before && generation_current
    }
    (None, _) => true
    _ => false
  }
}

///|
fn mac_apply_action(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  action : @text_field.TextFieldAction?,
  owner : MacTextOwner?,
  ime_mode : Bool,
) -> (@text_field.TextField, Bool, Bool) {
  match action {
    None => (field, false, false)
    Some(@text_field.Copy(text)) => {
      match host.write_clipboard(text) {
        Ok(_) => ()
        Err(error) => report(error)
      }
      (field, false, false)
    }
    Some(@text_field.Cut(text~, candidate~)) =>
      match host.write_clipboard(text) {
        Ok(_) => (candidate, candidate.revision() != field.revision(), false)
        Err(error) => {
          report(error)
          (field, false, false)
        }
      }
    Some(@text_field.Paste) => {
      let revision = field.revision()
      let session_epoch_before = match owner {
        Some(value) if ime_mode && value.active => Some(value.epoch)
        _ => None
      }
      let direct_epoch_before = if ime_mode {
        None
      } else {
        match host.direct_keyboard_text_epoch(window) {
          Ok(value) => Some(value)
          Err(error) => {
            report(error)
            None
          }
        }
      }
      match host.read_clipboard() {
        Err(error) => {
          report(error)
          (field, false, false)
        }
        Ok(text) => {
          let session_still_current = mac_paste_session_current(
            host, owner, session_epoch_before,
          )
          let direct_still_current = if ime_mode {
            true
          } else {
            match
              (direct_epoch_before, host.direct_keyboard_text_epoch(window)) {
              (Some(before), Ok(after)) => before == after
              _ => false
            }
          }
          if field.revision() != revision ||
            !field.is_focused() ||
            !session_still_current ||
            !direct_still_current {
            println("Paste rejected because the owner snapshot changed.")
            (field, false, false)
          } else {
            match field.replace_selection(text, measure, admit) {
              Ok(candidate) =>
                (candidate, candidate.revision() != field.revision(), false)
              Err(_) => {
                println("Paste rejected by the field admission checks.")
                (field, false, false)
              }
            }
          }
        }
      }
    }
    Some(@text_field.Submit) => {
      println("Field submitted; no persistence is configured.")
      (field, false, false)
    }
    Some(@text_field.Blur) => (field, false, true)
  }
}

///|
fn begin_macos_field_session(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
) -> Result[MacTextOwner, @diagnostics.FrameworkError] {
  mac_begin_owner(host, window, field)
}

///|
fn sync_macos_field_session(
  host : @macos.Host,
  field : @text_field.TextField,
  owner : MacTextOwner,
  external_edit : Bool,
  acknowledged_sequence : Int64?,
) -> Result[MacTextOwner, @diagnostics.FrameworkError] {
  mac_sync_owner(host, field, owner, external_edit, acknowledged_sequence)
}

///|
fn sync_macos_direct_text(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let epoch = match host.direct_keyboard_text_epoch(window) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let caret = match mac_caret_rect(field) {
    Ok(value) => value
    Err(_) =>
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "mac_direct_caret_rect",
        ),
      )
  }
  host.update_direct_keyboard_text(
    window,
    epoch,
    field.committed_document(),
    caret,
  )
}

///|
fn mac_acceptance_window_is_key(
  host : @macos.Host,
  window : @platform.WindowId,
) -> Bool {
  match host.testing_text_window_state(window) {
    Ok(value) =>
      mac_acceptance_bool_field(value, "window_key") == Some(true) &&
      mac_acceptance_bool_field(value, "app_key_matches") == Some(true) &&
      mac_acceptance_bool_field(value, "first_responder_is_content_view") ==
      Some(true)
    Err(_) => false
  }
}

///|
fn run_window() -> Unit {
  match @macos_text.require_grayscale_raster() {
    Ok(_) => ()
    Err(_) =>
      abort("macOS text field requires monochrome CoreText raster support")
  }
  let host = required(@macos.Host::start())
  let window = required(
    host.create_window("gpui.mbt experimental macOS TextField", 640.0, 240.0),
  )
  required(host.require_capability(@platform.GrayscaleTextFrames))
  let (initial_width, initial_height, initial_scale) = required(
    host.window_metrics(window),
  )
  let bounds = native_field_bounds(initial_width, initial_height).unwrap()
  let ime_acceptance = @env.args().contains("--ime-acceptance")
  let mut field = make_field("Hello ", bounds).unwrap()
  if ime_acceptance || @env.get_env_var("GPUI_FIELD_MACOS_IME") == Some("1") {
    field = field.with_focus(true).unwrap()
  }
  match validate_mac_document(field.document()) {
    Ok(_) => ()
    Err(_) => abort("initial field text is unsupported by the CoreText profile")
  }
  let mut shown = field
  let mut owner : MacTextOwner? = None
  let use_ime = ime_acceptance ||
    @env.get_env_var("GPUI_FIELD_MACOS_IME") == Some("1")
  let observe = ime_acceptance ||
    state_observer_enabled(@env.get_env_var("GPUI_FIELD_MACOS_E2E_STATE"))
  let smoke = @env.args().contains("--smoke") ||
    @env.get_env_var("GPUI_FIELD_SMOKE") == Some("1")
  let mut smoke_requested = false
  let mut direct_armed = false
  let mut rearm_direct_after_frame = false
  let mut pending_direct_arm = false
  let mut pending_direct_sync = false
  let mut pending_ime_begin = use_ime && field.is_focused()
  let mut running = true
  let mut dirty = true
  let mut has_presented = false
  let mut native_window_focused = false
  let mut acceptance_focus_wait_ticks = 0
  let mut pending_ack : @macos.TextSessionTarget? = None
  let mut pending_owner_sync = false
  let mut pending_geometry_revision : Int? = None
  let mut width = initial_width
  let mut height = initial_height
  let mut scale = initial_scale
  let mut presentation = 0
  let mut commit_ledger = mac_commit_ledger()
  let mut acceptance = mac_acceptance_new(ime_acceptance)
  let mut frame_count = 0

  while running {
    if acceptance.enabled && mac_acceptance_has_operation(acceptance) {
      if mac_acceptance_operation_timed_out(acceptance) {
        acceptance = mac_acceptance_operation_timeout_trace(
          host, window, field, owner, acceptance, dirty, pending_owner_sync, pending_ack,
        )
        mac_acceptance_fail_owned(
          host, window, owner, acceptance, "timed out waiting for the accepted IME operation observation",
        )
      }
      acceptance = mac_acceptance_tick_operation_iteration(acceptance)
    }
    let native_window_ready = if ime_acceptance &&
      pending_ime_begin &&
      field.is_focused() &&
      use_ime {
      native_window_focused && mac_acceptance_window_is_key(host, window)
    } else {
      native_window_focused
    }
    if acceptance.enabled &&
      !acceptance.finished &&
      acceptance_poll_abort() != 0 {
      acceptance = mac_acceptance_abort(host, window, owner, acceptance)
      owner = None
      direct_armed = false
      running = false
    }
    if running &&
      pending_ime_begin &&
      field.is_focused() &&
      use_ime &&
      !native_window_ready {
      if ime_acceptance && acceptance_focus_wait_ticks >= 200 {
        let native_state = match host.testing_text_window_state(window) {
          Ok(value) => value
          Err(error) =>
            "unavailable: \{error.operation()} \{error.code().label()}"
        }
        mac_acceptance_fail_owned(
          host,
          window,
          owner,
          acceptance,
          "timed out waiting for the app-owned key window; native_state=\{native_state}",
        )
        running = false
      }
    } else if native_window_ready {
      acceptance_focus_wait_ticks = 0
      // Focus/key-window delivery can arrive after the first accepted frame.
      // Force one fresh accepted presentation before publishing the native
      // text session mirror/candidate geometry.
      if pending_ime_begin && owner is None {
        dirty = true
      }
    }
    if running && !dirty {
      match host.next_editor_event(timeout_ms=16) {
        Err(error) => {
          report(error)
          running = false
        }
        Ok(None) =>
          if ime_acceptance &&
            pending_ime_begin &&
            field.is_focused() &&
            use_ime &&
            !native_window_ready {
            // Count only completed 16 ms event-pump waits, so this is a
            // bounded wall-clock readiness wait even while redraw/input
            // events are being processed quickly.
            acceptance_focus_wait_ticks += 1
          }
        Ok(Some(@macos.Platform(event))) =>
          if mac_global_exit_requested(event) {
            running = false
          } else if event.window() == window {
            scale = event.scale()
            match event.kind() {
              @platform.Created => dirty = true
              @platform.Resized(width=new_width, height=new_height) => {
                width = new_width
                height = new_height
                match native_field_bounds(width, height) {
                  Ok(new_bounds) =>
                    match field.with_bounds(new_bounds) {
                      Ok(candidate) => {
                        let previous_revision = field.revision()
                        pending_geometry_revision = match owner {
                          Some(active) =>
                            mac_owner_geometry_revision_after_resize(
                              active,
                              previous_revision,
                              candidate.revision(),
                              pending_geometry_revision,
                            )
                          None => None
                        }
                        field = candidate
                        dirty = true
                      }
                      Err(_) =>
                        println("Field bounds rejected; text was retained.")
                    }
                  Err(_) => ()
                }
                pending_owner_sync = owner is Some(_)
              }
              @platform.ScaleChanged => {
                dirty = true
                pending_owner_sync = owner is Some(_)
              }
              @platform.FocusChanged(true) => {
                native_window_focused = true
                if pending_ime_begin && field.is_focused() {
                  dirty = true
                }
              }
              @platform.FocusChanged(false) => {
                native_window_focused = false
                if acceptance.enabled && !acceptance.finished {
                  mac_acceptance_fail_owned(
                    host, window, owner, acceptance, "the app-owned field window lost focus during acceptance",
                  )
                }
                match owner {
                  Some(active) => {
                    ignore(host.end_text_session(window, active.epoch))
                    owner = None
                  }
                  None =>
                    if direct_armed {
                      ignore(host.set_direct_keyboard_text(window, false))
                      direct_armed = false
                    }
                }
                match field.with_focus(false) {
                  Ok(candidate) => {
                    field = candidate
                    dirty = true
                  }
                  Err(_) => running = false
                }
                pending_ime_begin = false
                pending_direct_arm = false
                pending_direct_sync = false
                rearm_direct_after_frame = false
              }
              @platform.CloseRequested => {
                match owner {
                  Some(active) =>
                    ignore(host.end_text_session(window, active.epoch))
                  None => ignore(host.set_direct_keyboard_text(window, false))
                }
                owner = None
                ignore(host.destroy_window(window))
              }
              @platform.Destroyed | @platform.ExitRequested => running = false
              @platform.Input(input) =>
                if acceptance.enabled &&
                  mac_acceptance_has_operation(acceptance) {
                  mac_acceptance_fail_owned(
                    host, window, owner, acceptance, "unrelated platform input interrupted the IME operation observation",
                  )
                } else if mac_platform_input_allowed(input, use_ime) {
                  let clicked_outside = match input {
                    @primitives.PointerButtonPressed(
                      position~,
                      button=@primitives.Primary,
                      ..
                    ) =>
                      field.is_focused() && !field.bounds().contains(position)
                    _ => false
                  }
                  if clicked_outside {
                    match owner {
                      Some(active) => {
                        ignore(host.end_text_session(window, active.epoch))
                        owner = None
                      }
                      None =>
                        if direct_armed {
                          ignore(host.set_direct_keyboard_text(window, false))
                          direct_armed = false
                        }
                    }
                    match field.with_focus(false) {
                      Ok(candidate) => {
                        field = candidate
                        dirty = true
                      }
                      Err(_) => running = false
                    }
                    pending_ime_begin = false
                    pending_direct_arm = false
                    pending_direct_sync = false
                    rearm_direct_after_frame = false
                  } else {
                    let previous = field
                    let mut external_before_route = false
                    if use_ime &&
                      field.is_composing() &&
                      input is @primitives.PointerButtonPressed(..) {
                      match field.cancel_composition(measure, admit) {
                        Ok(candidate) => {
                          field = candidate
                          external_before_route = true
                        }
                        Err(_) =>
                          println(
                            "Composition cancellation failed; input was rejected.",
                          )
                      }
                    }
                    let mut input_allowed = true
                    if !use_ime &&
                      field.is_focused() &&
                      (
                        input is @primitives.KeyPressed(..) ||
                        input is @primitives.TextInput(..)
                      ) {
                      match host.direct_keyboard_text_epoch(window) {
                        Ok(_) => ()
                        Err(error) => {
                          report(error)
                          ignore(host.set_direct_keyboard_text(window, false))
                          direct_armed = false
                          input_allowed = false
                          match field.with_focus(false) {
                            Ok(candidate) => field = candidate
                            Err(_) => running = false
                          }
                        }
                      }
                    }
                    if input_allowed {
                      match route_input(field, input, width, height) {
                        Err(_) =>
                          println(
                            "Field input, CoreText measurement or admission rejected.",
                          )
                        Ok((candidate, action)) => {
                          let was_focused = field.is_focused()
                          let (candidate, action_external, blur) = mac_apply_action(
                            host, window, candidate, action, owner, use_ime,
                          )
                          let mut candidate = candidate
                          let focus_changed = was_focused !=
                            candidate.is_focused()
                          if blur {
                            match owner {
                              Some(active) => {
                                ignore(
                                  host.end_text_session(window, active.epoch),
                                )
                                owner = None
                              }
                              None =>
                                if direct_armed {
                                  ignore(
                                    host.set_direct_keyboard_text(window, false),
                                  )
                                  direct_armed = false
                                }
                            }
                            candidate = match candidate.with_focus(false) {
                              Ok(value) => value
                              Err(_) => candidate
                            }
                          }
                          if focus_changed && candidate.is_focused() {
                            if use_ime {
                              pending_ime_begin = true
                              pending_direct_arm = false
                            } else {
                              pending_ime_begin = false
                              pending_direct_arm = true
                            }
                          } else if focus_changed && !candidate.is_focused() {
                            match owner {
                              Some(active) => {
                                ignore(
                                  host.end_text_session(window, active.epoch),
                                )
                                owner = None
                              }
                              None =>
                                if direct_armed {
                                  ignore(
                                    host.set_direct_keyboard_text(window, false),
                                  )
                                  direct_armed = false
                                }
                            }
                            pending_ime_begin = false
                            pending_direct_arm = false
                          }
                          let edited = candidate.revision() !=
                            previous.revision()
                          let text_changed = candidate
                            .committed_document()
                            .text() !=
                            previous.committed_document().text()
                          let direct_text_commit = input
                            is @primitives.TextInput(..)
                          let external_mutation = external_before_route ||
                            action_external ||
                            (text_changed && !direct_text_commit)
                          if edited && use_ime {
                            match owner {
                              Some(active) =>
                                if external_mutation {
                                  match
                                    mac_fence_owner(
                                      host,
                                      active,
                                      candidate.revision(),
                                    ) {
                                    Ok(value) => owner = Some(value)
                                    Err(error) => {
                                      report(error)
                                      running = false
                                    }
                                  }
                                }
                              None => ()
                            }
                            pending_owner_sync = true
                          }
                          if edited && !use_ime {
                            pending_direct_sync = true
                          }
                          if !use_ime && external_mutation {
                            if direct_armed {
                              match
                                host.set_direct_keyboard_text(window, false) {
                                Ok(_) => direct_armed = false
                                Err(error) => report(error)
                              }
                            }
                            rearm_direct_after_frame = candidate.is_focused()
                          }
                          if input is @primitives.TextInput(..) && edited {
                            commit_ledger = mac_stage_commits(commit_ledger, 1)
                          }
                          field = candidate
                          if field.revision() != previous.revision() ||
                            focus_changed {
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
        Ok(Some(@macos.TextSession(batch))) => {
          if acceptance.enabled {
            acceptance = mac_acceptance_observe_batch(
              host, window, owner, acceptance, batch,
            )
          }
          match owner {
            None =>
              if acceptance.enabled {
                mac_acceptance_fail_owned(
                  host,
                  window,
                  None,
                  acceptance,
                  "editor batch arrived without an active owner",
                )
              } else {
                println("GPUI_MACOS_FIELD_REJECT StaleEpoch")
              }
            Some(active) =>
              if !mac_target_current(
                  active,
                  batch,
                  field,
                  geometry_revision_pending=pending_geometry_revision ==
                    Some(field.revision()),
                ) {
                if acceptance.enabled {
                  mac_acceptance_fail_owned(
                    host,
                    window,
                    Some(active),
                    acceptance,
                    "editor batch was stale or replayed",
                  )
                }
                println("GPUI_MACOS_FIELD_REJECT StaleOrReplayedBatch")
                match mac_restore_rejected_field(shown, field) {
                  Err(_) => running = false
                  Ok(restored) => {
                    match mac_fence_owner(host, active, restored.revision()) {
                      Ok(value) => owner = Some(value)
                      Err(error) => {
                        report(error)
                        running = false
                      }
                    }
                    field = restored
                    dirty = !has_presented ||
                      !mac_same_visible_field(field, shown)
                    pending_owner_sync = dirty
                    if !dirty {
                      match owner {
                        Some(fenced) =>
                          match
                            sync_macos_field_session(
                              host,
                              field,
                              fenced,
                              false,
                              None,
                            ) {
                            Ok(value) => owner = Some(value)
                            Err(error) => {
                              report(error)
                              running = false
                            }
                          }
                        None => ()
                      }
                    }
                  }
                }
              } else {
                match mac_apply_batch(field, active, batch, width, height) {
                  Err(error) => {
                    if acceptance.enabled {
                      mac_acceptance_fail_owned(
                        host,
                        window,
                        Some(active),
                        acceptance,
                        "editor batch rejected: \{mac_owner_error_label(error)}",
                      )
                    }
                    println(
                      "GPUI_MACOS_FIELD_REJECT \{mac_owner_error_label(error)}",
                    )
                    match mac_restore_rejected_field(shown, field) {
                      Err(_) => running = false
                      Ok(restored) => {
                        match
                          mac_fence_owner(host, active, restored.revision()) {
                          Ok(value) => owner = Some(value)
                          Err(error) => {
                            report(error)
                            running = false
                          }
                        }
                        field = restored
                        dirty = !has_presented ||
                          !mac_same_visible_field(field, shown)
                        pending_owner_sync = dirty
                        if !dirty {
                          match owner {
                            Some(fenced) =>
                              match
                                sync_macos_field_session(
                                  host,
                                  field,
                                  fenced,
                                  false,
                                  None,
                                ) {
                                Ok(value) => owner = Some(value)
                                Err(error) => {
                                  report(error)
                                  running = false
                                }
                              }
                            None => ()
                          }
                        }
                      }
                    }
                  }
                  Ok(transition) => {
                    let (candidate, action_external, blur) = mac_apply_action(
                      host,
                      window,
                      transition.field,
                      transition.action,
                      Some(transition.owner),
                      use_ime,
                    )
                    let mut candidate = candidate
                    let external = transition.external_edit || action_external
                    if acceptance.enabled &&
                      mac_acceptance_has_operation(acceptance) &&
                      external {
                      mac_acceptance_fail_owned(
                        host,
                        window,
                        Some(transition.owner),
                        acceptance,
                        "external edit interrupted the IME operation observation",
                      )
                    }
                    if blur ||
                      !candidate.is_focused() ||
                      !transition.owner.active {
                      ignore(
                        host.end_text_session(window, transition.owner.epoch),
                      )
                      owner = None
                      if candidate.is_focused() {
                        candidate = match candidate.with_focus(false) {
                          Ok(value) => value
                          Err(_) => candidate
                        }
                      }
                    } else if external {
                      match
                        mac_fence_owner(
                          host,
                          transition.owner,
                          candidate.revision(),
                        ) {
                        Ok(value) => owner = Some(value)
                        Err(error) => {
                          report(error)
                          running = false
                        }
                      }
                      pending_owner_sync = true
                    } else {
                      owner = Some(transition.owner)
                      pending_ack = Some(batch.target())
                    }
                    field = candidate
                    commit_ledger = mac_stage_commits(
                      commit_ledger,
                      transition.commits,
                    )
                    dirty = true
                  }
                }
              }
          }
        }
      }
    }

    if running &&
      !dirty &&
      acceptance.enabled &&
      acceptance.started &&
      mac_acceptance_owner_sync_allows_progress(acceptance, pending_owner_sync) {
      let progress = mac_acceptance_poll_receipt(
        host, window, field, owner, acceptance,
      )
      acceptance = progress.state
      field = progress.field
      owner = progress.owner
      if progress.dirty {
        dirty = true
      }
    }

    if dirty && running {
      match field_scene(field, width, height, scale) {
        Err(_) => {
          println("GPUI_MACOS_FIELD_REJECT SceneAdmission")
          match owner {
            Some(active) => ignore(host.end_text_session(window, active.epoch))
            None => ()
          }
          if direct_armed {
            ignore(host.set_direct_keyboard_text(window, false))
            direct_armed = false
          }
          running = false
        }
        Ok(scene) => {
          let presented = host.present(window, scene)
          match classify_field_frame(presented) {
            Accepted => {
              let accepted_batch_ack = pending_ack is Some(_)
              // Scale/resize events can precede their same-dispatch text batch
              // in the native FIFO. Keep this sync pending while the batch
              // blocks an update without its exact ACK.
              let mut owner_sync_deferred = false
              match pending_ack {
                Some(target) =>
                  match owner {
                    Some(active) =>
                      match
                        sync_macos_field_session(
                          host,
                          field,
                          active,
                          false,
                          Some(target.sequence()),
                        ) {
                        Ok(value) => owner = Some(value)
                        Err(error) =>
                          if mac_owner_sync_should_defer(
                              error,
                              pending_ack is Some(_),
                            ) {
                            owner_sync_deferred = true
                          } else {
                            report(error)
                            running = false
                          }
                      }
                    None => running = false
                  }
                None =>
                  if pending_owner_sync {
                    match owner {
                      Some(active) =>
                        match
                          sync_macos_field_session(
                            host,
                            field,
                            active,
                            false,
                            None,
                          ) {
                          Ok(value) => owner = Some(value)
                          Err(error) =>
                            if mac_owner_sync_should_defer(
                                error,
                                pending_ack is Some(_),
                              ) {
                              owner_sync_deferred = true
                            } else {
                              report(error)
                              running = false
                            }
                        }
                      None => ()
                    }
                  }
              }
              pending_ack = None
              pending_owner_sync = owner_sync_deferred
              commit_ledger = mac_accept_commits(commit_ledger)
              if pending_ime_begin &&
                field.is_focused() &&
                use_ime &&
                mac_ime_begin_ready(
                  pending_ime_begin,
                  field.is_focused(),
                  use_ime,
                  native_window_ready,
                ) {
                match begin_macos_field_session(host, window, field) {
                  Ok(value) => {
                    owner = Some(value)
                    direct_armed = false
                  }
                  Err(error) =>
                    if ime_acceptance {
                      let native_state = match
                        host.testing_text_window_state(window) {
                        Ok(value) => value
                        Err(state_error) =>
                          "unavailable: \{state_error.operation()} \{state_error.code().label()}"
                      }
                      mac_acceptance_fail_owned(
                        host,
                        window,
                        owner,
                        acceptance,
                        "could not begin the real IME session: \{error.operation()} \{error.code().label()}; native_state=\{native_state}",
                      )
                    } else {
                      report(error)
                      running = false
                    }
                }
                if owner is Some(_) || !running || !use_ime {
                  pending_ime_begin = false
                }
              }
              if !use_ime &&
                field.is_focused() &&
                (
                  pending_direct_sync ||
                  pending_direct_arm ||
                  rearm_direct_after_frame
                ) {
                if running && (pending_direct_arm || rearm_direct_after_frame) {
                  match host.set_direct_keyboard_text(window, true) {
                    Ok(_) => direct_armed = true
                    Err(error) => {
                      report(error)
                      running = false
                    }
                  }
                }
                if running &&
                  (
                    pending_direct_sync ||
                    pending_direct_arm ||
                    rearm_direct_after_frame
                  ) {
                  match sync_macos_direct_text(host, window, field) {
                    Ok(_) => pending_direct_sync = false
                    Err(error) => {
                      report(error)
                      if direct_armed {
                        ignore(host.set_direct_keyboard_text(window, false))
                        direct_armed = false
                      }
                      running = false
                    }
                  }
                }
                pending_direct_arm = false
                rearm_direct_after_frame = false
              } else if !field.is_focused() {
                pending_direct_sync = false
              }
              shown = field
              has_presented = true
              frame_count += 1
              dirty = false
              if observe && running && (!ime_acceptance || owner is Some(_)) {
                presentation += 1
                let epoch = match owner {
                  Some(active) => active.epoch
                  None => 0
                }
                println(
                  state_line(presentation, shown, epoch, commit_ledger.accepted),
                )
                state_flush_stdout()
              }
              if acceptance.enabled &&
                running &&
                (acceptance.started || owner is Some(_)) &&
                mac_acceptance_owner_sync_allows_progress(
                  acceptance, owner_sync_deferred,
                ) {
                if !acceptance.started {
                  match owner {
                    Some(active) =>
                      acceptance = mac_acceptance_start(
                        host,
                        window,
                        field,
                        active,
                        commit_ledger.accepted,
                        acceptance,
                      )
                    None =>
                      mac_acceptance_fail_owned(
                        host, window, owner, acceptance, "initial accepted field frame did not begin its IME session",
                      )
                  }
                  if acceptance.finished {
                    owner = None
                    running = false
                  }
                } else {
                  let progress = mac_acceptance_after_frame(
                    host, window, field, owner, acceptance, accepted_batch_ack, pending_geometry_revision,
                  )
                  acceptance = progress.state
                  field = progress.field
                  owner = progress.owner
                  if progress.dirty {
                    dirty = true
                  }
                  if acceptance.finished {
                    running = false
                  }
                }
                if mac_acceptance_final_frame_ready({
                    state: acceptance,
                    field,
                    owner,
                    dirty,
                  }) &&
                  running {
                  acceptance = mac_acceptance_finish(
                    host,
                    window,
                    field,
                    commit_ledger.accepted,
                    owner,
                    acceptance,
                  )
                  running = false
                }
              }
              if smoke && !smoke_requested {
                smoke_requested = true
                println(
                  "GPUI_MACOS_FIELD_SMOKE {\"frames\":\{frame_count},\"accepted\":true}",
                )
                ignore(host.request_close(window))
              }
            }
            BusyPending => ()
            RecoverPending =>
              match host.recover_renderer(window) {
                Ok(_) => ()
                Err(error) => {
                  report(error)
                  running = false
                }
              }
            RejectPending => {
              if presented is Err(error) {
                report(error)
              }
              pending_ack = None
              commit_ledger = mac_reject_commits(commit_ledger)
              let pending = field
              match mac_restore_rejected_field(shown, pending) {
                Err(_) => running = false
                Ok(restored) => {
                  let mut fenced_owner : MacTextOwner? = None
                  match owner {
                    Some(active) =>
                      match mac_fence_owner(host, active, restored.revision()) {
                        Ok(value) => {
                          owner = Some(value)
                          fenced_owner = Some(value)
                        }
                        Err(error) => {
                          report(error)
                          running = false
                        }
                      }
                    None => ()
                  }
                  if direct_armed {
                    match host.set_direct_keyboard_text(window, false) {
                      Ok(_) => {
                        direct_armed = false
                        rearm_direct_after_frame = restored.is_focused()
                      }
                      Err(error) => {
                        report(error)
                        running = false
                      }
                    }
                  }
                  field = restored
                  let redraw = !has_presented ||
                    !mac_same_visible_field(field, shown)
                  dirty = redraw
                  pending_owner_sync = redraw && fenced_owner is Some(_)
                  if !redraw {
                    match fenced_owner {
                      Some(fenced) =>
                        match
                          sync_macos_field_session(
                            host,
                            field,
                            fenced,
                            false,
                            None,
                          ) {
                          Ok(value) => owner = Some(value)
                          Err(error) => {
                            report(error)
                            running = false
                          }
                        }
                      None => ()
                    }
                    if mac_direct_rearm_is_safe(
                        use_ime, has_presented, field, shown,
                      ) {
                      match host.set_direct_keyboard_text(window, true) {
                        Ok(_) => {
                          direct_armed = true
                          match sync_macos_direct_text(host, window, field) {
                            Ok(_) => rearm_direct_after_frame = false
                            Err(error) => {
                              report(error)
                              ignore(
                                host.set_direct_keyboard_text(window, false),
                              )
                              direct_armed = false
                              running = false
                            }
                          }
                        }
                        Err(error) => {
                          report(error)
                          running = false
                        }
                      }
                    }
                  }
                  if !has_presented {
                    running = false
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  match owner {
    Some(active) => ignore(host.end_text_session(window, active.epoch))
    None => ignore(host.set_direct_keyboard_text(window, false))
  }
  ignore(host.destroy_window(window))
  ignore(host.stop())
}

///|
fn main {
  run_window()
}
