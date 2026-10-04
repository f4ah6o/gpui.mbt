///|
fn running_mcp_app() -> @core.App raise {
  let app = match @core.App::new() {
    Ok(value) => value
    Err(_) => fail("app allocation should succeed")
  }
  match app.start() {
    Ok(_) => app
    Err(_) => fail("app should start")
  }
}

///|
fn mcp_command_descriptor(
  id : String,
  exposure : @capability.Exposure,
) -> @capability.Descriptor {
  match
    @capability.Descriptor::new(
      id,
      id,
      "semantic write",
      @capability.Command,
      @capability.Schema::int(),
      @capability.Schema::int(),
      @capability.StateChange,
      false,
      exposure,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => abort("valid descriptor rejected")
  }
}

///|
fn mcp_query_descriptor(id : String) -> @capability.Descriptor {
  match
    @capability.Descriptor::new(
      id,
      id,
      "semantic read",
      @capability.Query,
      @capability.Schema::unit(),
      @capability.Schema::int(),
      @capability.ReadOnly,
      true,
      @capability.External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => abort("valid descriptor rejected")
  }
}

///|
fn install_fixture(
  app : @core.App,
  entity : @core.Entity[Int],
  notifications : Ref[Int],
) -> (
  @capability.Registry,
  @capability.TypedCapability[Int, Int],
  @capability.TypedCapability[Unit, Int],
) {
  let owner = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => abort("observer entity creation should succeed")
  }
  match
    app.update(owner, context => {
      match
        context.subscribe(entity, event => {
          if event.kind() is @core.Changed {
            notifications.val += 1
          }
          Ok(())
        }) {
        Ok(_) => Ok(())
        Err(error) => Err(error)
      }
    }) {
    Ok(_) => ()
    Err(_) => abort("fixture subscription should succeed")
  }
  let command = @capability.TypedCapability::new(
    mcp_command_descriptor("document.rename", @capability.External),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      match
        app.update(entity, context => {
          match context.set(value) {
            Err(error) => Err(error)
            Ok(_) => context.notify()
          }
        }) {
        Err(error) => Err(error)
        Ok(_) => app.read(entity, current => current)
      }
    },
    () => {
      if entity.is_live() {
        Ok(())
      } else {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.EntityNotLive,
            "document.rename",
          ),
        )
      }
    },
    _origin => Ok(()),
  )
  let query = @capability.TypedCapability::new(
    mcp_query_descriptor("document.current"),
    _value => Ok(()),
    value => Ok(@capability.Value::int(value)),
    _unit => app.read(entity, current => current),
    () => {
      if entity.is_live() {
        Ok(())
      } else {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.EntityNotLive,
            "document.current",
          ),
        )
      }
    },
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  match registry.register(command) {
    Ok(_) => ()
    Err(_) => abort("command registration should succeed")
  }
  match registry.register(query) {
    Ok(_) => ()
    Err(_) => abort("query registration should succeed")
  }
  (registry, command, query)
}

///|
fn run_lane(lane : Int, value : Int) -> (Int, Int, Int) raise {
  let app = running_mcp_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let notifications = Ref(0)
  let (registry, command, _query) = install_fixture(app, entity, notifications)
  let result = match lane {
    0 =>
      match command.gui_binding().trigger(value) {
        Ok(actual) => actual
        Err(_) => fail("GUI lane failed")
      }
    1 =>
      match command.invoke(@capability.Direct, value) {
        Ok(actual) => actual
        Err(_) => fail("direct lane failed")
      }
    _ => {
      let adapter = @mcp.Adapter::new(registry)
      match
        adapter.call_tool("document_rename", @capability.Value::int(value)) {
        Ok(@capability.IntValue(actual)) => actual
        _ => fail("MCP lane failed")
      }
    }
  }
  assert_true(app.run_ready(16) is Ok(1))
  let state = match app.read(entity, current => current) {
    Ok(actual) => actual
    Err(_) => fail("state read failed")
  }
  (result, state, notifications.val)
}

///|
test "generated inventory is deterministic and default-safe" {
  let app = running_mcp_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let notifications = Ref(0)
  let (first, command, query) = install_fixture(app, entity, notifications)
  let internal = @capability.TypedCapability::new(
    mcp_command_descriptor("internal.reset", @capability.Internal),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => Ok(value),
    () => Ok(()),
    _origin => Ok(()),
  )
  assert_true(first.register(internal) is Ok(_))

  let second = @capability.Registry::new()
  assert_true(second.register(query) is Ok(_))
  assert_true(second.register(internal) is Ok(_))
  assert_true(second.register(command) is Ok(_))

  let first_inventory = match @mcp.Adapter::new(first).inventory() {
    Ok(value) => value
    Err(_) => fail("inventory generation failed")
  }
  let second_inventory = match @mcp.Adapter::new(second).inventory() {
    Ok(value) => value
    Err(_) => fail("inventory generation failed")
  }
  assert_eq(first_inventory.canonical_json(), second_inventory.canonical_json())
  assert_true(first_inventory.supports_tools())
  assert_true(first_inventory.supports_resources())
  assert_true(!first_inventory.supports_prompts())
  let tools = first_inventory.tools()
  let resources = first_inventory.resources()
  assert_true(tools.length() == 1)
  assert_eq(tools[0].name(), "document_rename")
  assert_eq(tools[0].semantic_id(), "document.rename")
  assert_true(resources.length() == 1)
  assert_eq(resources[0].uri(), "gpui://capability/document_current")
  assert_eq(resources[0].semantic_id(), "document.current")
}

