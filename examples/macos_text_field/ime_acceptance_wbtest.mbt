///|
test "Return baseline requires the accepted Hello space composition" {
  assert_true(mac_acceptance_return_baseline_matches("Hello ", true, 0, 0))
  assert_false(mac_acceptance_return_baseline_matches("Hello", true, 0, 0))
  assert_false(mac_acceptance_return_baseline_matches("Hello ", false, 0, 0))
  assert_false(mac_acceptance_return_baseline_matches("Hello ", true, 1, 0))
  assert_false(mac_acceptance_return_baseline_matches("Hello ", true, 0, 1))
}

///|
test "diagnostic traces require the explicit gate and reserve one terminal record" {
  assert_true(mac_acceptance_diagnostic_enabled(true, true, Some("1")))
  assert_false(mac_acceptance_diagnostic_enabled(false, true, Some("1")))
  assert_false(mac_acceptance_diagnostic_enabled(true, false, Some("1")))
  assert_false(mac_acceptance_diagnostic_enabled(true, true, Some("true")))
  assert_eq(mac_acceptance_diagnostic_next_record_count(0), Some(1))
  assert_eq(mac_acceptance_diagnostic_next_record_count(62), Some(63))
  assert_eq(mac_acceptance_diagnostic_next_record_count(63), Some(64))
  assert_true(mac_acceptance_diagnostic_next_record_count(64) is None)
  assert_true(mac_acceptance_diagnostic_next_record_count(-1) is None)
}

///|
test "timeout diagnostics preserve numeric receipts and project frame identity" {
  let frozen_receipt = "{\"schema_version\":1,\"dispatch_id\":3,\"key_code\":36,\"down_posted\":true,\"up_posted\":true,\"down_dispatched\":true,\"up_dispatched\":true,\"host_epoch\":8,\"session_epoch\":2,\"batch_sequence\":10,\"window_sequence\":10}"
  let current_receipt = "{\"schema_version\":1,\"dispatch_id\":4,\"key_code\":36,\"down_posted\":true,\"up_posted\":true,\"down_dispatched\":true,\"up_dispatched\":true,\"host_epoch\":8,\"session_epoch\":2,\"batch_sequence\":11,\"window_sequence\":11}"
  let frame_identity = "{\"schema_version\":1,\"window_id\":5,\"host_epoch\":8,\"session_epoch\":2,\"batch_sequence\":11,\"accepted_revision\":9,\"frame_revision\":17,\"frame_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"text\":\"private body\"}"
  assert_eq(
    mac_acceptance_diagnostic_receipt_json(frozen_receipt),
    Some(frozen_receipt),
  )
  assert_true(
    mac_acceptance_diagnostic_receipt_json(
      "{\"schema_version\":1,\"dispatch_id\":3,\"key_code\":36,\"down_posted\":true,\"up_posted\":true,\"down_dispatched\":true,\"up_dispatched\":true,\"host_epoch\":8,\"session_epoch\":2,\"batch_sequence\":10,\"window_sequence\":10,\"text\":\"private body\"}",
    )
    is None,
  )
  assert_true(
    mac_acceptance_diagnostic_receipt_json(
      "{\"schema_version\":1,\"dispatch_id\":3,\"key_code\":36,\"down_posted\":true,\"up_posted\":\"yes\",\"down_dispatched\":true,\"up_dispatched\":true,\"host_epoch\":8,\"session_epoch\":2,\"batch_sequence\":10,\"window_sequence\":10}",
    )
    is None,
  )
  let projection = match
    mac_acceptance_diagnostic_frame_projection(frame_identity) {
    Some(value) => value
    None => "null"
  }
  assert_eq(
    projection, "{\"window_id\":5,\"host_epoch\":8,\"session_epoch\":2,\"batch_sequence\":11,\"accepted_revision\":9,\"frame_revision\":17}",
  )
  assert_false(projection.contains("private body"))
  assert_false(projection.contains("frame_sha256"))
  let operation : MacAcceptanceOperation = {
    id: 1,
    step: 8,
    dispatch_id: 3L,
    key_code: 36,
    window_id: 5L,
    host_epoch: 8L,
    session_epoch: 2,
    baseline_batch_index: 0,
    baseline_batch_sequence: 9L,
    baseline_accepted_revision: 8L,
    baseline_frame_revision: 16L,
    baseline_preedit_callbacks: 1,
    baseline_commit_callbacks: 0,
    baseline_cancel_callbacks: 0,
    baseline_composing: true,
    baseline_frame_identity: frame_identity,
    loop_iterations: 200,
    effect_index: None,
    release_batch_index: None,
    release_batch_sequence: None,
    release_frame_revision: None,
    release_geometry_revision: None,
  }
  let state = {
    ..mac_acceptance_new(true),
    started: true,
    step: 8,
    session_epoch: 2,
    host_epoch: 8L,
    frozen_dispatch_receipt: Some(frozen_receipt),
    operation: Some(operation),
  }
  let snapshot = mac_acceptance_timeout_snapshot_json(
    state,
    operation,
    None,
    9,
    true,
    true,
    false,
    false,
    Some(11L),
    1,
    Some(current_receipt),
    1,
    Some(projection),
  )
  assert_true(mac_acceptance_parse(snapshot) is Some(_))
  assert_eq(mac_acceptance_int_field(snapshot, "step"), Some(8L))
  assert_eq(
    mac_acceptance_int_field(snapshot, "frozen_dispatch_receipt_status"),
    Some(1L),
  )
  assert_eq(
    mac_acceptance_int_field(snapshot, "current_dispatch_receipt_status"),
    Some(1L),
  )
  assert_eq(mac_acceptance_int_field(snapshot, "field_revision"), Some(9L))
  assert_true(
    snapshot.contains(
      "\"frozen_dispatch_receipt\":{\"schema_version\":1,\"dispatch_id\":3",
    ),
  )
  assert_true(
    snapshot.contains(
      "\"current_dispatch_receipt\":{\"schema_version\":1,\"dispatch_id\":4",
    ),
  )
  assert_false(snapshot.contains("private body"))
  assert_false(snapshot.contains("frame_sha256"))
}

