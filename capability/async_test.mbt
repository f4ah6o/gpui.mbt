///|
fn async_error(code : @diagnostics.ErrorCode) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(code, "async.test", subsystem="async-test")
}

///|
fn[T] async_assert_failed(
  outcome : @capability.InvocationOutcome[T],
  code : @diagnostics.ErrorCode,
) -> Unit raise {
  match outcome {
    @capability.Failed(error) => assert_eq(error.code().label(), code.label())
    _ => fail("expected a terminal failure")
  }
}

///|
fn[T] async_assert_error(
  result : Result[T, @diagnostics.FrameworkError],
  code : @diagnostics.ErrorCode,
) -> Unit raise {
  match result {
    Err(error) => assert_eq(error.code().label(), code.label())
    Ok(_) => fail("expected admission to fail")
  }
}

///|
fn async_fixture(
  visit : (String) -> Result[Unit, @diagnostics.FrameworkError],
) -> @capability.AsyncCapability[Int, Int] raise {
  @capability.AsyncCapability::new(
    external_int_descriptor("async.fixture", @capability.Workflow),
    value => {
      match visit("decode") {
        Err(error) => Err(error)
        Ok(_) => value.as_int()
      }
    },
    value => {
      match visit("encode") {
        Err(error) => Err(error)
        Ok(_) => Ok(@capability.Value::int(value))
      }
    },
    value => {
      match visit("snapshot") {
        Err(error) => Err(error)
        Ok(_) => Ok(value)
      }
    },
    _ => visit("input"),
    _ => visit("output"),
    value => {
      match visit("factory") {
        Err(error) => Err(error)
        Ok(_) => {
          let current = Ref(value)
          let turns = Ref(0)
          Ok(() => {
            match visit("step") {
              Err(error) => @capability.Fail(error)
              Ok(_) => {
                current.val += 1
                turns.val += 1
                if turns.val == 2 {
                  @capability.Complete(current.val)
                } else {
                  @capability.Pending
                }
              }
            }
          })
        }
      }
    },
    () => visit("availability"),
    _ => visit("policy"),
  )
}

///|
fn async_origins() -> Array[@capability.InvocationOrigin] {
  [
    @capability.Direct,
    @capability.Gui,
    @capability.LocalAutomation,
    @capability.RemoteMcp,
  ]
}

///|
test "cooperative factory and each actual work step consume separate polls for every origin" {
  for origin in async_origins() {
    let factories = Ref(0)
    let processed : Array[Int] = []
    let commits = Ref(0)
    let capability = @capability.AsyncCapability::new(
      external_int_descriptor("async.sum", @capability.Workflow),
      value => value.as_int(),
      value => Ok(@capability.Value::int(value)),
      value => Ok(value),
      _ => Ok(()),
      _ => Ok(()),
      limit => {
        factories.val += 1
        let index = Ref(0)
        let total = Ref(0)
        Ok(() => {
          index.val += 1
          processed.push(index.val)
          total.val += index.val
          if index.val == limit {
            commits.val += 1
            @capability.Complete(total.val)
          } else {
            @capability.Pending
          }
        })
      },
      () => Ok(()),
      _ => Ok(()),
    )
    let invocation = mutation_ok(capability.begin(origin, 3))
    assert_eq(factories.val, 0)
    assert_eq(processed, [])
    assert_true(invocation.poll() is @capability.Pending)
    assert_eq(factories.val, 1)
    assert_eq(processed, [])
    assert_true(invocation.poll() is @capability.Pending)
    assert_eq(processed, [1])
    assert_eq(commits.val, 0)
    assert_true(invocation.poll() is @capability.Pending)
    assert_eq(processed, [1, 2])
    assert_true(invocation.poll() is @capability.Ready(6))
    assert_eq(processed, [1, 2, 3])
    assert_eq(commits.val, 1)
    assert_true(invocation.poll() is @capability.Consumed)
    assert_true(invocation.cancel() is @capability.TooLate)
    assert_true(invocation.poll() is @capability.Consumed)
    assert_eq(factories.val, 1)
    assert_eq(commits.val, 1)
  }
}

///|
priv struct AsyncNestedInput {
  rows : Array[Ref[Array[Int]]]
}

///|
fn async_nested_fixture(
  decoded : AsyncNestedInput,
  observed : Array[Int],
) -> @capability.AsyncCapability[AsyncNestedInput, Int] raise {
  @capability.AsyncCapability::new(
    external_int_descriptor("async.nested", @capability.Workflow),
    _ => Ok(decoded),
    value => Ok(@capability.Value::int(value)),
    input => {
      Ok({ rows: input.rows.map(row => Ref(row.val.map(value => value))), })
    },
    input => {
      if input.rows.length() == 2 && input.rows[0].val.length() == 2 {
        Ok(())
      } else {
        Err(async_error(@diagnostics.InvalidInput))
      }
    },
    _ => Ok(()),
    input => {
      observed.push(input.rows[0].val[0])
      let turn = Ref(0)
      let sum = Ref(0)
      Ok(() => {
        let row = input.rows[turn.val].val
        sum.val += row[0] + row[1]
        observed.push(sum.val)
        turn.val += 1
        if turn.val == 2 {
          @capability.Complete(sum.val)
        } else {
          @capability.Pending
        }
      })
    },
    () => Ok(()),
    _ => Ok(()),
  )
}

///|
test "typed begin deep snapshots nested arrays and refs before and between actual work turns" {
  for origin in async_origins() {
    let first = Ref([1, 2])
    let second = Ref([3, 4])
    let input = { rows: [first, second], }
    let observed : Array[Int] = []
    let capability = async_nested_fixture(input, observed)
    let invocation = mutation_ok(capability.begin(origin, input))
    first.val[0] = 100
    assert_true(invocation.poll() is @capability.Pending)
    assert_eq(observed, [1])
    first.val = [200, 300]
    input.rows[1] = Ref([400, 500])
    assert_true(invocation.poll() is @capability.Pending)
    assert_eq(observed, [1, 3])
    second.val[0] = 600
    input.rows.clear()
    assert_true(invocation.poll() is @capability.Ready(10))
    assert_eq(observed, [1, 3, 10])
  }
}

