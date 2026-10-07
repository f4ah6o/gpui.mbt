///|
struct MacAcceptanceKey {
  code : Int
  text : String
}

///|
struct MacImeAcceptance {
  enabled : Bool
  started : Bool
  finished : Bool
  source_restored : Bool
  step : Int
  expected_dispatch_id : Int64
  expected_key_code : Int
  host_epoch : Int64
  session_epoch : Int
  input_source : String
  preedit_callbacks : Int
  commit_callbacks : Int
  cancel_callbacks : Int
  batches : Array[String]
  receipts : Array[String]
  pending_batch : @macos.EditorBatch?
  pending_preedits : Int
  pending_commits : Int
  pending_cancellations : Int
  last_preedit_identity : String
  last_candidate_screen_rect : String
  candidate_screen_rect : String
}

///|
struct MacAcceptanceProgress {
  state : MacImeAcceptance
  field : @text_field.TextField
  owner : MacTextOwner?
  dirty : Bool
}

///|
fn mac_acceptance_new(enabled : Bool) -> MacImeAcceptance {
  {
    enabled,
    started: false,
    finished: false,
    source_restored: false,
    step: -1,
    expected_dispatch_id: 0L,
    expected_key_code: 0,
    host_epoch: 0L,
    session_epoch: 0,
    input_source: "",
    preedit_callbacks: 0,
    commit_callbacks: 0,
    cancel_callbacks: 0,
    batches: [],
    receipts: [],
    pending_batch: None,
    pending_preedits: 0,
    pending_commits: 0,
    pending_cancellations: 0,
    last_preedit_identity: "",
    last_candidate_screen_rect: "null",
    candidate_screen_rect: "null",
  }
}

///|
/// Fail only after the collector has received the failure line and requested
/// cleanup. This leaves the process alive long enough to return an explicit
/// per-window source/session restoration receipt.
fn[T] mac_acceptance_fail_owned(
  host : @macos.Host,
  window : @platform.WindowId,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
  message : String,
) -> T {
  println("GPUI_MACOS_IME_ACCEPTANCE_FAIL \{message}")
  state_flush_stdout()
  ignore(acceptance_wait_command())
  ignore(mac_acceptance_abort(host, window, owner, state))
  abort("GPUI_MACOS_IME_ACCEPTANCE_FAIL \{message}")
}

///|
fn mac_acceptance_abort(
  host : @macos.Host,
  window : @platform.WindowId,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
) -> MacImeAcceptance {
  let session_closed = match owner {
    Some(active) =>
      match host.end_text_session(window, active.epoch) {
        Ok(_) => true
        Err(_) =>
          match host.testing_text_window_state(window) {
            Ok(value) =>
              mac_acceptance_bool_field(value, "session_active") == Some(false)
            Err(_) => false
          }
      }
    None => true
  }
  let source_restored = if state.source_restored {
    true
  } else {
    match host.testing_restore_input_source(window) {
      Ok(_) => true
      Err(_) => false
    }
  }
  println(
    "GPUI_MACOS_IME_ABORTED {\"schema_version\":1,\"restored\":\{source_restored},\"session_closed\":\{session_closed},\"host_epoch\":\{state.host_epoch},\"session_epoch\":\{state.session_epoch}}",
  )
  state_flush_stdout()
  { ..state, finished: true, source_restored, }
}

///|
fn mac_acceptance_parse(value : String) -> Json? {
  Some(@json.parse(value)) catch {
    _ => None
  }
}

///|
fn mac_acceptance_json_field(value : String, name : String) -> Json? {
  match mac_acceptance_parse(value) {
    Some(Object(object)) => object.get(name)
    _ => None
  }
}

///|
fn mac_acceptance_int_field(value : String, name : String) -> Int64? {
  match mac_acceptance_json_field(value, name) {
    Some(Number(number, ..)) if number >= 0.0 &&
      number <= 9007199254740991.0 &&
      number.to_int64().to_double() == number => Some(number.to_int64())
    _ => None
  }
}

