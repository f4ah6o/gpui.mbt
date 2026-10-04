///|
fn[T] assert_owner_stale(result : Result[T, @mcp.AdapterError]) -> Unit raise {
  match result {
    Err(error) => assert_true(error.code() is @mcp.Stale)
    Ok(_) => fail("owner shutdown must reject adapter access")
  }
}

///|
fn mcp_owned_registry(app : @core.App) -> @capability.Registry raise {
  match @capability.Registry::new_owned(app) {
    Ok(registry) => registry
    Err(_) => fail("live app should own a registry")
  }
}

///|
test "app stop rejects all MCP entry paths and cached outcomes before request conflicts" {
  let app = running_mcp_app()
  let registry = mcp_owned_registry(app)
  let executions = Ref(0)
  let command = @capability.TypedCapability::new(
    mcp_command_descriptor("owner.command", @capability.External),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  let query = @capability.TypedCapability::new(
    mcp_query_descriptor("owner.query"),
    _value => Ok(()),
    value => Ok(@capability.Value::int(value)),
    _value => {
      executions.val += 1
      Ok(9)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  assert_true(registry.register(command) is Ok(_))
  assert_true(registry.register(query) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)
  assert_true(
    adapter.call_tool_with_request_id(
      "cached",
      "owner_command",
      @capability.Value::int(7),
    )
    is Ok(@capability.IntValue(7)),
  )
  assert_true(
    adapter.call_tool_with_request_id(
      "cached",
      "owner_command",
      @capability.Value::int(7),
    )
    is Ok(@capability.IntValue(7)),
  )
  assert_true(executions.val == 1)
  assert_true(app.request_stop() is Ok(_))
  assert_true(app.request_stop() is Ok(_))
  assert_owner_stale(adapter.inventory())
  assert_owner_stale(
    adapter.call_tool("owner_command", @capability.Value::int(7)),
  )
  assert_owner_stale(adapter.read_resource("gpui://capability/owner_query"))
  assert_owner_stale(
    adapter.call_tool_with_request_id(
      "cached",
      "owner_command",
      @capability.Value::int(7),
    ),
  )
  assert_owner_stale(
    adapter.call_tool_with_request_id(
      "cached",
      "owner_command",
      @capability.Value::int(8),
    ),
  )
  assert_owner_stale(
    adapter.call_tool_with_request_id(
      "new",
      "owner_command",
      @capability.Value::int(7),
    ),
  )
  assert_owner_stale(
    adapter.call_tool_with_request_id("", "unknown", @capability.Value::int(7)),
  )
  assert_true(executions.val == 1)
}

///|
test "cache replay rejects owner stop inside authorization without returning retained output" {
  for stop_in_policy in [false, true] {
    let app = running_mcp_app()
    let registry = mcp_owned_registry(app)
    let executions = Ref(0)
    let stop_on_check = Ref(false)
    let maybe_stop = fn(policy : Bool) {
      if stop_on_check.val && policy == stop_in_policy {
        ignore(app.request_stop())
      }
      Ok(())
    }
    let command = @capability.TypedCapability::new(
      mcp_command_descriptor("owner.cached", @capability.External),
      value => value.as_int(),
      value => Ok(@capability.Value::int(value)),
      value => {
        executions.val += 1
        Ok(value)
      },
      () => maybe_stop(false),
      _origin => maybe_stop(true),
    )
    assert_true(registry.register(command) is Ok(_))
    let adapter = @mcp.Adapter::new(registry)
    assert_true(
      adapter.call_tool_with_request_id(
        "cached",
        "owner_cached",
        @capability.Value::int(3),
      )
      is Ok(_),
    )
    stop_on_check.val = true
    assert_owner_stale(
      adapter.call_tool_with_request_id(
        "cached",
        "owner_cached",
        @capability.Value::int(3),
      ),
    )
    assert_owner_stale(
      adapter.call_tool_with_request_id(
        "cached",
        "owner_cached",
        @capability.Value::int(3),
      ),
    )
    assert_true(executions.val == 1)
  }
}

///|
test "in-flight owner stop rejects nested retries and late success or domain failure" {
  for fail_after_stop in [false, true] {
    let app = running_mcp_app()
    let registry = mcp_owned_registry(app)
    let adapter = @mcp.Adapter::new(registry)
    let executions = Ref(0)
    let nested_same : Ref[@mcp.ErrorCode?] = Ref(None)
    let nested_changed : Ref[@mcp.ErrorCode?] = Ref(None)
    let command = @capability.TypedCapability::new(
      mcp_command_descriptor("owner.inflight", @capability.External),
      value => value.as_int(),
      value => Ok(@capability.Value::int(value)),
      value => {
        executions.val += 1
        ignore(app.request_stop())
        ignore(app.request_stop())
        match
          adapter.call_tool_with_request_id(
            "active",
            "owner_inflight",
            @capability.Value::int(value),
          ) {
          Err(error) => nested_same.val = Some(error.code())
          Ok(_) => ()
        }
        match
          adapter.call_tool_with_request_id(
            "active",
            "owner_inflight",
            @capability.Value::int(value + 1),
          ) {
          Err(error) => nested_changed.val = Some(error.code())
          Ok(_) => ()
        }
        if fail_after_stop {
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "private late error",
            ),
          )
        } else {
          Ok(value)
        }
      },
      () => Ok(()),
      _origin => Ok(()),
    )
    assert_true(registry.register(command) is Ok(_))
    assert_owner_stale(
      adapter.call_tool_with_request_id(
        "active",
        "owner_inflight",
        @capability.Value::int(4),
      ),
    )
    assert_true(nested_same.val is Some(@mcp.Stale))
    assert_true(nested_changed.val is Some(@mcp.Stale))
    assert_owner_stale(
      adapter.call_tool_with_request_id(
        "active",
        "owner_inflight",
        @capability.Value::int(4),
      ),
    )
    assert_true(executions.val == 1)
  }
}

///|
test "uncached tool and resource completions are rejected when owner stops in handler" {
  for resource in [false, true] {
    let app = running_mcp_app()
    let registry = mcp_owned_registry(app)
    let executions = Ref(0)
    let command = @capability.TypedCapability::new(
      mcp_command_descriptor("owner.tool", @capability.External),
      value => value.as_int(),
      value => Ok(@capability.Value::int(value)),
      value => {
        executions.val += 1
        ignore(app.request_stop())
        Ok(value)
      },
      () => Ok(()),
      _origin => Ok(()),
    )
    let query = @capability.TypedCapability::new(
      mcp_query_descriptor("owner.resource"),
      _value => Ok(()),
      value => Ok(@capability.Value::int(value)),
      _value => {
        executions.val += 1
        ignore(app.request_stop())
        Ok(2)
      },
      () => Ok(()),
      _origin => Ok(()),
    )
    assert_true(registry.register(command) is Ok(_))
    assert_true(registry.register(query) is Ok(_))
    let adapter = @mcp.Adapter::new(registry)
    if resource {
      assert_owner_stale(
        adapter.read_resource("gpui://capability/owner_resource"),
      )
    } else {
      assert_owner_stale(
        adapter.call_tool("owner_tool", @capability.Value::int(1)),
      )
    }
    assert_true(executions.val == 1)
  }
}

///|
test "MCP owner readiness gates new calls and cached replay after adoption" {
  for adopt_existing in [false, true] {
    let app = match @core.App::new() {
      Ok(app) => app
      Err(_) => fail("app allocation should succeed")
    }
    let registry = if adopt_existing {
      @capability.Registry::new()
    } else {
      mcp_owned_registry(app)
    }
    let executions = Ref(0)
    let command = @capability.TypedCapability::new(
      mcp_command_descriptor("owner.readiness", @capability.External),
      value => value.as_int(),
      value => Ok(@capability.Value::int(value)),
      value => {
        executions.val += 1
        Ok(value)
      },
      () => Ok(()),
      _origin => Ok(()),
    )
    assert_true(registry.register(command) is Ok(_))
    let adapter = @mcp.Adapter::new(registry)
    if adopt_existing {
      assert_true(
        adapter.call_tool_with_request_id(
          "ready",
          "owner_readiness",
          @capability.Value::int(6),
        )
        is Ok(@capability.IntValue(6)),
      )
      assert_true(registry.attach_owner(app) is Ok(_))
      match
        adapter.call_tool_with_request_id(
          "ready",
          "owner_readiness",
          @capability.Value::int(6),
        ) {
        Err(error) => assert_true(error.code() is @mcp.Unavailable)
        Ok(_) => fail("cached output must await the adopted owner's start")
      }
    }
    match adapter.call_tool("owner_readiness", @capability.Value::int(6)) {
      Err(error) => assert_true(error.code() is @mcp.Unavailable)
      Ok(_) => fail("new owner cannot execute MCP calls")
    }
    assert_true(executions.val == (if adopt_existing { 1 } else { 0 }))
    assert_true(app.start() is Ok(_))
    assert_true(
      adapter.call_tool_with_request_id(
        "ready",
        "owner_readiness",
        @capability.Value::int(6),
      )
      is Ok(@capability.IntValue(6)),
    )
    assert_true(executions.val == 1)
    assert_true(app.request_stop() is Ok(_))
    assert_owner_stale(
      adapter.call_tool_with_request_id(
        "ready",
        "owner_readiness",
        @capability.Value::int(6),
      ),
    )
    assert_true(executions.val == 1)
  }
}