///|
test "erased begin deep snapshots decoder-owned mutable aliases for all origins" {
  for origin in async_origins() {
    let first = Ref([1, 2])
    let second = Ref([3, 4])
    let decoded = { rows: [first, second], }
    let observed : Array[Int] = []
    let capability = async_nested_fixture(decoded, observed)
    let registry = @capability.Registry::new()
    assert_true(registry.register_async(capability) is Ok(_))
    let invocation = mutation_ok(
      registry.begin_external("async_nested", origin, @capability.Value::int(0)),
    )
    first.val[0] = 100
    assert_true(invocation.poll() is @capability.Pending)
    assert_eq(observed, [1])
    first.val = [200, 300]
    decoded.rows[1] = Ref([400, 500])
    assert_true(invocation.poll() is @capability.Pending)
    second.val[0] = 600
    decoded.rows.clear()
    match invocation.poll() {
      @capability.Ready(value) => assert_true(value.as_int() is Ok(10))
      _ => fail("decoder alias mutation changed captured work")
    }
    assert_eq(observed, [1, 3, 10])
    assert_true(invocation.poll() is @capability.Consumed)
  }
}

///|
test "async registry discovery includes jobs but synchronous execution never starts them" {
  let registry = @capability.Registry::new()
  let stages : Array[String] = []
  let capability = async_fixture(stage => {
    stages.push(stage)
    Ok(())
  })
  assert_true(registry.register_async(capability) is Ok(_))
  assert_true(registry.is_async("async.fixture"))
  assert_true(!registry.is_async("missing"))
  assert_eq(registry.descriptors().map(value => value.id()), ["async.fixture"])
  assert_eq(registry.external_descriptors().map(value => value.id()), [
    "async.fixture",
  ])
  for origin in async_origins() {
    async_assert_error(
      registry.invoke("async.fixture", origin, @capability.Value::int(1)),
      @diagnostics.UnsupportedCapability,
    )
    async_assert_error(
      registry.invoke_external(
        "async_fixture",
        origin,
        @capability.Value::int(1),
      ),
      @diagnostics.UnsupportedCapability,
    )
    async_assert_error(
      registry.begin("missing", origin, @capability.Value::int(1)),
      @diagnostics.UnsupportedCapability,
    )
    let invocation = mutation_ok(
      registry.begin("async.fixture", origin, @capability.Value::int(1)),
    )
    assert_true(invocation.poll() is @capability.Pending)
    assert_true(invocation.poll() is @capability.Pending)
    match invocation.poll() {
      @capability.Ready(value) => assert_true(value.as_int() is Ok(3))
      _ => fail("registry must drive the cooperative implementation")
    }
  }
  assert_eq(stages.filter(stage => stage == "factory").length(), 4)
  assert_true(registry.register_async(capability) is Err(_))
  let synchronous = mutation_identity(
    external_int_descriptor("sync.only", @capability.Query),
  )
  assert_true(registry.register(synchronous) is Ok(_))
  assert_true(!registry.is_async("sync.only"))
  async_assert_error(
    registry.begin("sync.only", @capability.Direct, @capability.Value::int(1)),
    @diagnostics.UnsupportedCapability,
  )
}

///|
test "cancel before starting and between work turns is idempotent and suppresses later work" {
  for cancel_after in [0, 1, 2] {
    let stages : Array[String] = []
    let capability = async_fixture(stage => {
      stages.push(stage)
      Ok(())
    })
    let invocation = mutation_ok(capability.begin(@capability.Direct, 5))
    for turn = 0; turn < cancel_after; turn = turn + 1 {
      assert_true(invocation.poll() is @capability.Pending)
    }
    let before = stages.length()
    assert_true(invocation.cancel() is @capability.Cancelled)
    assert_true(invocation.cancel() is @capability.AlreadyCancelled)
    assert_true(invocation.poll() is @capability.Cancelled)
    assert_true(invocation.poll() is @capability.Cancelled)
    assert_eq(stages.length(), before)
  }
}

///|
test "factory and step failures are delivered once and cannot be cancelled or restarted" {
  for fail_at in ["factory", "step"] {
    let stages : Array[String] = []
    let capability = async_fixture(stage => {
      stages.push(stage)
      if stage == fail_at {
        Err(async_error(@diagnostics.TaskFailure))
      } else {
        Ok(())
      }
    })
    let invocation = mutation_ok(capability.begin(@capability.Direct, 1))
    if fail_at == "step" {
      assert_true(invocation.poll() is @capability.Pending)
    }
    async_assert_failed(invocation.poll(), @diagnostics.TaskFailure)
    let before = stages.length()
    assert_true(invocation.poll() is @capability.Consumed)
    assert_true(invocation.cancel() is @capability.TooLate)
    assert_eq(stages.length(), before)
    assert_true(!stages.contains("output"))
    assert_true(!stages.contains("encode"))
  }
}

///|
fn[T] async_expect_eventual_failure(
  begun : Result[@capability.Invocation[T], @diagnostics.FrameworkError],
  code : @diagnostics.ErrorCode,
) -> Unit raise {
  match begun {
    Err(error) => assert_eq(error.code().label(), code.label())
    Ok(invocation) => {
      for turn = 0; turn < 4; turn = turn + 1 {
        match invocation.poll() {
          @capability.Pending => ()
          @capability.Failed(error) => {
            assert_eq(error.code().label(), code.label())
            if code is @diagnostics.StaleHandle {
              async_assert_failed(invocation.poll(), @diagnostics.StaleHandle)
            } else {
              assert_true(invocation.poll() is @capability.Consumed)
              assert_true(invocation.cancel() is @capability.TooLate)
            }
            return
          }
          _ => fail("job published a result instead of rejecting the callback")
        }
      }
      fail("bounded fixture did not terminate")
    }
  }
}