///|
test "GUI direct and MCP lanes converge on semantic state and notifications" {
  let gui = run_lane(0, 41)
  let direct = run_lane(1, 41)
  let mcp = run_lane(2, 41)
  assert_eq(gui, direct)
  assert_eq(direct, mcp)
}

///|
test "MCP resource reads observe state changed through ordinary capability path" {
  let app = running_mcp_app()
  let entity = match app.create_entity(3) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let notifications = Ref(0)
  let (registry, command, _query) = install_fixture(app, entity, notifications)
  let adapter = @mcp.Adapter::new(registry)
  assert_true(command.invoke(@capability.Direct, 12) is Ok(12))
  assert_true(app.run_ready(16) is Ok(1))
  assert_true(
    adapter.read_resource("gpui://capability/document_current")
    is Ok(@capability.IntValue(12)),
  )
  assert_true(notifications.val == 1)
}

///|
test "MCP boundary preserves invalid input policy and lifecycle failures" {
  let app = running_mcp_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let notifications = Ref(0)
  let (registry, _command, _query) = install_fixture(app, entity, notifications)
  let adapter = @mcp.Adapter::new(registry)

  match
    adapter.call_tool("document_rename", @capability.Value::string("wrong")) {
    Err(error) => assert_true(error.code() is @mcp.InvalidInput)
    Ok(_) => fail("invalid input must fail before domain execution")
  }

  let denied_descriptor = mcp_command_descriptor(
    "document.remote-denied",
    @capability.External,
  )
  let denied = @capability.TypedCapability::new(
    denied_descriptor,
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => Ok(value),
    () => Ok(()),
    origin => {
      if origin is @capability.RemoteMcp {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.PermissionDenied,
            "remote policy",
          ),
        )
      } else {
        Ok(())
      }
    },
  )
  assert_true(registry.register(denied) is Ok(_))
  match adapter.call_tool("document_remote_denied", @capability.Value::int(1)) {
    Err(error) => assert_true(error.code() is @mcp.PermissionDenied)
    Ok(_) => fail("remote policy denial must cross the adapter boundary")
  }

  assert_true(app.destroy_entity(entity) is Ok(_))
  assert_true(app.run_ready(16) is Ok(_))
  match adapter.call_tool("document_rename", @capability.Value::int(2)) {
    Err(error) => assert_true(error.code() is @mcp.Stale)
    Ok(_) => fail("released owner must not remain callable")
  }

  adapter.close()
  match adapter.inventory() {
    Err(error) => assert_true(error.code() is @mcp.AdapterClosed)
    Ok(_) => fail("closed adapter must reject inventory access")
  }
}

///|
fn sequence_parity(commands : Array[Int]) -> Bool {
  let direct_app = match @core.App::new() {
    Ok(value) => value
    Err(_) => return false
  }
  let remote_app = match @core.App::new() {
    Ok(value) => value
    Err(_) => return false
  }
  if direct_app.start() is Err(_) || remote_app.start() is Err(_) {
    return false
  }
  let direct_entity = match direct_app.create_entity(0) {
    Ok(value) => value
    Err(_) => return false
  }
  let remote_entity = match remote_app.create_entity(0) {
    Ok(value) => value
    Err(_) => return false
  }
  let direct_notifications = Ref(0)
  let remote_notifications = Ref(0)
  let (_direct_registry, direct_command, direct_query) = install_fixture(
    direct_app, direct_entity, direct_notifications,
  )
  let (remote_registry, _remote_command, _remote_query) = install_fixture(
    remote_app, remote_entity, remote_notifications,
  )
  let adapter = @mcp.Adapter::new(remote_registry)

  for command in commands {
    let normalized = if command < 0 { -command } else { command }
    if normalized % 3 == 0 {
      let value = command % 1000
      let direct_result = direct_command.invoke(@capability.Direct, value)
      let remote_result = adapter.call_tool(
        "document_rename",
        @capability.Value::int(value),
      )
      match (direct_result, remote_result) {
        (Ok(left), Ok(@capability.IntValue(right))) if left == right => ()
        _ => return false
      }
      if direct_app.run_ready(16) is Err(_) ||
        remote_app.run_ready(16) is Err(_) {
        return false
      }
    } else {
      let direct_result = direct_query.invoke(@capability.Direct, ())
      let remote_result = adapter.read_resource(
        "gpui://capability/document_current",
      )
      match (direct_result, remote_result) {
        (Ok(left), Ok(@capability.IntValue(right))) if left == right => ()
        _ => return false
      }
    }
    match
      (
        direct_app.read(direct_entity, current => current),
        remote_app.read(remote_entity, current => current),
      ) {
      (Ok(left), Ok(right)) if left == right => ()
      _ => return false
    }
    if direct_notifications.val != remote_notifications.val {
      return false
    }
  }
  true
}

///|
// Stable suite ID: capability-mcp-parity
test "quickcheck: direct and MCP semantic sequences remain equivalent" {
  @quickcheck.check(
    (commands : Array[Int]) => sequence_parity(commands),
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=99845120733210913,
  )
}
