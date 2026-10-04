///|
fn migration_test_capability(
  service : @host_services.Service,
  state : @host_services.CapabilityState,
) -> @host_services.ServiceCapability {
  @host_services.ServiceCapability::new(service, state)
}

///|
fn migration_test_bridge(
  capabilities : Array[@host_services.ServiceCapability],
) -> @host_services.ServiceBridge {
  match @host_services.ServiceBridge::new(capabilities) {
    Ok(bridge) => bridge
    Err(_) => abort("valid migration host-service configuration rejected")
  }
}

///|
fn migration_test_deep_value(depth : Int) -> @capability.Value {
  let mut value = @capability.StringValue("leaf")
  for _ in 0..<depth {
    value = @capability.ArrayValue([value])
  }
  value
}

///|
fn migration_test_large_text(length : Int) -> String {
  let builder = StringBuilder()
  for _ in 0..<length {
    builder.write_char('x')
  }
  builder.to_string()
}

///|
test "host services deny ungranted operations and expose requirement state" {
  let denied = migration_test_bridge([])
  let denied_scope = match denied.new_scope() {
    Ok(scope) => scope
    Err(_) => abort("logical service scope allocation failed")
  }
  assert_true(
    denied.request(
      denied_scope,
      @host_services.ClipboardReadText,
      @capability.UnitValue,
    )
    is Err(_),
  )
  assert_true(denied.take_requests().length() == 0)

  let browser = migration_test_bridge([
    migration_test_capability(
      @host_services.Clipboard,
      @host_services.RequiresUserGesture,
    ),
  ])
  assert_true(
    browser.capability_state(@host_services.Clipboard)
    is @host_services.RequiresUserGesture,
  )
  let scope = match browser.new_scope() {
    Ok(value) => value
    Err(_) => abort("logical service scope allocation failed")
  }
  ignore(
    browser.request(
      scope,
      @host_services.ClipboardWriteText,
      @capability.StringValue("copied by the host"),
    ),
  )
  let requests = browser.take_requests()
  assert_true(requests.length() == 1)
  assert_eq(
    requests[0].canonical_json(),
    "{\"version\":1,\"requestId\":\"1\",\"scopeId\":\"1\",\"operation\":\"clipboard.write_text\",\"input\":\"copied by the host\"}",
  )
  assert_true(browser.take_requests().length() == 0)
  browser.close()
}

///|
test "host-service values are copied across async requests" {
  let bridge = migration_test_bridge([
    migration_test_capability(
      @host_services.PersistentStorage,
      @host_services.Available,
    ),
  ])
  let scope = match bridge.new_scope() {
    Ok(value) => value
    Err(_) => abort("logical service scope allocation failed")
  }
  let nested : Array[@capability.Value] = [
    @capability.ObjectValue([("before", @capability.BoolValue(true))]),
  ]
  let payload = @capability.ArrayValue(nested)
  ignore(bridge.request(scope, @host_services.StorageWrite, payload))
  match nested[0] {
    @capability.ObjectValue(fields) =>
      fields[0] = ("after", @capability.BoolValue(false))
    _ => abort("test payload unexpectedly changed shape")
  }

  let request = bridge.take_requests()[0]
  assert_eq(request.input().canonical_json(), "[{\"before\":true}]")
  assert_true(
    bridge.complete(request.id(), scope, Ok(@capability.StringValue("stored"))),
  )
  let completions = bridge.drain_completions()
  assert_true(completions.length() == 1)
  match completions[0].result() {
    Ok(value) => assert_eq(value.canonical_json(), "\"stored\"")
    Err(_) => abort("successful host completion returned an error")
  }
  assert_true(!bridge.complete(request.id(), scope, Ok(@capability.UnitValue)))
}

///|
test "host-service ingress validates values before cloning or serialization" {
  let bridge = migration_test_bridge([
    migration_test_capability(
      @host_services.PersistentStorage,
      @host_services.Available,
    ),
  ])
  let scope = match bridge.new_scope() {
    Ok(value) => value
    Err(_) => abort("logical service scope allocation failed")
  }
  let invalid_inputs : Array[@capability.Value] = [
    @capability.NumberValue(0.0 / 0.0),
    @capability.ObjectValue([
      ("duplicate", @capability.UnitValue),
      ("duplicate", @capability.BoolValue(true)),
    ]),
    migration_test_deep_value(40),
    @capability.StringValue(migration_test_large_text(1_048_577)),
  ]
  for input in invalid_inputs {
    assert_true(
      bridge.request(scope, @host_services.StorageWrite, input) is Err(_),
    )
  }
  assert_true(bridge.pending_count() == 0)
  assert_true(bridge.take_requests().length() == 0)

  let prefix = "{\"version\":1,\"requestId\":\"1\",\"scopeId\":\"1\",\"operation\":\"storage.write\",\"input\":"
  let exact_input_length = 1_048_576 - prefix.length() - 3
  let request_id = match
    bridge.request(
      scope,
      @host_services.StorageWrite,
      @capability.StringValue(migration_test_large_text(exact_input_length)),
    ) {
    Ok(value) => value
    Err(_) => abort("request at the full-envelope transport limit rejected")
  }
  let outbound = bridge.take_requests()
  assert_true(outbound.length() == 1)
  assert_true(outbound[0].canonical_json().length() == 1_048_576)
  assert_true(
    bridge.request(
      scope,
      @host_services.StorageWrite,
      @capability.StringValue(migration_test_large_text(exact_input_length + 1)),
    )
    is Err(_),
  )
  assert_true(
    !bridge.complete(
      request_id,
      scope,
      Ok(@capability.StringValue(migration_test_large_text(1_048_577))),
    ),
  )
  assert_true(bridge.pending_count() == 1)
  assert_true(bridge.completion_count() == 0)
  assert_true(
    bridge.complete(request_id, scope, Ok(@capability.StringValue("ready"))),
  )
  assert_true(bridge.drain_completions().length() == 1)
}

///|
test "host-service completions cannot outlive their logical scope" {
  let bridge = migration_test_bridge([
    migration_test_capability(
      @host_services.Clipboard,
      @host_services.Available,
    ),
  ])
  let old_scope = match bridge.new_scope() {
    Ok(value) => value
    Err(_) => abort("logical service scope allocation failed")
  }
  let id = match
    bridge.request(
      old_scope,
      @host_services.ClipboardReadText,
      @capability.UnitValue,
    ) {
    Ok(value) => value
    Err(_) => abort("granted clipboard request rejected")
  }
  assert_true(bridge.destroy_scope(old_scope))
  let new_scope = match bridge.new_scope() {
    Ok(value) => value
    Err(_) => abort("new logical service scope allocation failed")
  }
  assert_true(new_scope.value() > old_scope.value())
  assert_true(
    !bridge.complete(id, old_scope, Ok(@capability.StringValue("stale"))),
  )
  assert_true(bridge.take_requests().length() == 0)
  assert_true(bridge.drain_completions().length() == 0)
  assert_true(bridge.pending_count() == 0)
}

///|
test "duplicate host service capability declarations are invalid" {
  assert_true(
    @host_services.ServiceBridge::new([
      migration_test_capability(@host_services.Shell, @host_services.Available),
      migration_test_capability(
        @host_services.Shell,
        @host_services.Unavailable,
      ),
    ])
    is Err(_),
  )
}