///|
test "callback errors reject admission or terminate work across typed and erased origins" {
  for erased in [false, true] {
    let stages = if erased {
      [
        "availability", "policy", "decode", "snapshot", "input", "factory", "step",
        "output", "encode",
      ]
    } else {
      [
        "availability", "policy", "snapshot", "input", "factory", "step", "output",
      ]
    }
    for origin in async_origins() {
      for fail_at in stages {
        let visited : Array[String] = []
        let capability = async_fixture(stage => {
          visited.push(stage)
          if stage == fail_at {
            Err(async_error(@diagnostics.CallbackFailure))
          } else {
            Ok(())
          }
        })
        let registry = @capability.Registry::new()
        assert_true(registry.register_async(capability) is Ok(_))
        let expected = if fail_at == "encode" {
          @diagnostics.ConversionFailed
        } else if fail_at == "decode" {
          @diagnostics.InvalidInput
        } else {
          @diagnostics.CallbackFailure
        }
        if erased {
          async_expect_eventual_failure(
            registry.begin("async.fixture", origin, @capability.Value::int(1)),
            expected,
          )
        } else {
          async_expect_eventual_failure(capability.begin(origin, 1), expected)
        }
        // Authorization may be repeated while handling a result, but no
        // subsequent application stage can run after the failed stage.
        let work = visited.filter(stage => stage != "policy")
        if fail_at != "policy" {
          assert_eq(work[work.length() - 1], fail_at)
        } else {
          assert_eq(work, ["availability"])
        }
      }
    }
  }
}

///|
test "owner shutdown at every callback occurrence wins over callback successes and errors" {
  for erased in [false, true] {
    for origin in async_origins() {
      let baseline : Array[String] = []
      let capability = async_fixture(stage => {
        baseline.push(stage)
        Ok(())
      })
      if erased {
        let registry = @capability.Registry::new()
        assert_true(registry.register_async(capability) is Ok(_))
        let job = mutation_ok(
          registry.begin("async.fixture", origin, @capability.Value::int(1)),
        )
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Ready(_))
      } else {
        let job = mutation_ok(capability.begin(origin, 1))
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Ready(3))
      }
      for return_error in [false, true] {
        for stop_index = 1
            stop_index <= baseline.length()
            stop_index = stop_index + 1 {
          let app = running_capability_app()
          let registry = owned_registry(app)
          let visited : Array[String] = []
          let capability = async_fixture(stage => {
            visited.push(stage)
            if visited.length() == stop_index {
              ignore(app.request_stop())
              if return_error {
                Err(async_error(@diagnostics.CallbackFailure))
              } else {
                Ok(())
              }
            } else {
              Ok(())
            }
          })
          assert_true(registry.register_async(capability) is Ok(_))
          if erased {
            async_expect_eventual_failure(
              registry.begin("async.fixture", origin, @capability.Value::int(1)),
              @diagnostics.StaleHandle,
            )
          } else {
            async_expect_eventual_failure(
              capability.begin(origin, 1),
              @diagnostics.StaleHandle,
            )
          }
          assert_eq(visited.length(), stop_index)
          assert_eq(visited[stop_index - 1], baseline[stop_index - 1])
        }
      }
    }
  }
}

///|
test "adoption revokes jobs and GUI bindings obtained before registration or ownership" {
  let app = running_capability_app()
  let registry = @capability.Registry::new()
  let stages : Array[String] = []
  let capability = async_fixture(stage => {
    stages.push(stage)
    Ok(())
  })
  let gui = capability.gui_binding()
  let direct_job = mutation_ok(capability.begin(@capability.Direct, 1))
  let gui_job = mutation_ok(gui.begin(2))
  assert_true(registry.register_async(capability) is Ok(_))
  assert_true(registry.attach_owner(app) is Ok(_))
  assert_true(registry.attach_owner(app) is Ok(_))
  assert_true(gui.is_enabled())
  let erased_job = mutation_ok(
    registry.begin_external(
      "async_fixture",
      @capability.RemoteMcp,
      @capability.Value::int(3),
    ),
  )
  assert_true(direct_job.poll() is @capability.Pending)
  assert_true(gui_job.poll() is @capability.Pending)
  assert_true(erased_job.poll() is @capability.Pending)
  assert_true(app.request_stop() is Ok(_))
  let before = stages.length()
  async_assert_failed(direct_job.poll(), @diagnostics.StaleHandle)
  async_assert_failed(gui_job.poll(), @diagnostics.StaleHandle)
  async_assert_failed(erased_job.poll(), @diagnostics.StaleHandle)
  assert_true(!gui.is_enabled())
  assert_stale(gui.begin(4))
  for origin in async_origins() {
    assert_stale(capability.begin(origin, 4))
    assert_stale(
      registry.begin("async.fixture", origin, @capability.Value::int(4)),
    )
    assert_stale(
      registry.begin_external(
        "async_fixture",
        origin,
        @capability.Value::int(4),
      ),
    )
  }
  assert_eq(stages.length(), before)
  assert_true(registry.descriptors().is_empty())
  assert_true(registry.external_descriptors().is_empty())
  assert_true(!registry.is_async("async.fixture"))
}

///|
test "stopped owners revoke pending cancelled failed and consumed jobs without callbacks" {
  for terminal in ["pending", "cancelled", "failed", "ready"] {
    let app = running_capability_app()
    let registry = owned_registry(app)
    let stages : Array[String] = []
    let capability = async_fixture(stage => {
      stages.push(stage)
      if terminal == "failed" && stage == "step" {
        Err(async_error(@diagnostics.TaskFailure))
      } else {
        Ok(())
      }
    })
    assert_true(registry.register_async(capability) is Ok(_))
    let job = mutation_ok(capability.begin(@capability.Direct, 1))
    assert_true(job.poll() is @capability.Pending)
    match terminal {
      "cancelled" => assert_true(job.cancel() is @capability.Cancelled)
      "failed" => async_assert_failed(job.poll(), @diagnostics.TaskFailure)
      "ready" => {
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Ready(3))
      }
      _ => ()
    }
    assert_true(app.request_stop() is Ok(_))
    let before = stages.length()
    async_assert_failed(job.poll(), @diagnostics.StaleHandle)
    async_assert_failed(job.poll(), @diagnostics.StaleHandle)
    assert_eq(stages.length(), before)
  }
}

///|
test "new owner prevents async admission until Running and failed competing registration cannot revoke it" {
  let app = mutation_ok(@core.App::new())
  let registry = owned_registry(app)
  let visits = Ref(0)
  let capability = async_fixture(_ => {
    visits.val += 1
    Ok(())
  })
  assert_true(registry.register_async(capability) is Ok(_))
  assert_true(!capability.gui_binding().is_enabled())
  for origin in async_origins() {
    async_assert_error(capability.begin(origin, 1), @diagnostics.AppNotRunning)
    async_assert_error(
      registry.begin("async.fixture", origin, @capability.Value::int(1)),
      @diagnostics.AppNotRunning,
    )
  }
  assert_eq(visits.val, 0)
  assert_true(app.start() is Ok(_))
  let second = @capability.Registry::new()
  async_assert_error(
    second.register_async(capability),
    @diagnostics.InvalidInput,
  )
  second.teardown()
  assert_true(capability.gui_binding().is_enabled())
  let job = mutation_ok(capability.gui_binding().begin(3))
  assert_true(job.poll() is @capability.Pending)
  assert_true(job.poll() is @capability.Pending)
  assert_true(job.poll() is @capability.Ready(5))
  registry.teardown()
  registry.teardown()
  assert_stale(capability.begin(@capability.Direct, 1))
}