///|
fn mac_acceptance_string_field(value : String, name : String) -> String? {
  match mac_acceptance_json_field(value, name) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn mac_acceptance_bool_field(value : String, name : String) -> Bool? {
  match mac_acceptance_json_field(value, name) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn mac_acceptance_source_is_kotoeri(source : String) -> Bool {
  source.contains("Kotoeri")
}

///|
fn mac_acceptance_valid_identity(identity : String) -> Bool {
  match mac_acceptance_parse(identity) {
    Some(Object(object)) =>
      mac_acceptance_int_field(identity, "schema_version") == Some(1L) &&
      object.get("window_id") is Some(_) &&
      object.get("host_epoch") is Some(_) &&
      object.get("session_epoch") is Some(_) &&
      object.get("batch_sequence") is Some(_) &&
      object.get("accepted_revision") is Some(_) &&
      object.get("frame_revision") is Some(_) &&
      object.get("frame_sha256") is Some(String(_)) &&
      object.get("text") is Some(String(_))
    _ => false
  }
}

///|
fn mac_acceptance_identity_matches(
  identity : String,
  window : @platform.WindowId,
  host_epoch : Int64,
  field : @text_field.TextField,
  batch : @macos.EditorBatch?,
  owner : MacTextOwner?,
  acknowledged : Bool,
) -> Bool {
  if !mac_acceptance_valid_identity(identity) {
    return false
  }
  let current_epoch = match owner {
    Some(value) => value.epoch
    None => 0
  }
  let target = match batch {
    Some(value) => Some(value.target())
    None => None
  }
  let header_matches = mac_acceptance_int_field(identity, "window_id") ==
    Some(window.value()) &&
    mac_acceptance_int_field(identity, "host_epoch") == Some(host_epoch) &&
    mac_acceptance_int_field(identity, "session_epoch") ==
    Some(current_epoch.to_int64()) &&
    mac_acceptance_string_field(identity, "text") ==
    Some(field.document().text())
  if !header_matches {
    return false
  }
  match (target, acknowledged) {
    (Some(value), true) =>
      mac_acceptance_int_field(identity, "session_epoch") ==
      Some(value.epoch().to_int64()) &&
      mac_acceptance_int_field(identity, "batch_sequence") ==
      Some(value.sequence()) &&
      mac_acceptance_int_field(identity, "accepted_revision") ==
      Some(field.revision().to_int64())
    (Some(_), false) => true
    (None, false) => true
    _ => false
  }
}

///|
fn mac_acceptance_key(step : Int) -> MacAcceptanceKey? {
  match step {
    0 => Some({ code: 45, text: "n", })
    1 => Some({ code: 34, text: "i", })
    2 => Some({ code: 4, text: "h", })
    3 => Some({ code: 31, text: "o", })
    4 => Some({ code: 45, text: "n", })
    5 => Some({ code: 5, text: "g", })
    6 => Some({ code: 31, text: "o", })
    7 => Some({ code: 49, text: " ", })
    8 => Some({ code: 36, text: "\r", })
    9 => Some({ code: 45, text: "n", })
    10 => Some({ code: 53, text: "\u{1B}", })
    _ => None
  }
}

///|
fn mac_acceptance_post_step(
  host : @macos.Host,
  window : @platform.WindowId,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
  step : Int,
) -> MacImeAcceptance {
  let key = match mac_acceptance_key(step) {
    Some(value) => value
    None =>
      mac_acceptance_fail_owned(
        host,
        window,
        owner,
        state,
        "no key is defined for step \{step}",
      )
  }
  match
    host.testing_post_key(
      window,
      key.code,
      key.text,
      key.text,
      @primitives.Modifiers::new(
        shift=false,
        control=false,
        alt=false,
        meta=false,
      ),
    ) {
    Ok(_) => ()
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        owner,
        state,
        "could not post app-owned key \{step}: \{error.operation()} \{error.code().label()}",
      )
  }
  let receipt = match host.testing_key_dispatch_receipt(window) {
    Ok(value) => value
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        owner,
        state,
        "could not read key dispatch receipt: \{error.operation()} \{error.code().label()}",
      )
  }
  let dispatch_id = match mac_acceptance_int_field(receipt, "dispatch_id") {
    Some(value) if value > state.expected_dispatch_id => value
    _ =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "native key dispatch receipt did not advance",
      )
  }
  if mac_acceptance_int_field(receipt, "key_code") != Some(key.code.to_int64()) ||
    mac_acceptance_bool_field(receipt, "down_posted") != Some(true) ||
    mac_acceptance_bool_field(receipt, "up_posted") != Some(true) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "native key dispatch receipt did not identify the posted key pair",
    )
  }
  {
    ..state,
    step,
    expected_dispatch_id: dispatch_id,
    expected_key_code: key.code,
  }
}

