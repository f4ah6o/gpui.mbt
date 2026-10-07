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
  dispatch_trace_record_count : Int
  dispatch_trace_truncated : Bool
  operation_timeout_trace_emitted : Bool
  operations : Array[String]
  effect_observations : Array[String]
  operation : MacAcceptanceOperation?
  frozen_dispatch_receipt : String?
}

///|
struct MacAcceptanceOperation {
  id : Int
  step : Int
  dispatch_id : Int64
  key_code : Int
  window_id : Int64
  host_epoch : Int64
  session_epoch : Int
  baseline_batch_index : Int
  baseline_batch_sequence : Int64
  baseline_accepted_revision : Int64
  baseline_frame_revision : Int64
  baseline_preedit_callbacks : Int
  baseline_commit_callbacks : Int
  baseline_cancel_callbacks : Int
  baseline_composing : Bool
  baseline_frame_identity : String
  loop_iterations : Int
  effect_index : Int?
  release_batch_index : Int?
  release_batch_sequence : Int64?
  release_frame_revision : Int64?
  release_geometry_revision : Int?
}

///|
enum MacAcceptanceOperationEffect {
  WaitingForCallbackEffect
  ReturnCommitEffect
  EscapeCancelEffect
} derive(Eq)

///|
const MAC_ACCEPTANCE_OPERATION_ITERATION_LIMIT : Int = 200

///|
const MAC_ACCEPTANCE_DISPATCH_TRACE_LIMIT : Int = 64

///|
const MAC_ACCEPTANCE_DISPATCH_TRACE_TERMINAL_RESERVE : Int = 1

///|
const MAC_ACCEPTANCE_DISPATCH_TRACE_TRUNCATION_RESERVE : Int = 1

///|
const MAC_ACCEPTANCE_DISPATCH_TRACE_ORDINARY_LIMIT : Int = MAC_ACCEPTANCE_DISPATCH_TRACE_LIMIT -
  MAC_ACCEPTANCE_DISPATCH_TRACE_TERMINAL_RESERVE -
  MAC_ACCEPTANCE_DISPATCH_TRACE_TRUNCATION_RESERVE

///|
struct MacAcceptanceProgress {
  state : MacImeAcceptance
  field : @text_field.TextField
  owner : MacTextOwner?
  dirty : Bool
}

///|
fn mac_acceptance_final_frame_ready(progress : MacAcceptanceProgress) -> Bool {
  progress.state.step == 11 &&
  !progress.state.finished &&
  !progress.field.is_focused() &&
  !progress.dirty
}

///|
fn mac_acceptance_has_operation(state : MacImeAcceptance) -> Bool {
  state.operation is Some(_)
}

///|
// The only operation-wait budget source is the top of the main-loop iteration.
// Receipt polling and frame handling never advance or restart it.
fn mac_acceptance_tick_operation_iteration(
  state : MacImeAcceptance,
) -> MacImeAcceptance {
  match state.operation {
    Some(operation) if operation.loop_iterations <
      MAC_ACCEPTANCE_OPERATION_ITERATION_LIMIT =>
      {
        ..state,
        operation: Some({
          ..operation,
          loop_iterations: operation.loop_iterations + 1,
        }),
      }
    _ => state
  }
}

///|
fn mac_acceptance_operation_timed_out(state : MacImeAcceptance) -> Bool {
  match state.operation {
    Some(operation) =>
      operation.loop_iterations >= MAC_ACCEPTANCE_OPERATION_ITERATION_LIMIT
    None => false
  }
}

///|
fn mac_acceptance_diagnostic_enabled(
  enabled : Bool,
  started : Bool,
  environment : String?,
) -> Bool {
  enabled && started && environment == Some("1")
}

///|
fn mac_acceptance_diagnostic_next_record_count(count : Int) -> Int? {
  if count < 0 || count >= MAC_ACCEPTANCE_DISPATCH_TRACE_LIMIT {
    None
  } else {
    Some(count + 1)
  }
}

///|
fn mac_acceptance_diagnostic_receipt_json(source : String) -> String? {
  if source.length() > 512 {
    return None
  }
  let allowed = [
    "schema_version", "dispatch_id", "key_code", "down_posted", "up_posted", "down_dispatched",
    "up_dispatched", "host_epoch", "session_epoch", "batch_sequence", "window_sequence",
  ]
  let integer_fields = [
    "schema_version", "dispatch_id", "key_code", "host_epoch", "session_epoch", "batch_sequence",
    "window_sequence",
  ]
  let boolean_fields = [
    "down_posted", "up_posted", "down_dispatched", "up_dispatched",
  ]
  match mac_acceptance_parse(source) {
    Some(Object(object)) if object.length() == allowed.length() => {
      for (key, value) in object.to_array() {
        if !allowed.contains(key) {
          return None
        }
        if integer_fields.contains(key) {
          match value {
            Number(number, ..) if number >= 0.0 &&
              number <= 9007199254740991.0 &&
              number.to_int64().to_double() == number => ()
            _ => return None
          }
        } else if boolean_fields.contains(key) {
          match value {
            True | False => ()
            _ => return None
          }
        } else {
          return None
        }
      }
      if mac_acceptance_int_field(source, "schema_version") != Some(1L) {
        return None
      }
      Some(source)
    }
    _ => None
  }
}

///|
fn mac_acceptance_diagnostic_frame_projection(source : String) -> String? {
  if !mac_acceptance_valid_identity(source) {
    return None
  }
  let window_id = match mac_acceptance_int_field(source, "window_id") {
    Some(value) => value
    None => return None
  }
  let host_epoch = match mac_acceptance_int_field(source, "host_epoch") {
    Some(value) => value
    None => return None
  }
  let session_epoch = match mac_acceptance_int_field(source, "session_epoch") {
    Some(value) => value
    None => return None
  }
  let batch_sequence = match
    mac_acceptance_int_field(source, "batch_sequence") {
    Some(value) => value
    None => return None
  }
  let accepted_revision = match
    mac_acceptance_int_field(source, "accepted_revision") {
    Some(value) => value
    None => return None
  }
  let frame_revision = match
    mac_acceptance_int_field(source, "frame_revision") {
    Some(value) => value
    None => return None
  }
  Some(
    "{\"window_id\":\{window_id},\"host_epoch\":\{host_epoch},\"session_epoch\":\{session_epoch},\"batch_sequence\":\{batch_sequence},\"accepted_revision\":\{accepted_revision},\"frame_revision\":\{frame_revision}}",
  )
}

///|
fn mac_acceptance_return_baseline_matches(
  committed_text : String,
  composing : Bool,
  commit_callbacks : Int,
  cancel_callbacks : Int,
) -> Bool {
  committed_text == "Hello " &&
  composing &&
  commit_callbacks == 0 &&
  cancel_callbacks == 0
}

