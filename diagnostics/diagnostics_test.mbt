///|
fn repeated_text(character : Char, count : Int) -> String {
  let builder = StringBuilder()
  for _ in 0..<count {
    builder.write_char(character)
  }
  builder.to_string()
}

///|
fn scalar_count(text : String) -> Int {
  let mut count = 0
  for _ in text {
    count += 1
  }
  count
}

///|
test "framework error keeps only logical identity and stable bounded context" {
  let error = @diagnostics.FrameworkError::new(
    @diagnostics.ErrorCode::EntityNotLive,
    "entity_update",
    app_id=7,
    entity_id=11,
    window_id=13,
    task_id=19,
    subsystem="core",
    backend="headless",
    message="entity has been destroyed",
  )
  assert_true(error.code() is @diagnostics.ErrorCode::EntityNotLive)
  assert_true(error.operation() == "entity_update")
  assert_true(error.app_id() == Some(7))
  assert_true(error.entity_id() == Some(11))
  assert_true(error.window_id() == Some(13))
  assert_true(error.task_id() == Some(19))
  assert_true(error.subsystem() == Some("core"))
  assert_true(error.backend() == Some("headless"))
  assert_true(error.message() == Some("entity has been destroyed"))
  assert_true(@diagnostics.ErrorCode::DeviceLost.label() == "device_lost")
}

///|
test "error text caps count Unicode scalars and mark truncation" {
  let exact = @diagnostics.FrameworkError::new(
    @diagnostics.ErrorCode::InvalidInput,
    repeated_text('🙂', 96),
    message=repeated_text('界', 256),
  )
  assert_true(scalar_count(exact.operation()) == 96)
  assert_true(scalar_count(exact.message().unwrap()) == 256)
  assert_true(exact.operation().has_suffix("🙂"))
  assert_true(exact.message().unwrap().has_suffix("界"))

  let over = @diagnostics.FrameworkError::new(
    @diagnostics.ErrorCode::InvalidInput,
    repeated_text('🙂', 97),
    message=repeated_text('界', 257),
  )
  assert_true(scalar_count(over.operation()) == 96)
  assert_true(scalar_count(over.message().unwrap()) == 256)
  assert_true(over.operation().has_suffix("…"))
  assert_true(over.message().unwrap().has_suffix("…"))

  let bounded_context = @diagnostics.FrameworkError::new(
    @diagnostics.ErrorCode::NativeFailure,
    "draw",
    subsystem=repeated_text('s', 49),
    backend=repeated_text('🙂', 49),
  )
  assert_true(scalar_count(bounded_context.subsystem().unwrap()) == 48)
  assert_true(scalar_count(bounded_context.backend().unwrap()) == 48)
  assert_true(bounded_context.subsystem().unwrap().has_suffix("…"))
  assert_true(bounded_context.backend().unwrap().has_suffix("…"))
}

///|
test "diagnostic sink is bounded fifo and counters include evicted records" {
  let sink = match @diagnostics.DiagnosticSink::new(2) {
    Ok(value) => value
    Err(_) => fail("capacity two must create a sink")
  }
  sink.record(
    @diagnostics.FrameworkError::new(@diagnostics.ErrorCode::WrongApp, "first"),
  )
  sink.record(
    @diagnostics.FrameworkError::new(
      @diagnostics.ErrorCode::EntityNotLive,
      "second",
    ),
  )
  sink.record(
    @diagnostics.FrameworkError::new(@diagnostics.ErrorCode::WrongApp, "third"),
  )

  let entries = sink.snapshot()
  assert_true(entries.length() == 2)
  match (entries.get(0), entries.get(1)) {
    (Some(first), Some(second)) => {
      assert_true(first.error().operation() == "second")
      assert_true(second.error().operation() == "third")
    }
    _ => fail("full sink snapshot must contain two entries")
  }
  ignore(entries.remove(0))
  assert_true(sink.snapshot().length() == 2)
  assert_true(sink.count(@diagnostics.ErrorCode::WrongApp) == 2)
  assert_true(sink.count(@diagnostics.ErrorCode::EntityNotLive) == 1)
  assert_true(sink.total_count() == 3)
  assert_true(sink.dropped_count() == 1)
}

///|
test "diagnostic sink rejects capacities outside its fixed bound" {
  assert_true(
    @diagnostics.DiagnosticSink::new(0)
    is Err(@diagnostics.SinkConfigError::CapacityOutOfRange(0)),
  )
  assert_true(
    @diagnostics.DiagnosticSink::new(257)
    is Err(@diagnostics.SinkConfigError::CapacityOutOfRange(257)),
  )
  assert_true(@diagnostics.DiagnosticSink::new(1) is Ok(_))
  assert_true(@diagnostics.DiagnosticSink::new(256) is Ok(_))
}