///|
test "reentrant polling is Busy from every polling callback and never duplicates actual work" {
  for erased in [false, true] {
    for origin in async_origins() {
      let reenter : Ref[(() -> Result[Unit, @diagnostics.FrameworkError])?] = Ref(
        None,
      )
      let attempted : Array[String] = []
      let capability = async_fixture(stage => {
        match reenter.val {
          None => Ok(())
          Some(callback) => {
            attempted.push(stage)
            callback()
          }
        }
      })
      let registry = @capability.Registry::new()
      assert_true(registry.register_async(capability) is Ok(_))
      if erased {
        let job = mutation_ok(
          registry.begin("async.fixture", origin, @capability.Value::int(1)),
        )
        reenter.val = Some(() => {
          if job.poll() is @capability.Busy {
            Ok(())
          } else {
            Err(async_error(@diagnostics.ReentrantUpdate))
          }
        })
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Ready(_))
        assert_true(job.poll() is @capability.Consumed)
      } else {
        let job = mutation_ok(capability.begin(origin, 1))
        reenter.val = Some(() => {
          if job.poll() is @capability.Busy {
            Ok(())
          } else {
            Err(async_error(@diagnostics.ReentrantUpdate))
          }
        })
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Pending)
        assert_true(job.poll() is @capability.Ready(3))
        assert_true(job.poll() is @capability.Consumed)
      }
      assert_true(attempted.contains("policy"))
      assert_eq(attempted.filter(stage => stage == "availability").length(), 1)
      assert_eq(attempted.filter(stage => stage == "factory").length(), 1)
      assert_eq(attempted.filter(stage => stage == "step").length(), 2)
      assert_eq(attempted.filter(stage => stage == "output").length(), 1)
      assert_eq(
        attempted.filter(stage => stage == "encode").length(),
        if erased {
          1
        } else {
          0
        },
      )
      reenter.val = None
    }
  }
}

///|
fn[T] async_expect_cancelled(
  job : @capability.Invocation[T],
  context : String,
) -> Unit raise {
  for turn = 0; turn < 4; turn = turn + 1 {
    match job.poll() {
      @capability.Pending => ()
      @capability.Cancelled => {
        assert_true(job.poll() is @capability.Cancelled)
        if !(job.cancel() is @capability.AlreadyCancelled) {
          fail("cancel must remain idempotent: \{context}")
        }
        return
      }
      _ => fail("cancelled callback published a result: \{context}")
    }
  }
  fail("cancelled fixture did not stop: \{context}")
}

///|
test "reentrant cancellation in every polling callback prevents all later callbacks and publication" {
  for erased in [false, true] {
    let stages = if erased {
      ["availability", "policy", "factory", "step", "output", "encode"]
    } else {
      ["availability", "policy", "factory", "step", "output"]
    }
    for cancel_at in stages {
      for return_error in [false, true] {
        let cancel : Ref[(() -> @capability.Cancellation)?] = Ref(None)
        let cancelled = Ref(false)
        let post_cancel : Array[String] = []
        let step_count = Ref(0)
        let cancellation_ok = Ref(false)
        let capability = async_fixture(stage => {
          if cancelled.val {
            post_cancel.push(stage)
          }
          if stage == "step" {
            step_count.val += 1
          }
          if stage == cancel_at && (stage != "step" || step_count.val == 2) {
            match cancel.val {
              None => ()
              Some(callback) => {
                cancellation_ok.val = callback() is @capability.Cancelled
                cancelled.val = true
              }
            }
          }
          if cancelled.val && return_error {
            Err(async_error(@diagnostics.CallbackFailure))
          } else {
            Ok(())
          }
        })
        let registry = @capability.Registry::new()
        assert_true(registry.register_async(capability) is Ok(_))
        if erased {
          let job = mutation_ok(
            registry.begin(
              "async.fixture",
              @capability.RemoteMcp,
              @capability.Value::int(1),
            ),
          )
          cancel.val = Some(() => job.cancel())
          async_expect_cancelled(job, "\{erased}:\{cancel_at}:\{return_error}")
        } else {
          let job = mutation_ok(capability.gui_binding().begin(1))
          cancel.val = Some(() => job.cancel())
          async_expect_cancelled(job, "\{erased}:\{cancel_at}:\{return_error}")
        }
        assert_true(cancellation_ok.val)
        assert_eq(post_cancel, [])
        cancel.val = None
      }
    }
  }
}

///|
test "registry teardown from every polling callback is reentrant and stops later callbacks" {
  for erased in [false, true] {
    let stages = if erased {
      ["availability", "policy", "factory", "step", "output", "encode"]
    } else {
      ["availability", "policy", "factory", "step", "output"]
    }
    for stop_at in stages {
      let registry = @capability.Registry::new()
      let enabled = Ref(false)
      let stopped = Ref(false)
      let late : Array[String] = []
      let capability = async_fixture(stage => {
        if stopped.val {
          late.push(stage)
        }
        if enabled.val && stage == stop_at {
          registry.teardown()
          registry.teardown()
          stopped.val = true
          Err(async_error(@diagnostics.CallbackFailure))
        } else {
          Ok(())
        }
      })
      assert_true(registry.register_async(capability) is Ok(_))
      if erased {
        let job = mutation_ok(
          registry.begin(
            "async.fixture",
            @capability.RemoteMcp,
            @capability.Value::int(1),
          ),
        )
        enabled.val = true
        async_expect_eventual_failure(Ok(job), @diagnostics.StaleHandle)
      } else {
        let job = mutation_ok(capability.gui_binding().begin(1))
        enabled.val = true
        async_expect_eventual_failure(Ok(job), @diagnostics.StaleHandle)
      }
      assert_true(stopped.val)
      assert_eq(late, [])
      assert_true(!capability.gui_binding().is_enabled())
    }
  }
}