///|
fn mac_acceptance_owner_sync_allows_progress(
  state : MacImeAcceptance,
  pending_owner_sync : Bool,
) -> Bool {
  !state.finished && !pending_owner_sync
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
    dispatch_trace_record_count: 0,
    dispatch_trace_truncated: false,
    operation_timeout_trace_emitted: false,
    operations: [],
    effect_observations: [],
    operation: None,
    frozen_dispatch_receipt: None,
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
fn mac_acceptance_diagnostic_int_json(value : Int?) -> String {
  match value {
    Some(number) => "\{number}"
    None => "null"
  }
}

///|
fn mac_acceptance_diagnostic_int64_json(value : Int64?) -> String {
  match value {
    Some(number) => "\{number}"
    None => "null"
  }
}

///|
// The raw receipt objects are preserved as independent JSON values only after
// validating their numeric/boolean-only native schema. Frame text and hashes
// are never copied into this diagnostic record.
fn mac_acceptance_timeout_snapshot_json(
  state : MacImeAcceptance,
  operation : MacAcceptanceOperation,
  owner : MacTextOwner?,
  field_revision : Int,
  composing : Bool,
  focused : Bool,
  dirty : Bool,
  pending_owner_sync : Bool,
  pending_ack_sequence : Int64?,
  current_receipt_status : Int,
  current_receipt : String?,
  current_frame_status : Int,
  current_frame_projection : String?,
) -> String {
  let frozen_receipt = match state.frozen_dispatch_receipt {
    Some(value) => mac_acceptance_diagnostic_receipt_json(value)
    None => None
  }
  let frozen_receipt_status = if state.frozen_dispatch_receipt is None {
    0
  } else if frozen_receipt is Some(_) {
    1
  } else {
    2
  }
  let current_receipt_json = match current_receipt {
    Some(value) => mac_acceptance_diagnostic_receipt_json(value)
    None => None
  }
  let current_receipt_status = if current_receipt_status == 1 &&
    current_receipt_json is Some(_) {
    1
  } else if current_receipt_status == 0 {
    0
  } else {
    2
  }
  let current_frame_projection = match current_frame_projection {
    Some(value) => value
    None => "null"
  }
  let last_accepted_sequence = mac_acceptance_diagnostic_int64_json(
    mac_acceptance_last_accepted_batch_sequence(state),
  )
  let (
    owner_active,
    owner_window,
    owner_host_epoch,
    owner_session_epoch,
    owner_last_sequence,
    owner_revision,
  ) = match owner {
    Some(value) =>
      (
        if value.active {
          "true"
        } else {
          "false"
        },
        "\{value.window.value()}",
        "\{value.host_epoch}",
        "\{value.epoch}",
        "\{value.last_sequence}",
        "\{value.revision}",
      )
    None => ("null", "null", "null", "null", "null", "null")
  }
  let (
    pending_batch_present,
    pending_batch_window,
    pending_batch_host_epoch,
    pending_batch_epoch,
    pending_batch_sequence,
    pending_batch_owner_revision,
  ) = match state.pending_batch {
    Some(batch) => {
      let target = batch.target()
      (
        "true",
        "\{target.window().value()}",
        "\{target.host_epoch()}",
        "\{target.epoch()}",
        "\{target.sequence()}",
        "\{target.owner_revision()}",
      )
    }
    None => ("false", "null", "null", "null", "null", "null")
  }
  let effect_index = mac_acceptance_diagnostic_int_json(operation.effect_index)
  let frozen_receipt_json = match frozen_receipt {
    Some(value) => value
    None => "null"
  }
  let current_receipt_json = match current_receipt_json {
    Some(value) if current_receipt_status == 1 => value
    _ => "null"
  }
  let current_frame_status = if current_frame_status == 1 &&
    current_frame_projection != "null" {
    1
  } else if current_frame_status == 0 {
    0
  } else {
    2
  }
  "{\"schema_version\":1,\"phase\":\"operation_timeout\",\"step\":\{operation.step},\"operation_id\":\{operation.id},\"dispatch_id\":\{operation.dispatch_id},\"key_code\":\{operation.key_code},\"loop_iterations\":\{operation.loop_iterations},\"iteration_limit\":\{MAC_ACCEPTANCE_OPERATION_ITERATION_LIMIT},\"baseline_batch_sequence\":\{operation.baseline_batch_sequence},\"baseline_accepted_revision\":\{operation.baseline_accepted_revision},\"baseline_frame_revision\":\{operation.baseline_frame_revision},\"baseline_preedit_callbacks\":\{operation.baseline_preedit_callbacks},\"baseline_commit_callbacks\":\{operation.baseline_commit_callbacks},\"baseline_cancel_callbacks\":\{operation.baseline_cancel_callbacks},\"baseline_composing\":\{operation.baseline_composing},\"effect_index\":\{effect_index},\"pending_batch\":\{pending_batch_present},\"pending_batch_window\":\{pending_batch_window},\"pending_batch_host_epoch\":\{pending_batch_host_epoch},\"pending_batch_session_epoch\":\{pending_batch_epoch},\"pending_batch_sequence\":\{pending_batch_sequence},\"pending_batch_owner_revision\":\{pending_batch_owner_revision},\"pending_preedit_callbacks\":\{state.pending_preedits},\"pending_commit_callbacks\":\{state.pending_commits},\"pending_cancel_callbacks\":\{state.pending_cancellations},\"preedit_callbacks\":\{state.preedit_callbacks},\"commit_callbacks\":\{state.commit_callbacks},\"cancel_callbacks\":\{state.cancel_callbacks},\"last_accepted_batch_sequence\":\{last_accepted_sequence},\"owner_active\":\{owner_active},\"owner_window\":\{owner_window},\"owner_host_epoch\":\{owner_host_epoch},\"owner_session_epoch\":\{owner_session_epoch},\"owner_last_sequence\":\{owner_last_sequence},\"owner_revision\":\{owner_revision},\"field_revision\":\{field_revision},\"composing\":\{composing},\"focused\":\{focused},\"dirty\":\{dirty},\"pending_owner_sync\":\{pending_owner_sync},\"pending_ack_sequence\":\{mac_acceptance_diagnostic_int64_json(pending_ack_sequence)},\"frozen_dispatch_receipt_status\":\{frozen_receipt_status},\"frozen_dispatch_receipt\":\{frozen_receipt_json},\"current_dispatch_receipt_status\":\{current_receipt_status},\"current_dispatch_receipt\":\{current_receipt_json},\"current_frame_identity_status\":\{current_frame_status},\"current_frame_identity\":\{current_frame_projection}}"
}

///|
fn mac_acceptance_operation_timeout_trace(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
  dirty : Bool,
  pending_owner_sync : Bool,
  pending_ack : @macos.TextSessionTarget?,
) -> MacImeAcceptance {
  if !mac_acceptance_diagnostic_enabled(
      state.enabled,
      state.started,
      @env.get_env_var("GPUI_FIELD_MACOS_IME_DISPATCH_TRACE"),
    ) ||
    state.operation_timeout_trace_emitted {
    return state
  }
  let operation = match state.operation {
    Some(value) => value
    None => return state
  }
  match owner {
    Some(active) if active.active &&
      active.window == window &&
      active.host_epoch == operation.host_epoch &&
      active.epoch == operation.session_epoch => ()
    _ => return state
  }
  let (current_receipt_status, current_receipt) = match
    host.testing_key_dispatch_receipt(window) {
    Ok(value) => (1, Some(value))
    Err(_) => (0, None)
  }
  let (current_frame_status, current_frame_projection) = match
    host.testing_frame_identity(window) {
    Ok(value) =>
      match mac_acceptance_diagnostic_frame_projection(value) {
        Some(projection) => (1, Some(projection))
        None => (2, None)
      }
    Err(_) => (0, None)
  }
  let pending_ack_sequence = match pending_ack {
    Some(target) => Some(target.sequence())
    None => None
  }
  let record = mac_acceptance_timeout_snapshot_json(
    state,
    operation,
    owner,
    field.revision(),
    field.is_composing(),
    field.is_focused(),
    dirty,
    pending_owner_sync,
    pending_ack_sequence,
    current_receipt_status,
    current_receipt,
    current_frame_status,
    current_frame_projection,
  )
  match
    mac_acceptance_diagnostic_next_record_count(
      state.dispatch_trace_record_count,
    ) {
    Some(next_count) => {
      println("GPUI_MACOS_IME_DIAGNOSTIC_TRACE \{record}")
      state_flush_stdout()
      {
        ..state,
        dispatch_trace_record_count: next_count,
        operation_timeout_trace_emitted: true,
      }
    }
    None => state
  }
}

///|
fn mac_acceptance_last_accepted_batch_sequence(
  state : MacImeAcceptance,
) -> Int64? {
  let mut last : Int64? = None
  for record in state.batches {
    if mac_acceptance_bool_field(record, "acknowledged") == Some(true) {
      last = mac_acceptance_int_field(record, "sequence")
    }
  }
  last
}

///|
// Diagnostic-only records contain fixed phase/kind labels and numeric,
// boolean, or null metadata. They deliberately omit field and callback text.
fn mac_acceptance_dispatch_trace(
  state : MacImeAcceptance,
  owner : MacTextOwner?,
  phase : String,
  kind : String,
  batch_sequence : Int64?,
  window_sequence : Int64?,
  pending_batch : Bool,
  commit_callback_count : Int,
  composing : Bool?,
  acknowledged : Bool?,
) -> MacImeAcceptance {
  if !mac_acceptance_diagnostic_enabled(
      state.enabled,
      state.started,
      @env.get_env_var("GPUI_FIELD_MACOS_IME_DISPATCH_TRACE"),
    ) {
    return state
  }
  match owner {
    Some(active) if active.active &&
      active.epoch == state.session_epoch &&
      active.host_epoch == state.host_epoch => ()
    _ => return state
  }
  if (
      phase != "observe" &&
      phase != "accepted_frame" &&
      phase != "receipt_ready" &&
      phase != "return_assert"
    ) ||
    (kind != "text_session" && kind != "return") {
    return state
  }
  if state.dispatch_trace_record_count >=
    MAC_ACCEPTANCE_DISPATCH_TRACE_ORDINARY_LIMIT {
    if state.dispatch_trace_truncated {
      return state
    }
    println(
      "GPUI_MACOS_IME_DISPATCH_TRACE {\"phase\":\"truncated\",\"kind\":\"record_limit\",\"session_epoch\":\{state.session_epoch},\"record_limit\":64}",
    )
    state_flush_stdout()
    return {
      ..state,
      dispatch_trace_record_count: state.dispatch_trace_record_count + 1,
      dispatch_trace_truncated: true,
    }
  }
  let key_code = if state.expected_dispatch_id > 0L {
    "\{state.expected_key_code}"
  } else {
    "null"
  }
  let accepted_sequence = match
    mac_acceptance_last_accepted_batch_sequence(state) {
    Some(value) => "\{value}"
    None => "null"
  }
  let batch_sequence = match batch_sequence {
    Some(value) => "\{value}"
    None => "null"
  }
  let window_sequence = match window_sequence {
    Some(value) => "\{value}"
    None => "null"
  }
  let composing = match composing {
    Some(value) => "\{value}"
    None => "null"
  }
  let acknowledged = match acknowledged {
    Some(value) => "\{value}"
    None => "null"
  }
  println(
    "GPUI_MACOS_IME_DISPATCH_TRACE {\"phase\":\"\{phase}\",\"kind\":\"\{kind}\",\"step\":\{state.step},\"session_epoch\":\{state.session_epoch},\"expected_dispatch_id\":\{state.expected_dispatch_id},\"key_code\":\{key_code},\"last_accepted_batch_sequence\":\{accepted_sequence},\"batch_sequence\":\{batch_sequence},\"window_sequence\":\{window_sequence},\"pending_batch\":\{pending_batch},\"commit_callback_count\":\{commit_callback_count},\"composing\":\{composing},\"acknowledged\":\{acknowledged}}",
  )
  state_flush_stdout()
  {
    ..state,
    dispatch_trace_record_count: state.dispatch_trace_record_count + 1,
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
fn mac_acceptance_operation_boundary(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
  step : Int,
  key_code : Int,
) -> MacAcceptanceOperation {
  if (step != 8 && step != 10) ||
    state.operation is Some(_) ||
    state.pending_batch is Some(_) ||
    !field.is_focused() {
    mac_acceptance_fail_owned(
      host, window, owner, state, "invalid IME operation observation boundary",
    )
  }
  let active = match owner {
    Some(value) if value.active => value
    _ =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "IME operation observation has no active owner",
      )
  }
  let generation = match host.generation() {
    Ok(value) => value
    Err(_) =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "IME operation host generation unavailable",
      )
  }
  let source = match host.testing_selected_input_source(window) {
    Ok(value) => value
    Err(_) =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "IME operation input source unavailable",
      )
  }
  let identity = match host.testing_frame_identity(window) {
    Ok(value) => value
    Err(_) =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "IME operation baseline frame unavailable",
      )
  }
  let baseline_batch_sequence = match
    mac_acceptance_int_field(identity, "batch_sequence") {
    Some(value) => value
    None =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "IME operation baseline omitted its batch sequence",
      )
  }
  let baseline_accepted_revision = match
    mac_acceptance_int_field(identity, "accepted_revision") {
    Some(value) => value
    None =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "IME operation baseline omitted its accepted revision",
      )
  }
  let baseline_frame_revision = match
    mac_acceptance_int_field(identity, "frame_revision") {
    Some(value) => value
    None =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "IME operation baseline omitted its frame revision",
      )
  }
  let accepted_sequence = match
    mac_acceptance_last_accepted_batch_sequence(state) {
    Some(value) => value
    None => 0L
  }
  if generation != state.host_epoch ||
    active.window != window ||
    active.host_epoch != state.host_epoch ||
    active.epoch != state.session_epoch ||
    active.last_sequence != baseline_batch_sequence ||
    active.revision != field.revision() ||
    baseline_batch_sequence != accepted_sequence ||
    baseline_accepted_revision != field.revision().to_int64() ||
    !mac_acceptance_valid_identity(identity) ||
    mac_acceptance_int_field(identity, "window_id") != Some(window.value()) ||
    mac_acceptance_int_field(identity, "host_epoch") != Some(state.host_epoch) ||
    mac_acceptance_int_field(identity, "session_epoch") !=
    Some(state.session_epoch.to_int64()) ||
    !mac_acceptance_source_is_kotoeri(source) ||
    source != state.input_source {
    mac_acceptance_fail_owned(
      host, window, owner, state, "IME operation boundary lost its accepted owner, frame, or Kotoeri source",
    )
  }
  if (
      step == 8 &&
      !mac_acceptance_return_baseline_matches(
        field.committed_document().text(),
        field.is_composing(),
        state.commit_callbacks,
        state.cancel_callbacks,
      )
    ) ||
    (
      step == 10 &&
      (
        state.commit_callbacks != 1 ||
        state.cancel_callbacks != 0 ||
        field.committed_document().text() != "Hello 日本語"
      )
    ) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "IME operation baseline did not contain the expected preceding accepted state",
    )
  }
  {
    id: state.operations.length() + 1,
    step,
    dispatch_id: 0L,
    key_code,
    window_id: window.value(),
    host_epoch: state.host_epoch,
    session_epoch: state.session_epoch,
    baseline_batch_index: state.batches.length(),
    baseline_batch_sequence,
    baseline_accepted_revision,
    baseline_frame_revision,
    baseline_preedit_callbacks: state.preedit_callbacks,
    baseline_commit_callbacks: state.commit_callbacks,
    baseline_cancel_callbacks: state.cancel_callbacks,
    baseline_composing: field.is_composing(),
    baseline_frame_identity: identity,
    loop_iterations: 0,
    effect_index: None,
    release_batch_index: None,
    release_batch_sequence: None,
    release_frame_revision: None,
    release_geometry_revision: None,
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
  field : @text_field.TextField,
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
  let mut prepared_state = { ..state, frozen_dispatch_receipt: None, }
  if step == 8 || step == 10 {
    let operation = mac_acceptance_operation_boundary(
      host,
      window,
      field,
      owner,
      state,
      step,
      key.code,
    )
    prepared_state = {
      ..state,
      operation: Some(operation),
      frozen_dispatch_receipt: None,
    }
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
        prepared_state,
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
        prepared_state,
        "could not read key dispatch receipt: \{error.operation()} \{error.code().label()}",
      )
  }
  let dispatch_id = match mac_acceptance_int_field(receipt, "dispatch_id") {
    Some(value) if value > prepared_state.expected_dispatch_id => value
    _ =>
      mac_acceptance_fail_owned(
        host, window, owner, prepared_state, "native key dispatch receipt did not advance",
      )
  }
  if mac_acceptance_int_field(receipt, "key_code") != Some(key.code.to_int64()) ||
    mac_acceptance_bool_field(receipt, "down_posted") != Some(true) ||
    mac_acceptance_bool_field(receipt, "up_posted") != Some(true) {
    mac_acceptance_fail_owned(
      host, window, owner, prepared_state, "native key dispatch receipt did not identify the posted key pair",
    )
  }
  let operation = match prepared_state.operation {
    Some(value) => Some({ ..value, dispatch_id, })
    None => None
  }
  {
    ..prepared_state,
    step,
    expected_dispatch_id: dispatch_id,
    expected_key_code: key.code,
    operation,
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
  mac_acceptance_post_step(host, window, field, Some(owner), ready, 0)
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
  let next_state = {
    ..state,
    pending_batch: Some(batch),
    pending_preedits: preedits,
    pending_commits: commits,
    pending_cancellations: cancellations,
  }
  if state.step == 8 {
    mac_acceptance_dispatch_trace(
      next_state,
      owner,
      "observe",
      "text_session",
      Some(batch.target().sequence()),
      None,
      true,
      commits,
      None,
      None,
    )
  } else {
    next_state
  }
}