///|
fn mac_acceptance_start(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : MacTextOwner,
  commit_count : Int,
  state : MacImeAcceptance,
) -> MacImeAcceptance {
  let session_state = {
    ..state,
    host_epoch: owner.host_epoch,
    session_epoch: owner.epoch,
  }
  if !field.is_focused() || owner.epoch <= 0 || !owner.active {
    mac_acceptance_fail_owned(
      host,
      window,
      Some(owner),
      session_state,
      "initial frame did not establish a focused editor session",
    )
  }
  match host.testing_select_kotoeri_source(window) {
    Ok(_) => ()
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        Some(owner),
        session_state,
        "could not select the enabled Kotoeri source for this app context: \{error.operation()} \{error.code().label()}",
      )
  }
  let source = match host.testing_selected_input_source(window) {
    Ok(value) => value
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        Some(owner),
        session_state,
        "could not query the selected input source: \{error.operation()} \{error.code().label()}",
      )
  }
  if !mac_acceptance_source_is_kotoeri(source) {
    mac_acceptance_fail_owned(
      host,
      window,
      Some(owner),
      session_state,
      "selected input source is not Kotoeri: \{source}",
    )
  }
  let window_geometry = match host.testing_text_window_state(window) {
    Ok(value) => value
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        Some(owner),
        session_state,
        "native window geometry unavailable: \{error.operation()} \{error.code().label()}",
      )
  }
  let identity = match host.testing_frame_identity(window) {
    Ok(value) => value
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        Some(owner),
        session_state,
        "initial frame identity unavailable: \{error.operation()} \{error.code().label()}",
      )
  }
  if !mac_acceptance_identity_matches(
      identity,
      window,
      owner.host_epoch,
      field,
      None,
      Some(owner),
      false,
    ) {
    mac_acceptance_fail_owned(
      host,
      window,
      Some(owner),
      session_state,
      "initial accepted frame identity did not match the focused owner",
    )
  }
  let source_revision = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_REVISION"),
  )
  let source_tree = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_TREE"),
  )
  let binary_sha256 = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_BINARY_SHA256"),
  )
  let ready = {
    ..state,
    started: true,
    step: -1,
    host_epoch: owner.host_epoch,
    session_epoch: owner.epoch,
    input_source: source,
  }
  println(
    "GPUI_MACOS_IME_CHECKPOINT {\"schema_version\":1,\"phase\":\"initial-ready\",\"input_source\":\{@json.to_json(source).stringify()},\"text\":\{@json.to_json(field.document().text()).stringify()},\"field_revision\":\{field.revision()},\"field_bounds\":\{field_bounds_json(field)},\"window_geometry\":\{window_geometry},\"session_epoch\":\{owner.epoch},\"commit_count\":\{commit_count},\"frame_identity\":\{identity},\"source_revision\":\{source_revision},\"source_tree\":\{source_tree},\"binary_sha256\":\{binary_sha256}}",
  )
  state_flush_stdout()
  let command = acceptance_wait_command()
  if command == 4 {
    return mac_acceptance_abort(host, window, Some(owner), ready)
  }
  if command != 1 {
    mac_acceptance_fail_owned(
      host,
      window,
      Some(owner),
      ready,
      "runner did not send begin after the initial screenshot",
    )
  }
  mac_acceptance_post_step(host, window, Some(owner), ready, 0)
}

///|
fn mac_acceptance_observe_batch(
  host : @macos.Host,
  window : @platform.WindowId,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
  batch : @macos.EditorBatch,
) -> MacImeAcceptance {
  if state.pending_batch is Some(_) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "a second text batch arrived before the first was presented",
    )
  }
  let mut preedits = 0
  let mut commits = 0
  let mut cancellations = 0
  for event in batch.events() {
    match event {
      @macos.Preedit(..) => preedits += 1
      @macos.Commit(..) => commits += 1
      @macos.Cancelled => cancellations += 1
      _ => ()
    }
  }
  {
    ..state,
    pending_batch: Some(batch),
    pending_preedits: preedits,
    pending_commits: commits,
    pending_cancellations: cancellations,
  }
}