///|
test "policy revocation before first poll and between work turns prevents further semantic work" {
  for origin in async_origins() {
    for revoke_after in [0, 1, 2] {
      let allowed = Ref(true)
      let visits : Array[String] = []
      let capability = async_fixture(stage => {
        visits.push(stage)
        if stage == "policy" && !allowed.val {
          Err(async_error(@diagnostics.PermissionDenied))
        } else {
          Ok(())
        }
      })
      let job = mutation_ok(capability.begin(origin, 1))
      for turn = 0; turn < revoke_after; turn = turn + 1 {
        assert_true(job.poll() is @capability.Pending)
      }
      let work_before = visits.filter(stage => stage != "policy").length()
      allowed.val = false
      async_assert_failed(job.poll(), @diagnostics.PermissionDenied)
      assert_eq(visits.filter(stage => stage != "policy").length(), work_before)
      let terminal_count = visits.length()
      allowed.val = true
      assert_true(job.poll() is @capability.Consumed)
      assert_true(job.cancel() is @capability.TooLate)
      assert_eq(visits.length(), terminal_count)
    }
  }
}

///|
test "policy revoked inside factory step output or encoder defeats both late values and callback errors" {
  for erased in [false, true] {
    let stages = if erased {
      ["factory", "step", "output", "encode"]
    } else {
      ["factory", "step", "output"]
    }
    for revoke_at in stages {
      for return_error in [false, true] {
        let allowed = Ref(true)
        let visits : Array[String] = []
        let steps = Ref(0)
        let capability = async_fixture(stage => {
          visits.push(stage)
          if stage == "policy" && !allowed.val {
            return Err(async_error(@diagnostics.PermissionDenied))
          }
          if stage == "step" {
            steps.val += 1
          }
          if stage == revoke_at && (stage != "step" || steps.val == 2) {
            allowed.val = false
            if return_error {
              return Err(async_error(@diagnostics.CallbackFailure))
            }
          }
          Ok(())
        })
        if erased {
          let registry = @capability.Registry::new()
          assert_true(registry.register_async(capability) is Ok(_))
          async_expect_eventual_failure(
            registry.begin(
              "async.fixture",
              @capability.RemoteMcp,
              @capability.Value::int(1),
            ),
            @diagnostics.PermissionDenied,
          )
        } else {
          async_expect_eventual_failure(
            capability.gui_binding().begin(1),
            @diagnostics.PermissionDenied,
          )
        }
        let work = visits.filter(stage => stage != "policy")
        assert_eq(work[work.length() - 1], revoke_at)
        assert_true(!allowed.val)
      }
    }
  }
}

///|
test "availability is rechecked at start but successful commit can make the operation unavailable" {
  for erased in [false, true] {
    for available_at_start in [false, true] {
      let available = Ref(true)
      let checks = Ref(0)
      let commits = Ref(0)
      let factories = Ref(0)
      let capability = @capability.AsyncCapability::new(
        external_int_descriptor("async.once", @capability.Command),
        value => value.as_int(),
        value => Ok(@capability.Value::int(value)),
        value => Ok(value),
        _ => Ok(()),
        _ => Ok(()),
        value => {
          factories.val += 1
          Ok(() => {
            commits.val += 1
            available.val = false
            @capability.Complete(value + 1)
          })
        },
        () => {
          checks.val += 1
          if available.val {
            Ok(())
          } else {
            Err(async_error(@diagnostics.EntityNotLive))
          }
        },
        _ => Ok(()),
      )
      let registry = @capability.Registry::new()
      assert_true(registry.register_async(capability) is Ok(_))
      if erased {
        let job = mutation_ok(
          registry.begin_external(
            "async_once",
            @capability.RemoteMcp,
            @capability.Value::int(8),
          ),
        )
        available.val = available_at_start
        if available_at_start {
          assert_true(job.poll() is @capability.Pending)
          match job.poll() {
            @capability.Ready(value) => assert_true(value.as_int() is Ok(9))
            _ =>
              fail(
                "a successful commit must survive its own availability change",
              )
          }
          assert_true(job.cancel() is @capability.TooLate)
          assert_true(job.poll() is @capability.Consumed)
        } else {
          async_assert_failed(job.poll(), @diagnostics.EntityNotLive)
        }
      } else {
        let job = mutation_ok(capability.gui_binding().begin(8))
        available.val = available_at_start
        if available_at_start {
          assert_true(job.poll() is @capability.Pending)
          assert_true(job.poll() is @capability.Ready(9))
          assert_true(job.cancel() is @capability.TooLate)
          assert_true(job.poll() is @capability.Consumed)
        } else {
          async_assert_failed(job.poll(), @diagnostics.EntityNotLive)
        }
      }
      assert_eq(checks.val, 2)
      assert_eq(commits.val, if available_at_start { 1 } else { 0 })
      assert_eq(factories.val, if available_at_start { 1 } else { 0 })
      assert_true(!capability.gui_binding().is_enabled())
    }
  }
}