///|
fn mac_acceptance_validate_operation_context(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
) -> Unit {
  match state.operation {
    None => ()
    Some(operation) => {
      let active = match owner {
        Some(value) if value.active => value
        _ =>
          mac_acceptance_fail_owned(
            host, window, owner, state, "IME operation observation lost its active owner",
          )
      }
      let generation = match host.generation() {
        Ok(value) => value
        Err(error) =>
          mac_acceptance_fail_owned(
            host,
            window,
            owner,
            state,
            "IME operation host generation unavailable: \{error.operation()} \{error.code().label()}",
          )
      }
      let source = match host.testing_selected_input_source(window) {
        Ok(value) => value
        Err(error) =>
          mac_acceptance_fail_owned(
            host,
            window,
            owner,
            state,
            "IME operation input source unavailable: \{error.operation()} \{error.code().label()}",
          )
      }
      if !field.is_focused() ||
        operation.window_id != window.value() ||
        operation.host_epoch != state.host_epoch ||
        operation.session_epoch != state.session_epoch ||
        operation.step != state.step ||
        operation.dispatch_id != state.expected_dispatch_id ||
        operation.key_code != state.expected_key_code ||
        active.window != window ||
        active.host_epoch != operation.host_epoch ||
        active.epoch != operation.session_epoch ||
        generation != operation.host_epoch ||
        !mac_acceptance_source_is_kotoeri(source) ||
        source != state.input_source {
        mac_acceptance_fail_owned(
          host, window, owner, state, "IME operation observation lost focus, owner, epoch, or Kotoeri source",
        )
      }
    }
  }
}

