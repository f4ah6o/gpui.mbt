///|
fn owned_registry(app : @core.App) -> @capability.Registry raise {
  match @capability.Registry::new_owned(app) {
    Ok(registry) => registry
    Err(_) => fail("live app should own a registry")
  }
}

///|
fn[T] assert_stale(
  result : Result[T, @diagnostics.FrameworkError],
) -> Unit raise {
  match result {
    Err(error) => {
      assert_true(error.code() is @diagnostics.StaleHandle)
      assert_true(error.subsystem() == Some("capability"))
    }
    Ok(_) => fail("stopped owner must reject the operation")
  }
}

///|
fn lifecycle_capability(
  executions : Ref[Int],
) -> @capability.TypedCapability[Int, Int] raise {
  @capability.TypedCapability::new(
    external_int_descriptor("owner.increment", @capability.Command),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
}

///|
test "app stop revokes owned registries and preexisting typed GUI handles for all origins" {
  let app = running_capability_app()
  let registry = owned_registry(app)
  let other_registry = owned_registry(app)
  let unrelated = owned_registry(running_capability_app())
  let executions = Ref(0)
  let capability = lifecycle_capability(executions)
  let copied_handle = capability
  let gui = capability.gui_binding()
  assert_true(registry.register(capability) is Ok(_))
  assert_true(gui.is_enabled())
  assert_true(gui.trigger(1) is Ok(1))
  assert_true(copied_handle.invoke(@capability.Direct, 2) is Ok(2))
  assert_true(app.request_stop() is Ok(_))
  assert_true(!app.lifetime().is_alive())
  assert_true(!registry.is_alive())
  assert_true(!other_registry.is_alive())
  assert_true(unrelated.is_alive())
  assert_true(!gui.is_enabled())
  assert_stale(gui.trigger(3))
  for
    origin in [
      @capability.Direct,
      @capability.Gui,
      @capability.LocalAutomation,
      @capability.RemoteMcp,
    ] {
    assert_stale(copied_handle.invoke(origin, 4))
    assert_stale(
      registry.invoke("owner.increment", origin, @capability.Value::int(5)),
    )
    assert_stale(
      registry.invoke_external(
        "owner_increment",
        origin,
        @capability.Value::int(6),
      ),
    )
    assert_stale(registry.authorize_external("owner_increment", origin))
  }
  assert_true(registry.descriptors().is_empty())
  assert_true(registry.external_descriptors().is_empty())
  assert_eq(
    registry.external_manifest_json(),
    "{\"schema_version\":1,\"capabilities\":[]}",
  )
  assert_stale(registry.register(lifecycle_capability(executions)))
  registry.teardown()
  registry.teardown()
  assert_true(app.request_stop() is Ok(_))
  assert_stale(copied_handle.invoke(@capability.Direct, 7))
  assert_true(executions.val == 2)
}

///|
test "adoption reaches existing handles and ownership cannot transfer or resurrect" {
  let app = running_capability_app()
  let other_app = running_capability_app()
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  let capability = lifecycle_capability(executions)
  let gui = capability.gui_binding()
  assert_true(registry.register(capability) is Ok(_))
  assert_true(registry.attach_owner(app) is Ok(_))
  assert_true(registry.attach_owner(app) is Ok(_))
  match registry.attach_owner(other_app) {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) => fail("registry ownership cannot transfer")
  }
  let second = @capability.Registry::new()
  match second.register(capability) {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) => fail("typed handles cannot have competing registry lifetimes")
  }
  assert_true(second.descriptors().is_empty())
  // Failed registration must not replace the original handle's lifetime.
  second.teardown()
  assert_true(gui.trigger(1) is Ok(1))
  assert_true(app.request_stop() is Ok(_))
  assert_stale(gui.trigger(2))
  assert_stale(registry.attach_owner(other_app))
  assert_stale(@capability.Registry::new_owned(app))
  assert_true(executions.val == 1)
}

///|
test "stop before app start and explicit standalone teardown revoke typed handles" {
  let app = match @core.App::new() {
    Ok(app) => app
    Err(_) => fail("app allocation should succeed")
  }
  let registry = owned_registry(app)
  let capability = lifecycle_capability(Ref(0))
  assert_true(registry.register(capability) is Ok(_))
  assert_true(app.request_stop() is Ok(_))
  assert_stale(capability.invoke(@capability.Direct, 1))
  let standalone = @capability.Registry::new()
  let other = lifecycle_capability(Ref(0))
  assert_true(standalone.register(other) is Ok(_))
  standalone.teardown()
  standalone.teardown()
  assert_stale(other.invoke(@capability.Direct, 1))
  assert_true(!other.gui_binding().is_enabled())
}