///|
fn mac_acceptance_rect_json(rect : @primitives.Rect) -> String {
  let width = rect.right() - rect.left()
  let height = rect.bottom() - rect.top()
  let values = [rect.left(), rect.top(), width, height]
  for value in values {
    if value.is_nan() || value.is_inf() {
      return "null"
    }
  }
  "{\"x\":\{@json.to_json(rect.left()).stringify()},\"y\":\{@json.to_json(rect.top()).stringify()},\"width\":\{@json.to_json(width).stringify()},\"height\":\{@json.to_json(height).stringify()}}"
}

///|
fn mac_acceptance_after_frame(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
  acknowledged : Bool,
) -> MacAcceptanceProgress {
  let mut next_state = state
  match state.pending_batch {
    None => ()
    Some(batch) => {
      let identity = match host.testing_frame_identity(window) {
        Ok(value) => value
        Err(error) =>
          mac_acceptance_fail_owned(
            host,
            window,
            owner,
            state,
            "accepted frame identity unavailable: \{error.operation()} \{error.code().label()}",
          )
      }
      if !mac_acceptance_identity_matches(
          identity,
          window,
          state.host_epoch,
          field,
          Some(batch),
          owner,
          acknowledged,
        ) {
        mac_acceptance_fail_owned(
          host, window, owner, state, "accepted frame identity did not match the applied editor batch",
        )
      }
      let candidate_rect = match host.testing_candidate_rect(window) {
        Ok(rect) => mac_acceptance_rect_json(rect)
        Err(_) => "null"
      }
      if state.pending_preedits > 0 && candidate_rect == "null" {
        mac_acceptance_fail_owned(
          host, window, owner, state, "composition frame had no synchronized candidate rect",
        )
      }
      let target = batch.target()
      let entry = "{\"sequence\":\{target.sequence()},\"owner_revision\":\{target.owner_revision()},\"epoch\":\{target.epoch()},\"accepted_revision\":\{field.revision()},\"acknowledged\":\{acknowledged},\"preedit_callbacks\":\{state.pending_preedits},\"commit_callbacks\":\{state.pending_commits},\"cancel_callbacks\":\{state.pending_cancellations},\"frame_identity\":\{identity},\"candidate_screen_rect\":\{candidate_rect}}"
      next_state.batches.push(entry)
      if candidate_rect != "null" {
        next_state = { ..next_state, candidate_screen_rect: candidate_rect, }
      }
      if state.pending_preedits > 0 {
        next_state = {
          ..next_state,
          last_preedit_identity: identity,
          last_candidate_screen_rect: candidate_rect,
        }
      }
      next_state = {
        ..next_state,
        preedit_callbacks: state.preedit_callbacks + state.pending_preedits,
        commit_callbacks: state.commit_callbacks + state.pending_commits,
        cancel_callbacks: state.cancel_callbacks + state.pending_cancellations,
        pending_batch: None,
        pending_preedits: 0,
        pending_commits: 0,
        pending_cancellations: 0,
      }
    }
  }
  mac_acceptance_poll_receipt(host, window, field, owner, next_state)
}