///|
fn mac_acceptance_cancel_effect_baseline_allows(
  baseline_composing : Bool,
  preedit_callback_delta : Int,
) -> Bool {
  baseline_composing || preedit_callback_delta > 0
}

///|
fn mac_acceptance_classify_operation_effect(
  operation : MacAcceptanceOperation,
  preedit_delta : Int,
  commit_delta : Int,
  cancel_delta : Int,
  pending_commits : Int,
  pending_cancellations : Int,
  committed_text : String,
  visible_text : String,
  composing : Bool,
) -> MacAcceptanceOperationEffect? {
  if commit_delta == 0 && cancel_delta == 0 {
    return Some(WaitingForCallbackEffect)
  }
  if visible_text != "Hello 日本語" ||
    committed_text != "Hello 日本語" ||
    composing {
    return None
  }
  if operation.step == 8 &&
    commit_delta == 1 &&
    cancel_delta == 0 &&
    pending_commits == 1 &&
    pending_cancellations == 0 {
    return Some(ReturnCommitEffect)
  }
  if operation.step == 10 &&
    commit_delta == 0 &&
    cancel_delta == 1 &&
    pending_commits == 0 &&
    pending_cancellations == 1 &&
    operation.baseline_commit_callbacks == 1 &&
    mac_acceptance_cancel_effect_baseline_allows(
      operation.baseline_composing,
      preedit_delta,
    ) {
    return Some(EscapeCancelEffect)
  }
  None
}

