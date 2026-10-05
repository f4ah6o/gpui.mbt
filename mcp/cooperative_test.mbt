///|
fn[T] cooperative_ok(result : Result[T, @mcp.AdapterError]) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
fn cooperative_fixture(
  started : Ref[Int],
  effects : Ref[Int],
) -> (@capability.Registry, @mcp.Adapter) {
  let registry = @capability.Registry::new()
  let operation = @capability.AsyncCapability::new(
    mcp_command_descriptor("async.add", @capability.External),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => Ok(value),
    _ => Ok(()),
    _ => Ok(()),
    value => {
      started.val += 1
      let left = Ref(value)
      Ok(() => {
        if left.val > 0 {
          left.val -= 1
          effects.val += 1
          @capability.Pending
        } else {
          @capability.Complete(effects.val)
        }
      })
    },
    () => Ok(()),
    _ => Ok(()),
  )
  ignore(registry.register_async(operation))
  (registry, @mcp.Adapter::new(registry))
}

///|
test "cooperative tools use complete semantic discovery without advertising a synchronous wire path" {
  let started = Ref(0)
  let effects = Ref(0)
  let (registry, adapter) = cooperative_fixture(started, effects)
  assert_eq(registry.descriptors().length(), 1)
  assert_eq(registry.external_descriptors().length(), 1)
  assert_true(registry.is_async("async.add"))
  assert_true(!registry.is_async("missing"))
  assert_eq(cooperative_ok(adapter.inventory()).tools().length(), 0)
  assert_eq(cooperative_ok(adapter.cooperative_inventory()).tools().length(), 1)
  assert_true(
    adapter.call_tool("async_add", @capability.Value::int(2)) is Err(_),
  )
  assert_true(
    registry.invoke("async.add", @capability.Direct, @capability.Value::int(2))
    is Err(_),
  )
  assert_eq(started.val, 0)
  let call = cooperative_ok(
    adapter.begin_tool("async_add", @capability.Value::int(2)),
  )
  assert_true(call.poll() is @mcp.Pending)
  assert_eq(started.val, 1)
  assert_eq(effects.val, 0)
  assert_true(call.poll() is @mcp.Pending)
  assert_eq(effects.val, 1)
  assert_true(call.poll() is @mcp.Pending)
  assert_eq(effects.val, 2)
  assert_true(call.poll() is @mcp.Ready(@capability.IntValue(2)))
  assert_true(call.poll() is @mcp.Consumed)
  assert_true(call.cancel() is @capability.TooLate)
  assert_eq(started.val, 1)
  assert_eq(effects.val, 2)
}

///|
test "cooperative adapter cancellation releases admission capacity and close suppresses future steps" {
  let started = Ref(0)
  let effects = Ref(0)
  let (_, adapter) = cooperative_fixture(started, effects)
  let calls : Array[@mcp.CooperativeCall] = []
  for _ in 0..<128 {
    calls.push(
      cooperative_ok(adapter.begin_tool("async_add", @capability.Value::int(2))),
    )
  }
  assert_true(
    adapter.begin_tool("async_add", @capability.Value::int(2)) is Err(_),
  )
  assert_true(calls[0].cancel() is @capability.Cancelled)
  assert_true(calls[0].cancel() is @capability.AlreadyCancelled)
  assert_true(calls[0].poll() is @mcp.Cancelled)
  let running = cooperative_ok(
    adapter.begin_tool("async_add", @capability.Value::int(2)),
  )
  assert_true(running.poll() is @mcp.Pending)
  assert_true(running.poll() is @mcp.Pending)
  assert_eq(effects.val, 1)
  adapter.close()
  adapter.close()
  for call in calls {
    match call.poll() {
      @mcp.Failed(error) => assert_true(error.code() is @mcp.AdapterClosed)
      _ => fail("closed")
    }
  }
  assert_true(running.poll() is @mcp.Failed(_))
  assert_eq(started.val, 1)
  assert_eq(effects.val, 1)
  assert_true(adapter.cooperative_inventory() is Err(_))
}