///|
test "Escape cancel permits a new interval preedit only when it is observed" {
  assert_true(mac_acceptance_cancel_effect_baseline_allows(true, 0))
  assert_true(mac_acceptance_cancel_effect_baseline_allows(false, 1))
  assert_false(mac_acceptance_cancel_effect_baseline_allows(false, 0))
}

///|
test "operation recorder waits through preedit then records only the exact Escape cancellation" {
  let operation : MacAcceptanceOperation = {
    id: 2,
    step: 10,
    dispatch_id: 11L,
    key_code: 53,
    window_id: 24L,
    host_epoch: 43L,
    session_epoch: 9,
    baseline_batch_index: 1,
    baseline_batch_sequence: 8L,
    baseline_accepted_revision: 12L,
    baseline_frame_revision: 28L,
    baseline_preedit_callbacks: 2,
    baseline_commit_callbacks: 1,
    baseline_cancel_callbacks: 0,
    baseline_composing: false,
    baseline_frame_identity: "{}",
    loop_iterations: 7,
    effect_index: None,
    release_batch_index: None,
    release_batch_sequence: None,
    release_frame_revision: None,
    release_geometry_revision: None,
  }
  assert_true(
    mac_acceptance_classify_operation_effect(
      operation, 1, 0, 0, 0, 0, "Hello 日本語", "Hello 日本語n", true,
    ) ==
    Some(WaitingForCallbackEffect),
  )
  assert_true(
    mac_acceptance_classify_operation_effect(
      operation, 1, 0, 1, 0, 1, "Hello 日本語", "Hello 日本語", false,
    ) ==
    Some(EscapeCancelEffect),
  )
  assert_true(
    mac_acceptance_classify_operation_effect(
      operation, 1, 0, 1, 0, 1, "Hello 日本語", "Hello WRONG", false,
    )
    is None,
  )
  assert_true(
    mac_acceptance_classify_operation_effect(
      operation, 0, 0, 1, 0, 1, "Hello 日本語", "Hello 日本語", false,
    )
    is None,
  )
}