///|
fn mac_acceptance_release_geometry_revision_allows(
  owner_revision : Int64,
  accepted_revision : Int64,
  geometry_revision : Int?,
) -> Bool {
  if owner_revision == accepted_revision {
    geometry_revision is None
  } else {
    match geometry_revision {
      Some(value) =>
        accepted_revision > owner_revision &&
        value.to_int64() == accepted_revision
      None => false
    }
  }
}

///|
fn mac_acceptance_record_escape_release_ack(
  state : MacImeAcceptance,
  operation : MacAcceptanceOperation,
  batch : @macos.EditorBatch,
  identity : String,
  acknowledged : Bool,
  accepted_revision : Int64,
  pending_geometry_revision : Int?,
) -> MacAcceptanceOperation? {
  if operation.step != 10 ||
    operation.key_code != 53 ||
    operation.effect_index is None ||
    operation.release_batch_index is Some(_) ||
    operation.release_batch_sequence is Some(_) ||
    operation.release_frame_revision is Some(_) ||
    operation.release_geometry_revision is Some(_) ||
    !acknowledged ||
    state.pending_preedits != 0 ||
    state.pending_commits != 0 ||
    state.pending_cancellations != 0 ||
    state.commit_callbacks != operation.baseline_commit_callbacks ||
    state.cancel_callbacks != operation.baseline_cancel_callbacks + 1 {
    return None
  }
  let events = batch.events()
  let exact_release = if events.length() == 1 {
    match events[0] {
      @macos.ForwardedReleased(
        key_code=53,
        key=Some(@primitives.Escape),
        modifiers=_
      ) => true
      _ => false
    }
  } else {
    false
  }
  if !exact_release ||
    mac_acceptance_string_field(identity, "text") != Some("Hello 日本語") ||
    !mac_acceptance_valid_identity(identity) {
    return None
  }
  let pending_target = match state.pending_batch {
    Some(value) => value.target()
    None => return None
  }
  let target = batch.target()
  if pending_target.sequence() != target.sequence() ||
    pending_target.window() != target.window() ||
    pending_target.host_epoch() != target.host_epoch() ||
    pending_target.epoch() != target.epoch() {
    return None
  }
  let effect_index = match operation.effect_index {
    Some(value) => value
    None => return None
  }
  if effect_index < 0 || effect_index >= state.effect_observations.length() {
    return None
  }
  let effect = state.effect_observations[effect_index]
  let effect_batch_index = match
    mac_acceptance_int_field(effect, "batch_index") {
    Some(value) if value >= 0L => value.to_int()
    _ => return None
  }
  let effect_sequence = match
    mac_acceptance_int_field(effect, "batch_sequence") {
    Some(value) => value
    None => return None
  }
  let effect_frame_revision = match
    mac_acceptance_int_field(effect, "frame_revision") {
    Some(value) => value
    None => return None
  }
  if effect_batch_index + 1 != state.batches.length() ||
    effect_batch_index < 0 ||
    effect_batch_index >= state.batches.length() ||
    mac_acceptance_int_field(effect, "operation_id") !=
    Some(operation.id.to_int64()) ||
    mac_acceptance_string_field(effect, "kind") != Some("cancel") ||
    mac_acceptance_int_field(effect, "commit_callback_delta") != Some(0L) ||
    mac_acceptance_int_field(effect, "cancel_callback_delta") != Some(1L) {
    return None
  }
  let cancel_batch = state.batches[effect_batch_index]
  if mac_acceptance_bool_field(cancel_batch, "acknowledged") != Some(true) ||
    mac_acceptance_int_field(cancel_batch, "sequence") != Some(effect_sequence) ||
    mac_acceptance_int_field(cancel_batch, "cancel_callbacks") != Some(1L) ||
    mac_acceptance_int_field(cancel_batch, "commit_callbacks") != Some(0L) {
    return None
  }
  let release_sequence = target.sequence()
  let release_frame_revision = match
    mac_acceptance_int_field(identity, "frame_revision") {
    Some(value) => value
    None => return None
  }
  let release_geometry_revision = if target.owner_revision() ==
    accepted_revision {
    None
  } else {
    pending_geometry_revision
  }
  if target.window().value() != operation.window_id ||
    target.host_epoch() != operation.host_epoch ||
    target.epoch() != operation.session_epoch ||
    target.sequence() <= effect_sequence ||
    target.sequence() <= operation.baseline_batch_sequence ||
    target.owner_revision() < operation.baseline_accepted_revision ||
    !mac_acceptance_release_geometry_revision_allows(
      target.owner_revision(),
      accepted_revision,
      release_geometry_revision,
    ) ||
    accepted_revision < operation.baseline_accepted_revision ||
    mac_acceptance_int_field(identity, "window_id") != Some(operation.window_id) ||
    mac_acceptance_int_field(identity, "host_epoch") !=
    Some(operation.host_epoch) ||
    mac_acceptance_int_field(identity, "session_epoch") !=
    Some(operation.session_epoch.to_int64()) ||
    mac_acceptance_int_field(identity, "batch_sequence") !=
    Some(release_sequence) ||
    mac_acceptance_int_field(identity, "accepted_revision") !=
    Some(accepted_revision) ||
    release_frame_revision <= effect_frame_revision ||
    release_frame_revision <= operation.baseline_frame_revision {
    return None
  }
  Some({
    ..operation,
    release_batch_index: Some(state.batches.length()),
    release_batch_sequence: Some(release_sequence),
    release_frame_revision: Some(release_frame_revision),
    release_geometry_revision,
  })
}

///|
fn mac_acceptance_release_reference_present(
  operation : MacAcceptanceOperation,
) -> Bool {
  operation.release_batch_index is Some(_) &&
  operation.release_batch_sequence is Some(_) &&
  operation.release_frame_revision is Some(_)
}

///|
fn mac_acceptance_release_watermark_allows_completion(
  release_sequence : Int64,
  receipt_sequence : Int64,
  last_accepted_sequence : Int64,
) -> Bool {
  release_sequence <= last_accepted_sequence &&
  receipt_sequence <= last_accepted_sequence
}