///|
test "owner shutdown during every callback rejects late results and stops the remaining stages" {
  // Typed and GUI calls skip transport projection; erased calls exercise it.
  for
    origin in [
      @capability.Direct,
      @capability.Gui,
      @capability.LocalAutomation,
      @capability.RemoteMcp,
    ] {
    let stages = if origin is @capability.Direct || origin is @capability.Gui {
      ["availability", "policy", "input", "handler", "output"]
    } else {
      [
        "availability", "policy", "decode", "input", "handler", "output", "encode",
      ]
    }
    for stop_at in stages {
      let app = running_capability_app()
      let registry = owned_registry(app)
      let visited : Array[String] = []
      let step = fn(stage : String) {
        visited.push(stage)
        if stage == stop_at {
          ignore(app.request_stop())
          ignore(app.request_stop())
        }
      }
      let capability = @capability.TypedCapability::new_with_validation(
        external_int_descriptor("owner.stages", @capability.Command),
        value => {
          step("decode")
          value.as_int()
        },
        value => {
          step("encode")
          Ok(@capability.Value::int(value))
        },
        _value => {
          step("input")
          Ok(())
        },
        _value => {
          step("output")
          Ok(())
        },
        value => {
          step("handler")
          Ok(value)
        },
        () => {
          step("availability")
          Ok(())
        },
        _origin => {
          step("policy")
          Ok(())
        },
      )
      assert_true(registry.register(capability) is Ok(_))
      match origin {
        @capability.Direct => assert_stale(capability.invoke(origin, 1))
        @capability.Gui => assert_stale(capability.gui_binding().trigger(1))
        _ =>
          assert_stale(
            registry.invoke("owner.stages", origin, @capability.Value::int(1)),
          )
      }
      assert_eq(visited[visited.length() - 1], stop_at)
      assert_eq(visited.length(), stages.search(stop_at).unwrap() + 1)
      assert_stale(capability.invoke(@capability.Direct, 2))
    }
  }
}

///|
test "stop within an app update revokes registry before deferred entity disposal" {
  let app = running_capability_app()
  let entity = match app.create_entity(0) {
    Ok(entity) => entity
    Err(_) => fail("entity creation should succeed")
  }
  let registry = owned_registry(app)
  let executions = Ref(0)
  let capability = lifecycle_capability(executions)
  assert_true(registry.register(capability) is Ok(_))
  let rejected_while_entity_live = Ref(false)
  assert_true(
    app.update(entity, _context => {
      ignore(app.request_stop())
      ignore(app.request_stop())
      rejected_while_entity_live.val = entity.is_live() &&
        !registry.is_alive() &&
        capability.invoke(@capability.Direct, 1) is Err(_)
      Ok(())
    })
    is Ok(_),
  )
  assert_true(rejected_while_entity_live.val)
  assert_true(app.lifecycle() is @core.Stopping)
  assert_true(app.run_ready(8) is Ok(_))
  assert_true(app.lifecycle() is @core.Stopped)
  assert_true(!entity.is_live())
  assert_true(executions.val == 0)
}

///|
test "owned registry configures before start but typed GUI and erased calls await Running" {
  let app = match @core.App::new() {
    Ok(app) => app
    Err(_) => fail("app allocation should succeed")
  }
  let registry = owned_registry(app)
  let executions = Ref(0)
  let capability = lifecycle_capability(executions)
  assert_true(registry.register(capability) is Ok(_))
  assert_true(registry.is_alive())
  assert_true(!capability.gui_binding().is_enabled())
  for
    origin in [
      @capability.Direct,
      @capability.Gui,
      @capability.LocalAutomation,
      @capability.RemoteMcp,
    ] {
    match capability.invoke(origin, 1) {
      Err(error) => assert_true(error.code() is @diagnostics.AppNotRunning)
      Ok(_) => fail("new owner cannot execute typed operations")
    }
    match
      registry.invoke("owner.increment", origin, @capability.Value::int(1)) {
      Err(error) => assert_true(error.code() is @diagnostics.AppNotRunning)
      Ok(_) => fail("new owner cannot execute erased operations")
    }
  }
  assert_true(executions.val == 0)
  assert_true(app.start() is Ok(_))
  assert_true(app.lifetime().is_running())
  assert_true(capability.gui_binding().trigger(1) is Ok(1))
  assert_true(executions.val == 1)
  assert_true(app.request_stop() is Ok(_))
  assert_true(!app.lifetime().is_running())
  assert_stale(capability.invoke(@capability.Direct, 1))
}

///|
test "standalone teardown inside availability is reentrant and leaves no callable typed handle" {
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  let capability = @capability.TypedCapability::new(
    external_int_descriptor("owner.dispose", @capability.Command),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => {
      registry.teardown()
      registry.teardown()
      Ok(())
    },
    _origin => Ok(()),
  )
  assert_true(registry.register(capability) is Ok(_))
  assert_stale(
    registry.invoke(
      "owner.dispose",
      @capability.Direct,
      @capability.Value::int(1),
    ),
  )
  assert_stale(capability.gui_binding().trigger(2))
  match @capability.Registry::new().register(capability) {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) => fail("dead typed handles cannot be rebound to a new registry")
  }
  assert_true(executions.val == 0)
}