///|
test "Escape release ACK is a separate exact zero-callback batch" {
  let window = @platform.WindowId::new(24)
  let baseline_identity = "{\"schema_version\":1,\"window_id\":24,\"host_epoch\":43,\"session_epoch\":9,\"batch_sequence\":8,\"accepted_revision\":12,\"frame_revision\":28,\"frame_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"text\":\"Hello 日本語\"}"
  let cancel_identity = "{\"schema_version\":1,\"window_id\":24,\"host_epoch\":43,\"session_epoch\":9,\"batch_sequence\":9,\"accepted_revision\":12,\"frame_revision\":29,\"frame_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"text\":\"Hello 日本語\"}"
  let release_identity = "{\"schema_version\":1,\"window_id\":24,\"host_epoch\":43,\"session_epoch\":9,\"batch_sequence\":10,\"accepted_revision\":12,\"frame_revision\":30,\"frame_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"text\":\"Hello 日本語\"}"
  let baseline_batch = "{\"sequence\":8,\"acknowledged\":true,\"preedit_callbacks\":2,\"commit_callbacks\":1,\"cancel_callbacks\":0,\"frame_identity\":\{baseline_identity}}"
  let cancel_batch = "{\"sequence\":9,\"acknowledged\":true,\"preedit_callbacks\":0,\"commit_callbacks\":0,\"cancel_callbacks\":1,\"frame_identity\":\{cancel_identity}}"
  let release_batch_record = "{\"sequence\":10,\"owner_revision\":12,\"accepted_revision\":12,\"acknowledged\":true,\"preedit_callbacks\":0,\"commit_callbacks\":0,\"cancel_callbacks\":0,\"frame_identity\":\{release_identity}}"
  let cancel_effect = "{\"schema_version\":1,\"operation_id\":2,\"kind\":\"cancel\",\"causal_origin\":\"unknown\",\"origin_dispatch_id\":null,\"batch_index\":1,\"batch_sequence\":9,\"window_id\":24,\"host_epoch\":43,\"session_epoch\":9,\"owner_revision\":12,\"accepted_revision\":12,\"frame_revision\":29,\"preedit_callback_delta\":0,\"commit_callback_delta\":0,\"cancel_callback_delta\":1,\"frame_identity\":\{cancel_identity}}"
  let modifiers = owner_test_modifiers()
  let batch : @macos.EditorBatch = {
    target: {
      window,
      host_epoch: 43L,
      epoch: 9,
      sequence: 10L,
      owner_revision: 12L,
    },
    events: [
      @macos.ForwardedReleased(
        key_code=53,
        key=Some(@primitives.Escape),
        modifiers~,
      ),
    ],
  }
  let operation : MacAcceptanceOperation = {
    id: 2,
    step: 10,
    dispatch_id: 11L,
    key_code: 53,
    window_id: 24L,
    host_epoch: 43L,
    session_epoch: 9,
    baseline_batch_index: 1,
    baseline_batch_sequence: 8L,
    baseline_accepted_revision: 12L,
    baseline_frame_revision: 28L,
    baseline_preedit_callbacks: 2,
    baseline_commit_callbacks: 1,
    baseline_cancel_callbacks: 0,
    baseline_composing: true,
    baseline_frame_identity: baseline_identity,
    loop_iterations: 7,
    effect_index: Some(0),
    release_batch_index: None,
    release_batch_sequence: None,
    release_frame_revision: None,
    release_geometry_revision: None,
  }
  let state = {
    ..mac_acceptance_new(true),
    started: true,
    step: 10,
    expected_dispatch_id: 11L,
    expected_key_code: 53,
    host_epoch: 43L,
    session_epoch: 9,
    input_source: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
    preedit_callbacks: 2,
    commit_callbacks: 1,
    cancel_callbacks: 1,
    batches: [baseline_batch, cancel_batch],
    effect_observations: [cancel_effect],
    operation: Some(operation),
    pending_batch: Some(batch),
  }
  let recorded = mac_acceptance_record_escape_release_ack(
    state,
    operation,
    batch,
    release_identity,
    true,
    12L,
    None,
  )
  match recorded {
    Some(value) => {
      assert_eq(value.release_batch_index, Some(2))
      assert_eq(value.release_batch_sequence, Some(10L))
      assert_eq(value.release_frame_revision, Some(30L))
      assert_eq(value.release_geometry_revision, None)
      assert_true(mac_acceptance_release_reference_present(value))
      assert_false(
        mac_acceptance_release_watermark_allows_completion(10L, 10L, 9L),
      )
      assert_false(
        mac_acceptance_release_watermark_allows_completion(10L, 11L, 10L),
      )
      assert_true(
        mac_acceptance_release_watermark_allows_completion(10L, 9L, 10L),
      )
      let acknowledged = {
        ..state,
        batches: [baseline_batch, cancel_batch, release_batch_record],
      }
      assert_true(
        mac_acceptance_batch_sequence_is_acknowledged(acknowledged, 10L),
      )
      assert_false(
        mac_acceptance_batch_sequence_is_acknowledged(acknowledged, 7L),
      )
      assert_false(
        mac_acceptance_batch_sequence_is_acknowledged(acknowledged, 11L),
      )
      assert_true(
        mac_acceptance_release_reference_is_acknowledged(acknowledged, value),
      )
      assert_eq(state.effect_observations[0], cancel_effect)
      assert_true(
        mac_acceptance_record_escape_release_ack(
          state,
          value,
          batch,
          release_identity,
          true,
          12L,
          None,
        )
        is None,
      )
    }
    None => assert_true(false)
  }
  let wrong_key : @macos.EditorBatch = {
    ..batch,
    events: [
      @macos.ForwardedReleased(
        key_code=36,
        key=Some(@primitives.Escape),
        modifiers~,
      ),
    ],
  }
  assert_true(
    mac_acceptance_record_escape_release_ack(
      state,
      operation,
      wrong_key,
      release_identity,
      true,
      12L,
      None,
    )
    is None,
  )
  let multiple : @macos.EditorBatch = {
    ..batch,
    events: [
      @macos.ForwardedReleased(
        key_code=53,
        key=Some(@primitives.Escape),
        modifiers~,
      ),
      @macos.ForwardedReleased(
        key_code=53,
        key=Some(@primitives.Escape),
        modifiers~,
      ),
    ],
  }
  assert_true(
    mac_acceptance_record_escape_release_ack(
      state,
      operation,
      multiple,
      release_identity,
      true,
      12L,
      None,
    )
    is None,
  )
  assert_true(
    mac_acceptance_record_escape_release_ack(
      state,
      operation,
      batch,
      release_identity,
      false,
      12L,
      None,
    )
    is None,
  )
  assert_true(
    mac_acceptance_record_escape_release_ack(
      { ..state, pending_commits: 1, },
      operation,
      batch,
      release_identity,
      true,
      12L,
      None,
    )
    is None,
  )
  let stale : @macos.EditorBatch = {
    ..batch,
    target: { ..batch.target(), sequence: 9L, },
  }
  assert_true(
    mac_acceptance_record_escape_release_ack(
      state,
      operation,
      stale,
      release_identity,
      true,
      12L,
      None,
    )
    is None,
  )
  let wrong_session = "{\"schema_version\":1,\"window_id\":24,\"host_epoch\":43,\"session_epoch\":8,\"batch_sequence\":10,\"accepted_revision\":12,\"frame_revision\":30,\"frame_sha256\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"text\":\"Hello 日本語\"}"
  assert_true(
    mac_acceptance_record_escape_release_ack(
      state,
      operation,
      batch,
      wrong_session,
      true,
      12L,
      None,
    )
    is None,
  )
  let wrong_text = "{\"schema_version\":1,\"window_id\":24,\"host_epoch\":43,\"session_epoch\":9,\"batch_sequence\":10,\"accepted_revision\":12,\"frame_revision\":30,\"frame_sha256\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"text\":\"Hello WRONG\"}"
  assert_true(
    mac_acceptance_record_escape_release_ack(
      state,
      operation,
      batch,
      wrong_text,
      true,
      12L,
      None,
    )
    is None,
  )
}