///|
test "cooperative adapter close after commit preserves effect but skips output callbacks" {
  for close_in in ["step", "validator", "encoder"] {
    let registry = @capability.Registry::new()
    let adapter = @mcp.Adapter::new(registry)
    let effects = Ref(0)
    let validated = Ref(0)
    let encoded = Ref(0)
    let operation = @capability.AsyncCapability::new(
      mcp_command_descriptor("async.close", @capability.External),
      value => value.as_int(),
      value => {
        encoded.val += 1
        if close_in == "encoder" {
          adapter.close()
        }
        Ok(@capability.Value::int(value))
      },
      value => Ok(value),
      _ => Ok(()),
      _ => {
        validated.val += 1
        if close_in == "validator" {
          adapter.close()
        }
        Ok(())
      },
      value => {
        Ok(() => {
          effects.val += 1
          if close_in == "step" {
            adapter.close()
          }
          @capability.Complete(value)
        })
      },
      () => Ok(()),
      _ => Ok(()),
    )
    assert_true(registry.register_async(operation) is Ok(_))
    let call = cooperative_ok(
      adapter.begin_tool("async_close", @capability.Value::int(2)),
    )
    assert_true(call.poll() is @mcp.Pending)
    match call.poll() {
      @mcp.Failed(error) => assert_true(error.code() is @mcp.AdapterClosed)
      _ => fail("close must reject completion")
    }
    assert_eq(effects.val, 1)
    assert_eq(validated.val, if close_in == "step" { 0 } else { 1 })
    assert_eq(encoded.val, if close_in == "encoder" { 1 } else { 0 })
    assert_true(call.poll() is @mcp.Failed(_))
    assert_eq(effects.val, 1)
  }
}

///|
test "cooperative query resources share the registry and owner revocation" {
  let app = running_mcp_app()
  let registry = mcp_owned_registry(app)
  let reads = Ref(0)
  let query = @capability.AsyncCapability::new(
    mcp_query_descriptor("async.read"),
    _ => Ok(()),
    value => Ok(@capability.Value::int(value)),
    value => Ok(value),
    _ => Ok(()),
    _ => Ok(()),
    _ => {
      Ok(() => {
        reads.val += 1
        @capability.Complete(7)
      })
    },
    () => Ok(()),
    _ => Ok(()),
  )
  assert_true(registry.register_async(query) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)
  assert_eq(cooperative_ok(adapter.inventory()).resources().length(), 0)
  assert_eq(
    cooperative_ok(adapter.cooperative_inventory()).resources().length(),
    1,
  )
  assert_true(
    adapter.begin_tool("async_read", @capability.Value::unit()) is Err(_),
  )
  let call = cooperative_ok(
    adapter.begin_resource("gpui://capability/async_read"),
  )
  assert_true(call.poll() is @mcp.Pending)
  assert_true(call.poll() is @mcp.Ready(@capability.IntValue(7)))
  let pending = cooperative_ok(
    adapter.begin_resource("gpui://capability/async_read"),
  )
  ignore(app.request_stop())
  for stale in [call, pending] {
    match stale.poll() {
      @mcp.Failed(error) => assert_true(error.code() is @mcp.Stale)
      _ => fail("stale")
    }
  }
  assert_eq(reads.val, 1)
}

///|
test "cooperative adapter admission is reserved before reentrant snapshot and close prevents factory" {
  for close in [false, true] {
    let registry = @capability.Registry::new()
    let adapter = @mcp.Adapter::new(registry)
    let snapshotting = Ref(false)
    let rejected = Ref(0)
    let started = Ref(0)
    let retained : Array[@mcp.CooperativeCall] = []
    let operation = @capability.AsyncCapability::new(
      mcp_command_descriptor("async.reserve", @capability.External),
      value => value.as_int(),
      value => Ok(@capability.Value::int(value)),
      value => {
        if !snapshotting.val {
          snapshotting.val = true
          for _ in 0..<128 {
            match
              adapter.begin_tool("async_reserve", @capability.Value::int(1)) {
              Ok(call) => retained.push(call)
              Err(_) => rejected.val += 1
            }
          }
          if close {
            adapter.close()
          }
        }
        Ok(value)
      },
      _ => Ok(()),
      _ => Ok(()),
      value => {
        started.val += 1
        Ok(() => @capability.Complete(value))
      },
      () => Ok(()),
      _ => Ok(()),
    )
    assert_true(registry.register_async(operation) is Ok(_))
    let outer = adapter.begin_tool("async_reserve", @capability.Value::int(1))
    assert_eq(rejected.val, 1)
    assert_eq(retained.length(), 127)
    assert_eq(started.val, 0)
    if close {
      match outer {
        Err(error) => assert_true(error.code() is @mcp.AdapterClosed)
        Ok(_) => fail("closed during admission")
      }
      for call in retained {
        assert_true(call.poll() is @mcp.Failed(_))
      }
      assert_eq(started.val, 0)
    } else {
      ignore(cooperative_ok(outer).cancel())
      for call in retained {
        ignore(call.cancel())
      }
      assert_true(
        adapter.begin_tool("async_reserve", @capability.Value::int(1)) is Ok(_),
      )
    }
  }
}