///|
fn mac_acceptance_batch_sequence_is_acknowledged(
  state : MacImeAcceptance,
  sequence : Int64,
) -> Bool {
  if sequence == 0L {
    return true
  }
  for batch in state.batches {
    if mac_acceptance_bool_field(batch, "acknowledged") == Some(true) &&
      mac_acceptance_int_field(batch, "sequence") == Some(sequence) {
      return true
    }
  }
  false
}

///|
fn mac_acceptance_release_reference_is_acknowledged(
  state : MacImeAcceptance,
  operation : MacAcceptanceOperation,
) -> Bool {
  let batch_index = match operation.release_batch_index {
    Some(value) => value
    None => return false
  }
  let sequence = match operation.release_batch_sequence {
    Some(value) => value
    None => return false
  }
  let frame_revision = match operation.release_frame_revision {
    Some(value) => value
    None => return false
  }
  if operation.step != 10 ||
    operation.effect_index is None ||
    batch_index < 0 ||
    batch_index >= state.batches.length() {
    return false
  }
  let effect_index = match operation.effect_index {
    Some(value) => value
    None => return false
  }
  if effect_index < 0 || effect_index >= state.effect_observations.length() {
    return false
  }
  let effect = state.effect_observations[effect_index]
  let effect_batch_index = match
    mac_acceptance_int_field(effect, "batch_index") {
    Some(value) if value >= 0L => value.to_int()
    _ => return false
  }
  let effect_sequence = match
    mac_acceptance_int_field(effect, "batch_sequence") {
    Some(value) => value
    None => return false
  }
  let effect_frame_revision = match
    mac_acceptance_int_field(effect, "frame_revision") {
    Some(value) => value
    None => return false
  }
  let batch = state.batches[batch_index]
  let identity = match mac_acceptance_json_field(batch, "frame_identity") {
    Some(value) => value.stringify()
    None => return false
  }
  let owner_revision = match mac_acceptance_int_field(batch, "owner_revision") {
    Some(value) => value
    None => return false
  }
  let accepted_revision = match
    mac_acceptance_int_field(batch, "accepted_revision") {
    Some(value) => value
    None => return false
  }
  batch_index == effect_batch_index + 1 &&
  mac_acceptance_string_field(effect, "kind") == Some("cancel") &&
  mac_acceptance_bool_field(batch, "acknowledged") == Some(true) &&
  mac_acceptance_int_field(batch, "sequence") == Some(sequence) &&
  owner_revision >= operation.baseline_accepted_revision &&
  mac_acceptance_release_geometry_revision_allows(
    owner_revision,
    accepted_revision,
    operation.release_geometry_revision,
  ) &&
  mac_acceptance_int_field(identity, "accepted_revision") ==
  Some(accepted_revision) &&
  sequence > effect_sequence &&
  mac_acceptance_int_field(batch, "preedit_callbacks") == Some(0L) &&
  mac_acceptance_int_field(batch, "commit_callbacks") == Some(0L) &&
  mac_acceptance_int_field(batch, "cancel_callbacks") == Some(0L) &&
  mac_acceptance_valid_identity(identity) &&
  mac_acceptance_string_field(identity, "text") == Some("Hello 日本語") &&
  mac_acceptance_int_field(identity, "window_id") == Some(operation.window_id) &&
  mac_acceptance_int_field(identity, "host_epoch") == Some(operation.host_epoch) &&
  mac_acceptance_int_field(identity, "session_epoch") ==
  Some(operation.session_epoch.to_int64()) &&
  mac_acceptance_int_field(identity, "batch_sequence") == Some(sequence) &&
  mac_acceptance_int_field(identity, "frame_revision") == Some(frame_revision) &&
  frame_revision > effect_frame_revision
}