///|
test "Mac acceptance waits for the blurred final frame before finishing" {
  if mac_owner_coretext_tests_available() {
    let state = { ..mac_acceptance_new(true), started: true, step: 11, }
    let field = make_field("Hello 日本語", owner_test_rect())
      .unwrap()
      .with_focus(true)
      .unwrap()
    let blurred_field = field.with_focus(false).unwrap()
    let escape_keyup = {
      state,
      field: blurred_field,
      owner: None,
      dirty: true,
    }
    assert_false(mac_acceptance_final_frame_ready(escape_keyup))
    assert_true(
      mac_acceptance_final_frame_ready({ ..escape_keyup, dirty: false, }),
    )
  }
}

///|
test "Mac owner geometry sync defers Busy only until the text batch ACK" {
  let busy = @diagnostics.FrameworkError::new(@diagnostics.Busy, "sync")
  let failed = @diagnostics.FrameworkError::new(
    @diagnostics.NativeFailure,
    "sync",
  )
  assert_true(mac_owner_sync_should_defer(busy, false))
  assert_false(mac_owner_sync_should_defer(busy, true))
  assert_false(mac_owner_sync_should_defer(failed, false))
}

///|
test "Mac IME operation wait has one saturating main-loop iteration budget" {
  let operation : MacAcceptanceOperation = {
    id: 1,
    step: 8,
    dispatch_id: 9L,
    key_code: 36,
    window_id: 3L,
    host_epoch: 11L,
    session_epoch: 7,
    baseline_batch_index: 1,
    baseline_batch_sequence: 4L,
    baseline_accepted_revision: 12L,
    baseline_frame_revision: 24L,
    baseline_preedit_callbacks: 1,
    baseline_commit_callbacks: 0,
    baseline_cancel_callbacks: 0,
    baseline_composing: true,
    baseline_frame_identity: "{}",
    loop_iterations: 0,
    effect_index: None,
    release_batch_index: None,
    release_batch_sequence: None,
    release_frame_revision: None,
    release_geometry_revision: None,
  }
  let waiting = { ..mac_acceptance_new(true), operation: Some(operation), }
  assert_false(mac_acceptance_operation_timed_out(waiting))
  let first_iteration = mac_acceptance_tick_operation_iteration(waiting)
  match first_iteration.operation {
    Some(value) => assert_eq(value.loop_iterations, 1)
    None => assert_true(false)
  }
  let last_allowed = {
    ..waiting,
    operation: Some({ ..operation, loop_iterations: 199, }),
  }
  let deadline = mac_acceptance_tick_operation_iteration(last_allowed)
  assert_true(mac_acceptance_operation_timed_out(deadline))
  match deadline.operation {
    Some(value) => assert_eq(value.loop_iterations, 200)
    None => assert_true(false)
  }
  let saturated = mac_acceptance_tick_operation_iteration(deadline)
  match saturated.operation {
    Some(value) => assert_eq(value.loop_iterations, 200)
    None => assert_true(false)
  }
  assert_false(mac_acceptance_operation_timed_out(mac_acceptance_new(true)))
}