///|
fn mac_acceptance_poll_receipt(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
) -> MacAcceptanceProgress {
  if !state.enabled || !state.started || state.expected_dispatch_id <= 0L {
    return { state, field, owner, dirty: false, }
  }
  let receipt = match host.testing_key_dispatch_receipt(window) {
    Ok(value) => value
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        owner,
        state,
        "key dispatch receipt unavailable: \{error.operation()} \{error.code().label()}",
      )
  }
  if mac_acceptance_int_field(receipt, "dispatch_id") !=
    Some(state.expected_dispatch_id) ||
    mac_acceptance_int_field(receipt, "key_code") !=
    Some(state.expected_key_code.to_int64()) ||
    mac_acceptance_int_field(receipt, "host_epoch") != Some(state.host_epoch) ||
    mac_acceptance_bool_field(receipt, "down_posted") != Some(true) ||
    mac_acceptance_bool_field(receipt, "up_posted") != Some(true) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "key dispatch receipt changed identity or omitted a posted event",
    )
  }
  let down = mac_acceptance_bool_field(receipt, "down_dispatched") == Some(true)
  let up = mac_acceptance_bool_field(receipt, "up_dispatched") == Some(true)
  if !down || !up {
    return { state, field, owner, dirty: false, }
  }
  if state.pending_batch is Some(_) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "native dispatched key-up before its text batch was accepted",
    )
  }
  let next_state = { ..state, receipts: state.receipts.copy(), }
  next_state.receipts.push(receipt)
  let completed_step = state.step
  if completed_step == 7 {
    if !field.is_composing() ||
      next_state.preedit_callbacks == 0 ||
      next_state.last_preedit_identity.length() == 0 ||
      next_state.last_candidate_screen_rect == "null" {
      mac_acceptance_fail_owned(
        host, window, owner, next_state, "Kotoeri Space did not leave an accepted visible conversion preview",
      )
    }
    let source_revision = json_string(
      @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_REVISION"),
    )
    let source_tree = json_string(
      @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_TREE"),
    )
    let binary_sha256 = json_string(
      @env.get_env_var("GPUI_FIELD_MACOS_BINARY_SHA256"),
    )
    println(
      "GPUI_MACOS_IME_CHECKPOINT {\"schema_version\":1,\"phase\":\"composition-ready\",\"input_source\":\{@json.to_json(next_state.input_source).stringify()},\"text\":\{@json.to_json(field.document().text()).stringify()},\"committed\":\{@json.to_json(field.committed_document().text()).stringify()},\"field_revision\":\{field.revision()},\"field_bounds\":\{field_bounds_json(field)},\"session_epoch\":\{next_state.session_epoch},\"composing\":true,\"marked\":\{marked_json(field)},\"caret\":\{caret_json(field)},\"candidate_screen_rect\":\{next_state.last_candidate_screen_rect},\"frame_identity\":\{next_state.last_preedit_identity},\"source_revision\":\{source_revision},\"source_tree\":\{source_tree},\"binary_sha256\":\{binary_sha256}}",
    )
    state_flush_stdout()
    let command = acceptance_wait_command()
    if command == 4 {
      let aborted = mac_acceptance_abort(host, window, owner, next_state)
      return { state: aborted, field, owner: None, dirty: false, }
    }
    if command != 3 {
      mac_acceptance_fail_owned(
        host, window, owner, next_state, "runner did not send preview after the composition screenshot",
      )
    }
  }
  if completed_step == 8 &&
    (
      field.committed_document().text() != "Hello 日本語" ||
      field.is_composing() ||
      next_state.commit_callbacks != 1
    ) {
    mac_acceptance_fail_owned(
      host, window, owner, next_state, "Return did not accept exactly one `日本語` commit",
    )
  }
  if completed_step == 10 &&
    (
      field.committed_document().text() != "Hello 日本語" ||
      field.is_composing() ||
      next_state.cancel_callbacks == 0
    ) {
    mac_acceptance_fail_owned(
      host, window, owner, next_state, "Escape did not cancel the follow-up composition",
    )
  }
  if completed_step == 10 {
    let blurred = match field.with_focus(false) {
      Ok(value) => value
      Err(_) =>
        mac_acceptance_fail_owned(
          host, window, owner, next_state, "could not blur the field after cancellation",
        )
    }
    match owner {
      Some(active) =>
        match host.end_text_session(window, active.epoch) {
          Ok(_) => ()
          Err(error) =>
            mac_acceptance_fail_owned(
              host,
              window,
              owner,
              next_state,
              "could not end the field session after cancellation: \{error.operation()} \{error.code().label()}",
            )
        }
      None =>
        mac_acceptance_fail_owned(
          host, window, owner, next_state, "text session ended before the cancellation fence",
        )
    }
    return {
      state: { ..next_state, step: 11, expected_dispatch_id: 0L, },
      field: blurred,
      owner: None,
      dirty: true,
    }
  }
  let next_step = completed_step + 1
  if next_step <= 10 {
    let posted = mac_acceptance_post_step(
      host,
      window,
      owner,
      { ..next_state, expected_dispatch_id: 0L, },
      next_step,
    )
    return { state: posted, field, owner, dirty: false, }
  }
  { state: next_state, field, owner, dirty: false, }
}