///|
test "typed and erased origins share domain validators while only erased calls use transport projection" {
  for erased in [false, true] {
    for origin in async_origins() {
      for input in [-1, 5, 20] {
        let decoded = Ref(0)
        let encoded = Ref(0)
        let input_checks = Ref(0)
        let output_checks = Ref(0)
        let factories = Ref(0)
        let capability = @capability.AsyncCapability::new(
          external_int_descriptor("async.domain", @capability.Workflow),
          value => {
            decoded.val += 1
            value.as_int()
          },
          value => {
            encoded.val += 1
            Ok(@capability.Value::int(value))
          },
          value => Ok(value),
          value => {
            input_checks.val += 1
            if value < 0 {
              Err(async_error(@diagnostics.InvalidInput))
            } else {
              Ok(())
            }
          },
          value => {
            output_checks.val += 1
            if value > 10 {
              Err(async_error(@diagnostics.InvalidInput))
            } else {
              Ok(())
            }
          },
          value => {
            factories.val += 1
            Ok(() => @capability.Complete(value + 1))
          },
          () => Ok(()),
          _ => Ok(()),
        )
        let registry = @capability.Registry::new()
        assert_true(registry.register_async(capability) is Ok(_))
        if erased {
          let begun = registry.begin(
            "async.domain",
            origin,
            @capability.Value::int(input),
          )
          if input < 0 {
            async_assert_error(begun, @diagnostics.InvalidInput)
          } else {
            let job = mutation_ok(begun)
            assert_true(job.poll() is @capability.Pending)
            if input > 10 {
              async_assert_failed(job.poll(), @diagnostics.InvalidInput)
            } else {
              match job.poll() {
                @capability.Ready(value) => assert_true(value.as_int() is Ok(6))
                _ => fail("valid domain output was rejected")
              }
            }
          }
        } else {
          let begun = capability.begin(origin, input)
          if input < 0 {
            async_assert_error(begun, @diagnostics.InvalidInput)
          } else {
            let job = mutation_ok(begun)
            assert_true(job.poll() is @capability.Pending)
            if input > 10 {
              async_assert_failed(job.poll(), @diagnostics.InvalidInput)
            } else {
              assert_true(job.poll() is @capability.Ready(6))
            }
          }
        }
        assert_eq(input_checks.val, 1)
        assert_eq(output_checks.val, if input < 0 { 0 } else { 1 })
        assert_eq(factories.val, if input < 0 { 0 } else { 1 })
        assert_eq(decoded.val, if erased { 1 } else { 0 })
        assert_eq(encoded.val, if erased && input == 5 { 1 } else { 0 })
      }
    }
  }
}

///|
test "erased jobs detach caller transport decoder aliases and final encoder storage" {
  let schema = @capability.Schema::array(
    @capability.Schema::array(@capability.Schema::int()),
  )
  let descriptor = mutation_ok(
    @capability.Descriptor::new(
      "async.transport",
      "transport",
      "nested snapshots",
      @capability.Workflow,
      schema,
      schema,
      @capability.ReadOnly,
      true,
      @capability.External,
      None,
      1,
    ),
  )
  let decoder_alias : Ref[@capability.Value?] = Ref(None)
  let encoded_row = [@capability.Value::int(10)]
  let encoded_rows = [@capability.ArrayValue(encoded_row)]
  let observations : Array[Int] = []
  let capability = @capability.AsyncCapability::new(
    descriptor,
    value => {
      decoder_alias.val = Some(value)
      Ok(value)
    },
    _ => Ok(@capability.ArrayValue(encoded_rows)),
    value => value.try_clone_transport(),
    _ => Ok(()),
    value => {
      if value == 10 {
        Ok(())
      } else {
        Err(async_error(@diagnostics.InvalidInput))
      }
    },
    input => {
      let rows = match input {
        @capability.ArrayValue(rows) => rows
        _ => return Err(async_error(@diagnostics.InvalidInput))
      }
      let index = Ref(0)
      let sum = Ref(0)
      Ok(() => {
        match rows[index.val] {
          @capability.ArrayValue(row) =>
            for cell in row {
              match cell {
                @capability.IntValue(value) => sum.val += value
                _ =>
                  return @capability.Fail(
                    async_error(@diagnostics.InvalidInput),
                  )
              }
            }
          _ => return @capability.Fail(async_error(@diagnostics.InvalidInput))
        }
        observations.push(sum.val)
        index.val += 1
        if index.val == rows.length() {
          @capability.Complete(sum.val)
        } else {
          @capability.Pending
        }
      })
    },
    () => Ok(()),
    _ => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register_async(capability) is Ok(_))
  let caller_row = [@capability.Value::int(1), @capability.Value::int(2)]
  let second_row = [@capability.Value::int(3), @capability.Value::int(4)]
  let caller_rows = [
    @capability.ArrayValue(caller_row),
    @capability.ArrayValue(second_row),
  ]
  let job = mutation_ok(
    registry.begin(
      "async.transport",
      @capability.LocalAutomation,
      @capability.ArrayValue(caller_rows),
    ),
  )
  caller_row[0] = @capability.Value::int(100)
  match decoder_alias.val {
    Some(@capability.ArrayValue(rows)) => {
      match rows[0] {
        @capability.ArrayValue(row) => row[0] = @capability.Value::int(200)
        _ => fail("decoder did not observe nested transport")
      }
      rows[1] = @capability.ArrayValue([@capability.Value::int(300)])
    }
    _ => fail("decoder did not receive transport input")
  }
  assert_true(job.poll() is @capability.Pending)
  assert_true(job.poll() is @capability.Pending)
  assert_eq(observations, [3])
  caller_rows.clear()
  second_row.clear()
  let output = match job.poll() {
    @capability.Ready(value) => value
    _ => fail("transport aliases changed the captured job")
  }
  assert_eq(observations, [3, 10])
  assert_eq(output.canonical_json(), "[[10]]")
  encoded_row[0] = @capability.Value::int(500)
  encoded_rows.clear()
  assert_eq(output.canonical_json(), "[[10]]")
  assert_true(job.poll() is @capability.Consumed)
}

///|
test "erased admission rejects wrong schemas and malformed transport before decoder or factory" {
  let visits : Array[String] = []
  let capability = async_fixture(stage => {
    visits.push(stage)
    Ok(())
  })
  let registry = @capability.Registry::new()
  assert_true(registry.register_async(capability) is Ok(_))
  let cycle : Array[@capability.Value] = []
  cycle.push(@capability.ArrayValue(cycle))
  for input in [@capability.Value::string("1"), @capability.ArrayValue(cycle)] {
    async_assert_error(
      registry.begin("async.fixture", @capability.RemoteMcp, input),
      @diagnostics.InvalidInput,
    )
    assert_true(!visits.contains("decode"))
    assert_true(!visits.contains("snapshot"))
    assert_true(!visits.contains("input"))
    assert_true(!visits.contains("factory"))
  }
}