///|
test "cooperative adapter reentrant poll is busy and denial suppresses errors and projection" {
  let registry = @capability.Registry::new()
  let adapter = @mcp.Adapter::new(registry)
  let handle : Ref[@mcp.CooperativeCall?] = Ref(None)
  let allowed = Ref(true)
  let busy = Ref(0)
  let encoded = Ref(0)
  let operation = @capability.AsyncCapability::new(
    mcp_command_descriptor("async.reenter", @capability.External),
    value => value.as_int(),
    value => {
      encoded.val += 1
      Ok(@capability.Value::int(value))
    },
    value => Ok(value),
    _ => Ok(()),
    _ => Ok(()),
    value => {
      Ok(() => {
        match handle.val {
          Some(call) => if call.poll() is @mcp.Busy { busy.val += 1 }
          None => ()
        }
        allowed.val = false
        @capability.Complete(value)
      })
    },
    () => Ok(()),
    _ => {
      if allowed.val {
        Ok(())
      } else {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.PermissionDenied,
            "revoked",
          ),
        )
      }
    },
  )
  assert_true(registry.register_async(operation) is Ok(_))
  let call = cooperative_ok(
    adapter.begin_tool("async_reenter", @capability.Value::int(2)),
  )
  handle.val = Some(call)
  assert_true(call.poll() is @mcp.Pending)
  match call.poll() {
    @mcp.Failed(error) => assert_true(error.code() is @mcp.PermissionDenied)
    _ => fail("denied")
  }
  assert_eq(busy.val, 1)
  assert_eq(encoded.val, 0)
  assert_true(call.poll() is @mcp.Consumed)
}

///|
test "close during every admission callback stops later callbacks including error returns" {
  for close_at in 1..<=6 {
    for callback_error in [false, true] {
      let registry = @capability.Registry::new()
      let adapter = @mcp.Adapter::new(registry)
      let trace : Array[String] = []
      let started = Ref(0)
      let stage = fn(name : String) {
        trace.push(name)
        if trace.length() == close_at {
          adapter.close()
          if callback_error {
            return Err(
              @diagnostics.FrameworkError::new(
                @diagnostics.CallbackFailure,
                "late admission error",
              ),
            )
          }
        }
        Ok(())
      }
      let operation = @capability.AsyncCapability::new(
        mcp_command_descriptor("async.admission", @capability.External),
        value => {
          match stage("decode") {
            Err(error) => Err(error)
            Ok(_) => value.as_int()
          }
        },
        value => Ok(@capability.Value::int(value)),
        value => {
          match stage("snapshot") {
            Err(error) => Err(error)
            Ok(_) => Ok(value)
          }
        },
        _ => stage("input"),
        _ => Ok(()),
        value => {
          started.val += 1
          Ok(() => @capability.Complete(value))
        },
        () => stage("availability"),
        _ => stage("policy"),
      )
      assert_true(registry.register_async(operation) is Ok(_))
      match adapter.begin_tool("async_admission", @capability.Value::int(7)) {
        Err(error) => assert_true(error.code() is @mcp.AdapterClosed)
        Ok(_) => fail("close must reject admission")
      }
      assert_eq(trace.length(), close_at)
      assert_eq(started.val, 0)
    }
  }
}