///|
fn mac_acceptance_record_operation_effect(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
  owner : MacTextOwner?,
  state : MacImeAcceptance,
  batch : @macos.EditorBatch,
  identity : String,
  acknowledged : Bool,
  pending_geometry_revision : Int?,
) -> MacImeAcceptance {
  match state.operation {
    None => state
    Some(operation) => {
      mac_acceptance_validate_operation_context(
        host, window, field, owner, state,
      )
      if operation.effect_index is Some(_) {
        match
          mac_acceptance_record_escape_release_ack(
            state,
            operation,
            batch,
            identity,
            acknowledged,
            field.revision().to_int64(),
            pending_geometry_revision,
          ) {
          Some(updated) => { ..state, operation: Some(updated), }
          None =>
            mac_acceptance_fail_owned(
              host, window, owner, state, "post-cancellation batch was not the exact acknowledged Escape release",
            )
        }
      } else {
        let target = batch.target()
        if operation.step != state.step ||
          !acknowledged ||
          state.pending_batch is None ||
          target.window() != window ||
          target.host_epoch() != operation.host_epoch ||
          target.epoch() != operation.session_epoch ||
          target.sequence() <= operation.baseline_batch_sequence ||
          target.owner_revision() < operation.baseline_accepted_revision ||
          mac_acceptance_int_field(identity, "window_id") !=
          Some(operation.window_id) ||
          mac_acceptance_int_field(identity, "host_epoch") !=
          Some(operation.host_epoch) ||
          mac_acceptance_int_field(identity, "session_epoch") !=
          Some(operation.session_epoch.to_int64()) ||
          mac_acceptance_int_field(identity, "batch_sequence") !=
          Some(target.sequence()) ||
          mac_acceptance_int_field(identity, "accepted_revision") !=
          Some(field.revision().to_int64()) ||
          mac_acceptance_int_field(identity, "frame_revision") is None ||
          !mac_acceptance_valid_identity(identity) {
          mac_acceptance_fail_owned(
            host, window, owner, state, "IME operation effect did not reference its exact acknowledged owner frame",
          )
        }
        let effect_frame_revision = match
          mac_acceptance_int_field(identity, "frame_revision") {
          Some(value) => value
          None =>
            mac_acceptance_fail_owned(
              host, window, owner, state, "IME operation effect frame omitted its revision",
            )
        }
        let preedit_delta = state.preedit_callbacks +
          state.pending_preedits -
          operation.baseline_preedit_callbacks
        let commit_delta = state.commit_callbacks +
          state.pending_commits -
          operation.baseline_commit_callbacks
        let cancel_delta = state.cancel_callbacks +
          state.pending_cancellations -
          operation.baseline_cancel_callbacks
        let accepted_revision_is_current = match
          mac_acceptance_int_field(identity, "accepted_revision") {
          Some(revision) => revision >= operation.baseline_accepted_revision
          None => false
        }
        if effect_frame_revision <= operation.baseline_frame_revision ||
          !accepted_revision_is_current ||
          preedit_delta < 0 ||
          commit_delta < 0 ||
          cancel_delta < 0 {
          mac_acceptance_fail_owned(
            host, window, owner, state, "IME operation effect moved its accepted frame or callback baseline backwards",
          )
        }
        let effect_kind = match
          mac_acceptance_classify_operation_effect(
            operation,
            preedit_delta,
            commit_delta,
            cancel_delta,
            state.pending_commits,
            state.pending_cancellations,
            field.committed_document().text(),
            mac_acceptance_string_field(identity, "text").unwrap_or(""),
            field.is_composing(),
          ) {
          Some(WaitingForCallbackEffect) => return state
          Some(ReturnCommitEffect) => "commit"
          Some(EscapeCancelEffect) => "cancel"
          None =>
            mac_acceptance_fail_owned(
              host, window, owner, state, "IME operation observed a duplicate, wrong, or out-of-scope callback",
            )
        }
        let batch_index = state.batches.length()
        let effect_index = state.effect_observations.length()
        let effect = "{\"schema_version\":1,\"operation_id\":\{operation.id},\"kind\":\"\{effect_kind}\",\"causal_origin\":\"unknown\",\"origin_dispatch_id\":null,\"batch_index\":\{batch_index},\"batch_sequence\":\{target.sequence()},\"window_id\":\{window.value()},\"host_epoch\":\{operation.host_epoch},\"session_epoch\":\{operation.session_epoch},\"owner_revision\":\{target.owner_revision()},\"accepted_revision\":\{field.revision()},\"frame_revision\":\{effect_frame_revision},\"preedit_callback_delta\":\{preedit_delta},\"commit_callback_delta\":\{commit_delta},\"cancel_callback_delta\":\{cancel_delta},\"frame_identity\":\{identity}}"
        let effect_observations = state.effect_observations.copy()
        effect_observations.push(effect)
        {
          ..state,
          effect_observations,
          operation: Some({ ..operation, effect_index: Some(effect_index), }),
        }
      }
    }
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
  pending_geometry_revision : Int?,
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
      if state.step == 8 {
        next_state = mac_acceptance_dispatch_trace(
          next_state,
          owner,
          "accepted_frame",
          "text_session",
          Some(batch.target().sequence()),
          None,
          true,
          state.commit_callbacks + state.pending_commits,
          Some(field.is_composing()),
          Some(acknowledged),
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
      next_state = mac_acceptance_record_operation_effect(
        host, window, field, owner, next_state, batch, identity, acknowledged, pending_geometry_revision,
      )
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
  mac_acceptance_validate_operation_context(host, window, field, owner, state)
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
    mac_acceptance_int_field(receipt, "session_epoch") !=
    Some(state.session_epoch.to_int64()) ||
    mac_acceptance_int_field(receipt, "batch_sequence") is None ||
    mac_acceptance_int_field(receipt, "window_sequence") is None ||
    mac_acceptance_bool_field(receipt, "down_posted") != Some(true) ||
    mac_acceptance_bool_field(receipt, "up_posted") != Some(true) {
    mac_acceptance_fail_owned(
      host, window, owner, state, "key dispatch receipt changed identity or omitted a posted event",
    )
  }
  match state.frozen_dispatch_receipt {
    Some(frozen) if frozen != receipt =>
      mac_acceptance_fail_owned(
        host, window, owner, state, "native dispatch-completion receipt changed after it was frozen",
      )
    _ => ()
  }
  let down = mac_acceptance_bool_field(receipt, "down_dispatched") == Some(true)
  let up = mac_acceptance_bool_field(receipt, "up_dispatched") == Some(true)
  if !down || !up {
    return { state, field, owner, dirty: false, }
  }
  let mut next_state = state
  if state.frozen_dispatch_receipt is None {
    if state.receipts.length() != state.step {
      mac_acceptance_fail_owned(
        host, window, owner, state, "native dispatch receipt arrived out of the expected 11-key order",
      )
    }
    next_state = {
      ..state,
      receipts: state.receipts.copy(),
      frozen_dispatch_receipt: Some(receipt),
    }
    next_state.receipts.push(receipt)
  } else if state.receipts.length() != state.step + 1 ||
    state.receipts[state.step] != receipt {
    mac_acceptance_fail_owned(
      host, window, owner, state, "frozen native dispatch receipt did not remain in its ordered slot",
    )
  }
  if state.step == 8 && state.frozen_dispatch_receipt is None {
    next_state = mac_acceptance_dispatch_trace(
      next_state,
      owner,
      "receipt_ready",
      "return",
      mac_acceptance_int_field(receipt, "batch_sequence"),
      mac_acceptance_int_field(receipt, "window_sequence"),
      state.pending_batch is Some(_),
      state.commit_callbacks + state.pending_commits,
      Some(field.is_composing()),
      None,
    )
  }
  let completed_step = next_state.step
  let operation = next_state.operation
  if next_state.pending_batch is Some(_) {
    match operation {
      Some(_) => return { state: next_state, field, owner, dirty: false, }
      None =>
        mac_acceptance_fail_owned(
          host, window, owner, next_state, "native dispatched key-up before its text batch was accepted",
        )
    }
  }
  match operation {
    Some(active) => {
      if active.dispatch_id != next_state.expected_dispatch_id ||
        active.step != completed_step {
        mac_acceptance_fail_owned(
          host, window, owner, next_state, "IME operation boundary did not match its dispatch",
        )
      }
      match active.effect_index {
        None => {
          let baseline_state_valid = if active.step == 8 {
            mac_acceptance_return_baseline_matches(
              field.committed_document().text(),
              field.is_composing(),
              next_state.commit_callbacks,
              next_state.cancel_callbacks,
            ) &&
            active.baseline_commit_callbacks == 0 &&
            active.baseline_cancel_callbacks == 0 &&
            next_state.commit_callbacks == active.baseline_commit_callbacks &&
            next_state.cancel_callbacks == active.baseline_cancel_callbacks
          } else {
            active.baseline_commit_callbacks == 1 &&
            active.baseline_cancel_callbacks == 0 &&
            next_state.commit_callbacks == active.baseline_commit_callbacks &&
            next_state.cancel_callbacks == active.baseline_cancel_callbacks &&
            field.committed_document().text() == "Hello 日本語"
          }
          if !baseline_state_valid {
            mac_acceptance_fail_owned(
              host,
              window,
              owner,
              next_state,
              if active.step == 8 {
                "Return did not accept exactly one 日本語 commit"
              } else {
                "Escape did not cancel the follow-up composition"
              },
            )
          }
          return { state: next_state, field, owner, dirty: false, }
        }
        Some(effect_index) => {
          if effect_index < 0 ||
            effect_index >= next_state.effect_observations.length() {
            mac_acceptance_fail_owned(
              host, window, owner, next_state, "IME operation referenced a missing effect record",
            )
          }
          let effect_state_valid = if active.step == 8 {
            next_state.commit_callbacks == active.baseline_commit_callbacks + 1 &&
            next_state.cancel_callbacks == active.baseline_cancel_callbacks &&
            field.committed_document().text() == "Hello 日本語" &&
            !field.is_composing()
          } else {
            next_state.commit_callbacks == active.baseline_commit_callbacks &&
            next_state.cancel_callbacks == active.baseline_cancel_callbacks + 1 &&
            field.committed_document().text() == "Hello 日本語" &&
            !field.is_composing()
          }
          if !effect_state_valid {
            mac_acceptance_fail_owned(
              host,
              window,
              owner,
              next_state,
              if active.step == 8 {
                "Return did not accept exactly one 日本語 commit"
              } else {
                "Escape did not cancel the follow-up composition"
              },
            )
          }
          if active.step == 10 {
            if !mac_acceptance_release_reference_present(active) {
              return { state: next_state, field, owner, dirty: false, }
            }
            if !mac_acceptance_release_reference_is_acknowledged(
                next_state, active,
              ) {
              mac_acceptance_fail_owned(
                host, window, owner, next_state, "Escape release reference did not match its exact accepted batch",
              )
            }
            let receipt_sequence = match
              mac_acceptance_int_field(receipt, "batch_sequence") {
              Some(value) => value
              None =>
                mac_acceptance_fail_owned(
                  host, window, owner, next_state, "Escape receipt omitted its batch watermark",
                )
            }
            let last_accepted_sequence = match
              mac_acceptance_last_accepted_batch_sequence(next_state) {
              Some(value) => value
              None => 0L
            }
            let release_sequence = match active.release_batch_sequence {
              Some(value) => value
              None =>
                mac_acceptance_fail_owned(
                  host, window, owner, next_state, "Escape release reference omitted its sequence",
                )
            }
            if !mac_acceptance_batch_sequence_is_acknowledged(
                next_state, receipt_sequence,
              ) ||
              !mac_acceptance_release_watermark_allows_completion(
                release_sequence, receipt_sequence, last_accepted_sequence,
              ) {
              return { state: next_state, field, owner, dirty: false, }
            }
          }
          let operation_kind = if active.step == 8 {
            "return_commit_observation"
          } else {
            "escape_cancel_observation"
          }
          let release_kind = if active.step == 10 {
            "\"forwarded_escape_release\""
          } else {
            "null"
          }
          let release_key_code = if active.step == 10 { "53" } else { "null" }
          let release_batch_index = match active.release_batch_index {
            Some(value) => "\{value}"
            None => "null"
          }
          let release_batch_sequence = match active.release_batch_sequence {
            Some(value) => "\{value}"
            None => "null"
          }
          let release_frame_revision = match active.release_frame_revision {
            Some(value) => "\{value}"
            None => "null"
          }
          let release_geometry_revision = match
            active.release_geometry_revision {
            Some(value) => "\{value}"
            None => "null"
          }
          let operation_record = "{\"schema_version\":2,\"operation_id\":\{active.id},\"kind\":\"\{operation_kind}\",\"scope\":\"serial_post_dispatch_observation\",\"causal_origin\":\"unknown\",\"origin_dispatch_id\":null,\"dispatch_id\":\{active.dispatch_id},\"key_code\":\{active.key_code},\"dispatch_receipt_index\":\{completed_step},\"window_id\":\{active.window_id},\"host_epoch\":\{active.host_epoch},\"session_epoch\":\{active.session_epoch},\"baseline_batch_index\":\{active.baseline_batch_index},\"baseline_batch_sequence\":\{active.baseline_batch_sequence},\"baseline_accepted_revision\":\{active.baseline_accepted_revision},\"baseline_frame_revision\":\{active.baseline_frame_revision},\"baseline_preedit_callbacks\":\{active.baseline_preedit_callbacks},\"baseline_commit_callbacks\":\{active.baseline_commit_callbacks},\"baseline_cancel_callbacks\":\{active.baseline_cancel_callbacks},\"baseline_composing\":\{active.baseline_composing},\"baseline_frame_identity\":\{active.baseline_frame_identity},\"loop_iterations\":\{active.loop_iterations},\"effect_index\":\{effect_index},\"release_kind\":\{release_kind},\"release_key_code\":\{release_key_code},\"release_batch_index\":\{release_batch_index},\"release_batch_sequence\":\{release_batch_sequence},\"release_frame_revision\":\{release_frame_revision},\"release_geometry_revision\":\{release_geometry_revision}}"
          let operations = next_state.operations.copy()
          operations.push(operation_record)
          next_state = {
            ..next_state,
            operations,
            operation: None,
            frozen_dispatch_receipt: None,
          }
        }
      }
    }
    None =>
      if completed_step == 8 || completed_step == 10 {
        mac_acceptance_fail_owned(
          host, window, owner, next_state, "IME operation boundary was not retained",
        )
      }
  }
  if completed_step == 8 {
    next_state = mac_acceptance_dispatch_trace(
      next_state,
      owner,
      "return_assert",
      "return",
      mac_acceptance_int_field(receipt, "batch_sequence"),
      mac_acceptance_int_field(receipt, "window_sequence"),
      next_state.pending_batch is Some(_),
      next_state.commit_callbacks + next_state.pending_commits,
      Some(field.is_composing()),
      None,
    )
  }
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
      field,
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
    state.operations.length() != 2 ||
    state.effect_observations.length() != 2 ||
    state.operation is Some(_) ||
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
  let mut operation_records = ""
  for index, record in state.operations {
    if index > 0 {
      operation_records += ","
    }
    operation_records += record
  }
  let mut effect_records = ""
  for index, record in state.effect_observations {
    if index > 0 {
      effect_records += ","
    }
    effect_records += record
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
  let output = "GPUI_MACOS_IME_ACCEPTANCE {\"schema_version\":2,\"window_id\":\{window.value()},\"host_epoch\":\{state.host_epoch},\"session_epoch\":\{state.session_epoch},\"final_session_epoch\":\{final_session_epoch},\"input_source\":\{source},\"preedit_callbacks\":\{state.preedit_callbacks},\"commit_callbacks\":\{state.commit_callbacks},\"cancel_callbacks\":\{state.cancel_callbacks},\"committed_text\":\{committed_text},\"composing\":false,\"focused\":false,\"commit_count\":\{commit_count},\"batches\":[\{batch_records}],\"receipts\":[\{receipt_records}],\"operations\":[\{operation_records}],\"effect_observations\":[\{effect_records}],\"candidate_screen_rect\":\{state.candidate_screen_rect},\"field_bounds\":\{field_bounds_json(field)},\"final_frame_identity\":\{identity},\"final_frame_revision\":\{final_frame_revision},\"source_revision\":\{source_revision},\"source_tree\":\{source_tree},\"binary_sha256\":\{binary_sha256}}"
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