///|
test "erased output projection rejects wrong schema and malformed transport after domain validation" {
  for malformed in [false, true] {
    let validations = Ref(0)
    let encodes = Ref(0)
    let steps = Ref(0)
    let capability = @capability.AsyncCapability::new(
      external_int_descriptor("async.bad.output", @capability.Workflow),
      value => value.as_int(),
      _ => {
        encodes.val += 1
        if malformed {
          let values : Array[@capability.Value] = []
          values.push(@capability.ArrayValue(values))
          Ok(@capability.ArrayValue(values))
        } else {
          Ok(@capability.Value::string("wrong schema"))
        }
      },
      value => Ok(value),
      _ => Ok(()),
      _ => {
        validations.val += 1
        Ok(())
      },
      value => {
        Ok(() => {
          steps.val += 1
          @capability.Complete(value)
        })
      },
      () => Ok(()),
      _ => Ok(()),
    )
    let registry = @capability.Registry::new()
    assert_true(registry.register_async(capability) is Ok(_))
    let job = mutation_ok(
      registry.begin(
        "async.bad.output",
        @capability.RemoteMcp,
        @capability.Value::int(1),
      ),
    )
    assert_true(job.poll() is @capability.Pending)
    async_assert_failed(job.poll(), @diagnostics.ConversionFailed)
    assert_true(job.poll() is @capability.Consumed)
    assert_true(job.cancel() is @capability.TooLate)
    assert_eq(validations.val, 1)
    assert_eq(encodes.val, 1)
    assert_eq(steps.val, 1)
  }
}

///|
test "cancellation at every polling callback occurrence suppresses later callbacks values and errors" {
  for erased in [false, true] {
    let baseline : Array[String] = []
    let capability = async_fixture(stage => {
      baseline.push(stage)
      Ok(())
    })
    if erased {
      let registry = @capability.Registry::new()
      assert_true(registry.register_async(capability) is Ok(_))
      let job = mutation_ok(
        registry.begin(
          "async.fixture",
          @capability.RemoteMcp,
          @capability.Value::int(1),
        ),
      )
      baseline.clear()
      assert_true(job.poll() is @capability.Pending)
      assert_true(job.poll() is @capability.Pending)
      assert_true(job.poll() is @capability.Ready(_))
    } else {
      let job = mutation_ok(capability.gui_binding().begin(1))
      baseline.clear()
      assert_true(job.poll() is @capability.Pending)
      assert_true(job.poll() is @capability.Pending)
      assert_true(job.poll() is @capability.Ready(3))
    }
    for use_scope in [false, true] {
      for return_error in [false, true] {
        for cancel_index = 1
            cancel_index <= baseline.length()
            cancel_index = cancel_index + 1 {
          let scope = @capability.InvocationScope::new()
          let cancel : Ref[(() -> Unit)?] = Ref(None)
          let visited : Array[String] = []
          let capability = async_fixture(stage => {
            match cancel.val {
              None => Ok(())
              Some(callback) => {
                visited.push(stage)
                if visited.length() == cancel_index {
                  callback()
                  if return_error {
                    Err(async_error(@diagnostics.CallbackFailure))
                  } else {
                    Ok(())
                  }
                } else {
                  Ok(())
                }
              }
            }
          })
          if erased {
            let registry = @capability.Registry::new()
            assert_true(registry.register_async(capability) is Ok(_))
            let job = mutation_ok(
              registry.begin(
                "async.fixture",
                @capability.RemoteMcp,
                @capability.Value::int(1),
                scope~,
              ),
            )
            cancel.val = Some(() => {
              if use_scope {
                scope.cancel()
              } else {
                ignore(job.cancel())
              }
            })
            async_expect_cancelled(
              job,
              "erased=\{erased}, scope=\{use_scope}, callback=\{cancel_index}, error=\{return_error}",
            )
          } else {
            let job = mutation_ok(capability.gui_binding().begin(1, scope~))
            cancel.val = Some(() => {
              if use_scope {
                scope.cancel()
              } else {
                ignore(job.cancel())
              }
            })
            async_expect_cancelled(
              job,
              "erased=\{erased}, scope=\{use_scope}, callback=\{cancel_index}, error=\{return_error}",
            )
          }
          assert_eq(visited.length(), cancel_index)
          assert_eq(visited[cancel_index - 1], baseline[cancel_index - 1])
          cancel.val = None
        }
      }
    }
  }
}

///|
test "scope cancellation at every admission callback wins over values and errors unless owner stopped" {
  for erased in [false, true] {
    for origin in async_origins() {
      let baseline : Array[String] = []
      let capability = async_fixture(stage => {
        baseline.push(stage)
        Ok(())
      })
      if erased {
        let registry = @capability.Registry::new()
        assert_true(registry.register_async(capability) is Ok(_))
        ignore(
          mutation_ok(
            registry.begin("async.fixture", origin, @capability.Value::int(1)),
          ),
        )
      } else {
        ignore(mutation_ok(capability.begin(origin, 1)))
      }
      for stop_owner in [false, true] {
        for return_error in [false, true] {
          for cancel_index = 1
              cancel_index <= baseline.length()
              cancel_index = cancel_index + 1 {
            let app = running_capability_app()
            let registry = owned_registry(app)
            let scope = @capability.InvocationScope::new()
            let visited : Array[String] = []
            let capability = async_fixture(stage => {
              visited.push(stage)
              if visited.length() == cancel_index {
                scope.cancel()
                scope.cancel()
                if stop_owner {
                  ignore(app.request_stop())
                }
                if return_error {
                  Err(async_error(@diagnostics.CallbackFailure))
                } else {
                  Ok(())
                }
              } else {
                Ok(())
              }
            })
            assert_true(registry.register_async(capability) is Ok(_))
            let expected = if stop_owner {
              @diagnostics.StaleHandle
            } else {
              @diagnostics.HostStopping
            }
            if erased {
              async_assert_error(
                registry.begin_external(
                  "async_fixture",
                  origin,
                  @capability.Value::int(1),
                  scope~,
                ),
                expected,
              )
            } else if origin is @capability.Gui {
              async_assert_error(
                capability.gui_binding().begin(1, scope~),
                expected,
              )
            } else {
              async_assert_error(capability.begin(origin, 1, scope~), expected)
            }
            assert_eq(visited.length(), cancel_index)
            assert_eq(visited[cancel_index - 1], baseline[cancel_index - 1])
          }
        }
      }
    }
  }
}