///|
fn mac_acceptance_finish(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  commit_count : Int,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
) -> MacImeAcceptance {
  if state.finished {
    return state
  }
  if field.committed_document().text() != "Hello 日本語" ||
    field.is_composing() ||
    field.is_focused() ||
    commit_count != 1 ||
    state.preedit_callbacks == 0 ||
    state.commit_callbacks != 1 ||
    state.cancel_callbacks == 0 ||
    state.receipts.length() != 11 ||
    state.pending_batch is Some(_) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "final accepted text, focus, callbacks, or key receipts were wrong",
    )
  }
  let identity = match host.testing_frame_identity(window) {
    Ok(value) => value
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        owner,
        state,
        "final frame identity unavailable: \{error.operation()} \{error.code().label()}",
      )
  }
  let final_session_epoch = match
    mac_acceptance_int_field(identity, "session_epoch") {
    Some(value) => value
    None => 0L
  }
  let final_frame_revision = match
    mac_acceptance_int_field(identity, "frame_revision") {
    Some(value) => value
    None => 0L
  }
  let last_composition_frame_revision = match
    mac_acceptance_int_field(state.last_preedit_identity, "frame_revision") {
    Some(value) => value
    None => 0L
  }
  if !mac_acceptance_valid_identity(identity) ||
    mac_acceptance_int_field(identity, "window_id") != Some(window.value()) ||
    mac_acceptance_int_field(identity, "host_epoch") != Some(state.host_epoch) ||
    final_session_epoch != state.session_epoch.to_int64() ||
    final_frame_revision <= last_composition_frame_revision ||
    mac_acceptance_string_field(identity, "text") !=
    Some(field.document().text()) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "final presented frame identity did not match the field",
    )
  }
  let source = @json.to_json(state.input_source).stringify()
  let committed_text = @json.to_json(field.committed_document().text()).stringify()
  let source_revision = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_REVISION"),
  )
  let source_tree = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_TREE"),
  )
  let binary_sha256 = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_BINARY_SHA256"),
  )
  let mut batch_records = ""
  for index, record in state.batches {
    if index > 0 {
      batch_records += ","
    }
    batch_records += record
  }
  let mut receipt_records = ""
  for index, record in state.receipts {
    if index > 0 {
      receipt_records += ","
    }
    receipt_records += record
  }
  match host.testing_restore_input_source(window) {
    Ok(_) => ()
    Err(error) =>
      mac_acceptance_fail_owned(
        host,
        window,
        owner,
        state,
        "could not restore the app context's previous keyboard source: \{error.operation()} \{error.code().label()}",
      )
  }
  let restored_state = { ..state, source_restored: true, }
  let output = "GPUI_MACOS_IME_ACCEPTANCE {\"schema_version\":1,\"window_id\":\{window.value()},\"host_epoch\":\{state.host_epoch},\"session_epoch\":\{state.session_epoch},\"final_session_epoch\":\{final_session_epoch},\"input_source\":\{source},\"preedit_callbacks\":\{state.preedit_callbacks},\"commit_callbacks\":\{state.commit_callbacks},\"cancel_callbacks\":\{state.cancel_callbacks},\"committed_text\":\{committed_text},\"composing\":false,\"focused\":false,\"commit_count\":\{commit_count},\"batches\":[\{batch_records}],\"receipts\":[\{receipt_records}],\"candidate_screen_rect\":\{state.candidate_screen_rect},\"field_bounds\":\{field_bounds_json(field)},\"final_frame_identity\":\{identity},\"final_frame_revision\":\{final_frame_revision},\"source_revision\":\{source_revision},\"source_tree\":\{source_tree},\"binary_sha256\":\{binary_sha256}}"
  println(output)
  state_flush_stdout()
  let command = acceptance_wait_command()
  if command == 4 {
    return mac_acceptance_abort(host, window, None, restored_state)
  }
  if command != 2 {
    mac_acceptance_fail_owned(
      host, window, owner, restored_state, "runner did not send quit after the final screenshot",
    )
  }
  { ..restored_state, finished: true, }
}