///|
test "scopes cancel pending siblings but individual cancellation is isolated and delivered outputs stay consumed" {
  let visits = Ref(0)
  let capability = async_fixture(_ => {
    visits.val += 1
    Ok(())
  })
  let registry = @capability.Registry::new()
  assert_true(registry.register_async(capability) is Ok(_))
  let scope = @capability.InvocationScope::new()
  let first = mutation_ok(capability.begin(@capability.Direct, 1, scope~))
  let ready = mutation_ok(capability.gui_binding().begin(2, scope~))
  let pending = mutation_ok(
    registry.begin(
      "async.fixture",
      @capability.LocalAutomation,
      @capability.Value::int(3),
      scope~,
    ),
  )
  let independent = mutation_ok(capability.begin(@capability.Direct, 4))
  let failing_capability = async_fixture(stage => {
    if stage == "factory" {
      Err(async_error(@diagnostics.TaskFailure))
    } else {
      Ok(())
    }
  })
  let failed = mutation_ok(
    failing_capability.begin(@capability.Direct, 1, scope~),
  )
  async_assert_failed(failed.poll(), @diagnostics.TaskFailure)
  assert_true(first.cancel() is @capability.Cancelled)
  assert_true(ready.poll() is @capability.Pending)
  assert_true(ready.poll() is @capability.Pending)
  assert_true(ready.poll() is @capability.Ready(4))
  assert_true(pending.poll() is @capability.Pending)
  scope.cancel()
  scope.cancel()
  let before = visits.val
  assert_true(first.poll() is @capability.Cancelled)
  assert_true(first.cancel() is @capability.AlreadyCancelled)
  assert_true(ready.poll() is @capability.Consumed)
  assert_true(ready.cancel() is @capability.TooLate)
  assert_true(failed.poll() is @capability.Consumed)
  assert_true(failed.cancel() is @capability.TooLate)
  assert_true(pending.poll() is @capability.Cancelled)
  assert_true(pending.cancel() is @capability.AlreadyCancelled)
  assert_true(pending.poll() is @capability.Cancelled)
  for origin in async_origins() {
    async_assert_error(
      capability.begin(origin, 1, scope~),
      @diagnostics.HostStopping,
    )
    async_assert_error(
      registry.begin("async.fixture", origin, @capability.Value::int(1), scope~),
      @diagnostics.HostStopping,
    )
    async_assert_error(
      registry.begin_external(
        "async_fixture",
        origin,
        @capability.Value::int(1),
        scope~,
      ),
      @diagnostics.HostStopping,
    )
  }
  assert_eq(visits.val, before)
  assert_true(independent.poll() is @capability.Pending)
  assert_true(independent.poll() is @capability.Pending)
  assert_true(independent.poll() is @capability.Ready(6))
}

///|
test "cancel within a committing step suppresses result and output callbacks without undoing committed effects" {
  for erased in [false, true] {
    let cancel : Ref[(() -> @capability.Cancellation)?] = Ref(None)
    let committed = Ref(0)
    let steps = Ref(0)
    let output_callbacks = Ref(0)
    let cancellation_ok = Ref(false)
    let capability = @capability.AsyncCapability::new(
      external_int_descriptor("async.commit", @capability.Command),
      value => value.as_int(),
      value => {
        output_callbacks.val += 1
        Ok(@capability.Value::int(value))
      },
      value => Ok(value),
      _ => Ok(()),
      _ => {
        output_callbacks.val += 1
        Ok(())
      },
      value => {
        Ok(() => {
          steps.val += 1
          committed.val = value
          match cancel.val {
            Some(callback) =>
              cancellation_ok.val = callback() is @capability.Cancelled
            None => ()
          }
          @capability.Complete(value)
        })
      },
      () => Ok(()),
      _ => Ok(()),
    )
    if erased {
      let registry = @capability.Registry::new()
      assert_true(registry.register_async(capability) is Ok(_))
      let job = mutation_ok(
        registry.begin(
          "async.commit",
          @capability.RemoteMcp,
          @capability.Value::int(17),
        ),
      )
      cancel.val = Some(() => job.cancel())
      async_expect_cancelled(job, "committing erased step")
    } else {
      let job = mutation_ok(capability.gui_binding().begin(17))
      cancel.val = Some(() => job.cancel())
      async_expect_cancelled(job, "committing typed step")
    }
    assert_true(cancellation_ok.val)
    assert_eq(committed.val, 17)
    assert_eq(steps.val, 1)
    assert_eq(output_callbacks.val, 0)
    cancel.val = None
  }
}

///|
test "async begin preserves exposure rules and forwards every typed and erased origin to policy" {
  for
    exposure in [@capability.Internal, @capability.Local, @capability.External] {
    for erased in [false, true] {
      for origin in async_origins() {
        let origins : Array[@capability.InvocationOrigin] = []
        let work = Ref(0)
        let capability = @capability.AsyncCapability::new(
          mutation_ok(mutation_descriptor("async.exposure", exposure, None, 1)),
          value => value.as_int(),
          value => Ok(@capability.Value::int(value)),
          value => Ok(value),
          _ => Ok(()),
          _ => Ok(()),
          value => {
            work.val += 1
            Ok(() => @capability.Complete(value))
          },
          () => Ok(()),
          actual => {
            origins.push(actual)
            Ok(())
          },
        )
        let allowed = match exposure {
          @capability.Internal =>
            origin is @capability.Direct || origin is @capability.Gui
          @capability.Local => !(origin is @capability.RemoteMcp)
          @capability.External => true
        }
        let registry = @capability.Registry::new()
        assert_true(registry.register_async(capability) is Ok(_))
        if erased {
          let begun = registry.begin(
            "async.exposure",
            origin,
            @capability.Value::int(5),
          )
          if allowed {
            let job = mutation_ok(begun)
            assert_true(job.poll() is @capability.Pending)
            assert_true(job.poll() is @capability.Ready(_))
          } else {
            async_assert_error(begun, @diagnostics.PermissionDenied)
          }
        } else {
          let begun = capability.begin(origin, 5)
          if allowed {
            let job = mutation_ok(begun)
            assert_true(job.poll() is @capability.Pending)
            assert_true(job.poll() is @capability.Ready(5))
          } else {
            async_assert_error(begun, @diagnostics.PermissionDenied)
          }
        }
        assert_eq(work.val, if allowed { 1 } else { 0 })
        if allowed {
          assert_true(!origins.is_empty())
          for actual in origins {
            assert_true(actual == origin)
          }
        } else {
          assert_true(origins.is_empty())
        }
        if !(exposure is @capability.External) {
          assert_true(registry.external_descriptors().is_empty())
          async_assert_error(
            registry.begin_external(
              "async_exposure",
              origin,
              @capability.Value::int(5),
            ),
            @diagnostics.UnsupportedCapability,
          )
        }
      }
    }
  }
}
