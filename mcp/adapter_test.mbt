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
/// A test-only observation model shared by GUI, direct, and adapter lanes.
/// It intentionally records semantic state and notifications, not renderer or
/// protocol framing details.
priv struct SemanticTrace {
  capability_id : String
  input_json : String
  accepted : Bool
  state_before_json : String
  state_after_json : String
  revision_before : UInt64
  revision_after : UInt64
  notifications : Int
  result_json : String
} derive(Eq)

///|
fn run_lane(lane : Int, value : Int) -> SemanticTrace raise {
  let app = running_mcp_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let notifications = Ref(0)
  let (registry, command, _query) = install_fixture(app, entity, notifications)
  let state_before = match app.read(entity, current => current) {
    Ok(actual) => actual
    Err(_) => fail("initial state read failed")
  }
  let revision_before = match app.revision(entity) {
    Ok(actual) => actual
    Err(_) => fail("initial revision read failed")
  }
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
  let revision_after = match app.revision(entity) {
    Ok(actual) => actual
    Err(_) => fail("updated revision read failed")
  }
  {
    capability_id: "document.rename",
    input_json: @capability.Value::int(value).canonical_json(),
    accepted: true,
    state_before_json: @capability.Value::int(state_before).canonical_json(),
    state_after_json: @capability.Value::int(state).canonical_json(),
    revision_before,
    revision_after,
    notifications: notifications.val,
    result_json: @capability.Value::int(result).canonical_json(),
  }
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
test "resource-only query cannot be invoked through tool dispatch" {
  let app = running_mcp_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let notifications = Ref(0)
  let (registry, _command, _query) = install_fixture(app, entity, notifications)
  let adapter = @mcp.Adapter::new(registry)
  match adapter.call_tool("document_current", @capability.Value::unit()) {
    Err(error) => assert_true(error.code() is @mcp.UnknownOperation)
    Ok(_) => fail("resource-only capability must not be callable as a tool")
  }
}

///|
test "output projection failure is separate and records post-handler effects" {
  let executions = Ref(0)
  let descriptor = mcp_command_descriptor(
    "document.invalid-output",
    @capability.External,
  )
  let capability = @capability.TypedCapability::new(
    descriptor,
    value => value.as_int(),
    value => Ok(@capability.Value::string("\{value}")),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(capability) is Ok(_))
  assert_true(capability.invoke(@capability.Direct, 7) is Ok(7))
  assert_true(executions.val == 1)

  executions.val = 0
  let adapter = @mcp.Adapter::new(registry)
  match
    adapter.call_tool("document_invalid_output", @capability.Value::int(7)) {
    Err(error) => assert_true(error.code() is @mcp.ProjectionFailed)
    Ok(_) => fail("invalid adapter projection must be reported explicitly")
  }
  // The domain handler has already run. A transport conversion failure cannot
  // imply rollback, so retry policy must treat this result as ambiguous.
  assert_true(executions.val == 1)
}

///|
test "domain validation failure is equivalent across GUI direct and MCP" {
  let app = running_mcp_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let executions = Ref(0)
  let capability = @capability.TypedCapability::new_with_validation(
    mcp_command_descriptor("document.rename", @capability.External),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      if value < 0 {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.InvalidInput,
            "document.rename",
            subsystem="domain",
            message="rename value must be non-negative",
          ),
        )
      } else {
        Ok(())
      }
    },
    _output => Ok(()),
    value => {
      executions.val += 1
      match app.update(entity, context => context.set(value)) {
        Err(error) => Err(error)
        Ok(_) => app.read(entity, current => current)
      }
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(capability) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)

  let gui = capability.gui_binding().trigger(-3)
  let direct = capability.invoke(@capability.Direct, -3)
  let remote = adapter.call_tool("document_rename", @capability.Value::int(-3))
  match gui {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) => fail("GUI binding must return domain validation error")
  }
  match direct {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) => fail("direct invocation must return domain validation error")
  }
  match remote {
    Err(error) => assert_true(error.code() is @mcp.InvalidInput)
    Ok(_) => fail("MCP invocation must return domain validation error")
  }
  assert_true(executions.val == 0)
  assert_true(app.read(entity, current => current) is Ok(0))
}

///|
test "GUI direct and MCP lanes converge on semantic state and notifications" {
  let gui = run_lane(0, 41)
  let direct = run_lane(1, 41)
  let mcp = run_lane(2, 41)
  assert_true(gui == direct)
  assert_true(direct == mcp)
  assert_eq(gui.capability_id, "document.rename")
  assert_true(gui.accepted)
  assert_eq(gui.revision_before, 0)
  assert_eq(gui.revision_after, 1)
  assert_eq(gui.notifications, 1)
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
test "request replay rechecks policy and lifecycle without repeating the handler" {
  let allowed = Ref(true)
  let policy_checks = Ref(0)
  let executions = Ref(0)
  let capability = @capability.TypedCapability::new(
    mcp_command_descriptor("document.rename", @capability.External),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => Ok(()),
    _origin => {
      policy_checks.val += 1
      if allowed.val {
        Ok(())
      } else {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.PermissionDenied,
            "document.rename",
            subsystem="test-policy",
            message="remote permission was revoked",
          ),
        )
      }
    },
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(capability) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)

  assert_true(
    adapter.call_tool_with_request_id(
      "rename-1",
      "document_rename",
      @capability.Value::int(7),
    )
    is Ok(@capability.IntValue(7)),
  )
  // A new request goes through the shared invocation check exactly once.
  assert_true(policy_checks.val == 1)
  assert_true(executions.val == 1)

  assert_true(
    adapter.call_tool_with_request_id(
      "rename-1",
      "document_rename",
      @capability.Value::int(7),
    )
    is Ok(@capability.IntValue(7)),
  )
  assert_true(policy_checks.val == 2)
  assert_true(executions.val == 1)

  allowed.val = false
  match
    adapter.call_tool_with_request_id(
      "rename-1",
      "document_rename",
      @capability.Value::int(7),
    ) {
    Err(error) => assert_true(error.code() is @mcp.PermissionDenied)
    Ok(_) => fail("a revoked policy must prevent cached-result disclosure")
  }
  assert_true(policy_checks.val == 3)
  assert_true(executions.val == 1)

  registry.teardown()
  match
    adapter.call_tool_with_request_id(
      "rename-1",
      "document_rename",
      @capability.Value::int(7),
    ) {
    Err(error) => assert_true(error.code() is @mcp.Stale)
    Ok(_) => fail("a torn down registry must not replay cached output")
  }
  assert_true(executions.val == 1)
}

///|
test "request fingerprint and dispatch use an owned input snapshot" {
  let shared_values : Array[@capability.Value] = [@capability.Value::int(1)]
  let descriptor = match
    @capability.Descriptor::new(
      "document.echo",
      "document.echo",
      "echo the first integer",
      @capability.Command,
      @capability.Schema::array(@capability.Schema::int()),
      @capability.Schema::int(),
      @capability.StateChange,
      false,
      @capability.External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("valid array capability descriptor rejected")
  }
  let executions = Ref(0)
  let capability = @capability.TypedCapability::new(
    descriptor,
    value => {
      match value.as_array() {
        Err(error) => Err(error)
        Ok(values) => values[0].as_int()
      }
    },
    value => Ok(@capability.Value::int(value)),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => Ok(()),
    _origin => {
      // Simulate application code holding an alias to the caller's public
      // mutable array and changing it while authorization runs.
      shared_values[0] = @capability.Value::int(2)
      Ok(())
    },
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(capability) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)
  let original = @capability.ArrayValue(shared_values)
  assert_true(
    adapter.call_tool_with_request_id("echo-1", "document_echo", original)
    is Ok(@capability.IntValue(1)),
  )
  assert_true(shared_values[0] is @capability.IntValue(2))

  // Re-sending the original semantic input finds the cached result, even
  // though the aliased caller storage was mutated during the first request.
  assert_true(
    adapter.call_tool_with_request_id(
      "echo-1",
      "document_echo",
      @capability.Value::array([@capability.Value::int(1)]),
    )
    is Ok(@capability.IntValue(1)),
  )
  assert_true(executions.val == 1)
}

///|
test "same-id reentrancy is rejected before a second handler execution" {
  let adapter_slot : Ref[@mcp.Adapter?] = Ref(None)
  let nested_code : Ref[@mcp.ErrorCode?] = Ref(None)
  let executions = Ref(0)
  let capability = @capability.TypedCapability::new(
    mcp_command_descriptor("document.reentrant", @capability.External),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      executions.val += 1
      match adapter_slot.val {
        None => nested_code.val = Some(@mcp.DomainFailure)
        Some(adapter) =>
          match
            adapter.call_tool_with_request_id(
              "reentrant-1",
              "document_reentrant",
              @capability.Value::int(value),
            ) {
            Err(error) => nested_code.val = Some(error.code())
            Ok(_) => nested_code.val = Some(@mcp.DomainFailure)
          }
      }
      Ok(value)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(capability) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)
  adapter_slot.val = Some(adapter)
  assert_true(
    adapter.call_tool_with_request_id(
      "reentrant-1",
      "document_reentrant",
      @capability.Value::int(11),
    )
    is Ok(@capability.IntValue(11)),
  )
  assert_true(nested_code.val is Some(@mcp.RequestInProgress))
  assert_true(executions.val == 1)
  match
    adapter.call_tool_with_request_id(
      "reentrant-1",
      "document_reentrant",
      @capability.Value::int(12),
    ) {
    Err(error) => assert_true(error.code() is @mcp.RequestConflict)
    Ok(_) => fail("a request id cannot be reused with different arguments")
  }
  assert_true(executions.val == 1)
}

///|
test "closing during a request reports ambiguous committed effects" {
  let adapter_slot : Ref[@mcp.Adapter?] = Ref(None)
  let executions = Ref(0)
  let capability = @capability.TypedCapability::new(
    mcp_command_descriptor("document.close", @capability.External),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      executions.val += 1
      match adapter_slot.val {
        None =>
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.StaleHandle,
              "adapter.close.fixture",
            ),
          )
        Some(adapter) => {
          adapter.close()
          Ok(value)
        }
      }
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(capability) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)
  adapter_slot.val = Some(adapter)
  match
    adapter.call_tool_with_request_id(
      "close-1",
      "document_close",
      @capability.Value::int(13),
    ) {
    Err(error) => {
      assert_true(error.code() is @mcp.AdapterClosed)
      assert_true(error.message().contains("may already be committed"))
    }
    Ok(_) => fail("close during handler must report the ambiguous outcome")
  }
  assert_true(executions.val == 1)
  assert_true(!adapter.is_open())
}

///|
test "oversized successful outcomes leave a no-reexecution tombstone" {
  let text = StringBuilder()
  let mut index = 0
  while index < 262_143 {
    text.write_char('x')
    index += 1
  }
  let output = text.to_string()
  let descriptor = match
    @capability.Descriptor::new(
      "document.large",
      "document.large",
      "large result fixture",
      @capability.Command,
      @capability.Schema::int(),
      @capability.Schema::string(),
      @capability.StateChange,
      false,
      @capability.External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("valid large-output descriptor rejected")
  }
  let executions = Ref(0)
  let capability = @capability.TypedCapability::new(
    descriptor,
    value => value.as_int(),
    value => Ok(@capability.Value::string(value)),
    _value => {
      executions.val += 1
      Ok(output)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(capability) is Ok(_))
  let adapter = @mcp.Adapter::new(registry)
  assert_true(
    adapter.call_tool_with_request_id(
      "large-1",
      "document_large",
      @capability.Value::int(1),
    )
    is Ok(@capability.StringValue(_)),
  )
  match
    adapter.call_tool_with_request_id(
      "large-1",
      "document_large",
      @capability.Value::int(1),
    ) {
    Err(error) => assert_true(error.code() is @mcp.OutcomeNotRetained)
    Ok(_) => fail("large output must not be retained in the replay cache")
  }
  assert_true(executions.val == 1)
}

///|
priv struct CrudCapabilities {
  registry : @capability.Registry
  create : @capability.TypedCapability[String, String]
  rename : @capability.TypedCapability[String, String]
  delete : @capability.TypedCapability[Unit, Bool]
}

///|
fn crud_descriptor(
  id : String,
  input : @capability.Schema,
  output : @capability.Schema,
) -> @capability.Descriptor raise {
  match
    @capability.Descriptor::new(
      id,
      id,
      "document CRUD conformance fixture",
      @capability.Command,
      input,
      output,
      @capability.StateChange,
      false,
      @capability.External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("valid CRUD descriptor rejected")
  }
}

///|
fn document_present(
  app : @core.App,
  entity : @core.Entity[Array[String]],
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match app.read(entity, names => names.length()) {
    Err(error) => Err(error)
    Ok(count) if count > 0 => Ok(())
    Ok(_) =>
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.AppNotRunning,
          operation,
          subsystem="document-availability",
          message="no document is available",
        ),
      )
  }
}

///|
fn update_document_names(
  app : @core.App,
  entity : @core.Entity[Array[String]],
  names : Array[String],
  effect : String,
  side_effects : Ref[Array[String]],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match
    app.update(entity, context => {
      match context.set(names) {
        Err(error) => Err(error)
        Ok(_) => context.notify()
      }
    }) {
    Err(error) => Err(error)
    Ok(_) => {
      side_effects.val.push(effect)
      Ok(())
    }
  }
}

///|
fn install_crud_capabilities(
  app : @core.App,
  entity : @core.Entity[Array[String]],
  side_effects : Ref[Array[String]],
) -> CrudCapabilities raise {
  let nonempty_name : (String) -> Result[Unit, @diagnostics.FrameworkError] = name => {
    if name.length() == 0 {
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "document.name",
          subsystem="domain",
          message="document name must not be empty",
        ),
      )
    } else {
      Ok(())
    }
  }
  let encode_string : (String) -> Result[
    @capability.Value,
    @diagnostics.FrameworkError,
  ] = value => Ok(@capability.Value::string(value))
  let decode_string : (@capability.Value) -> Result[
    String,
    @diagnostics.FrameworkError,
  ] = value => value.as_string()
  let create = @capability.TypedCapability::new_with_validation(
    crud_descriptor(
      "document.create",
      @capability.Schema::string(),
      @capability.Schema::string(),
    ),
    decode_string,
    encode_string,
    nonempty_name,
    _output => Ok(()),
    name => {
      match app.read(entity, names => names.length()) {
        Err(error) => Err(error)
        Ok(count) if count > 0 =>
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "document.create",
              subsystem="domain",
              message="a document already exists",
            ),
          )
        Ok(_) => {
          let new_names : Array[String] = [name]
          match
            update_document_names(
              app,
              entity,
              new_names,
              "create:\{name}",
              side_effects,
            ) {
            Err(error) => Err(error)
            Ok(_) => Ok(name)
          }
        }
      }
    },
    () => {
      match app.read(entity, names => names.length()) {
        Err(error) => Err(error)
        Ok(count) if count == 0 => Ok(())
        Ok(_) =>
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.Busy,
              "document.create",
              message="document already exists",
            ),
          )
      }
    },
    _origin => Ok(()),
  )
  let rename = @capability.TypedCapability::new_with_validation(
    crud_descriptor(
      "document.rename",
      @capability.Schema::string(),
      @capability.Schema::string(),
    ),
    decode_string,
    encode_string,
    nonempty_name,
    _output => Ok(()),
    name => {
      match app.read(entity, names => names.length()) {
        Err(error) => Err(error)
        Ok(count) if count == 0 =>
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "document.rename",
              subsystem="domain",
              message="document does not exist",
            ),
          )
        Ok(_) => {
          let names : Array[String] = [name]
          match
            update_document_names(
              app,
              entity,
              names,
              "rename:\{name}",
              side_effects,
            ) {
            Err(error) => Err(error)
            Ok(_) => Ok(name)
          }
        }
      }
    },
    () => document_present(app, entity, "document.rename"),
    _origin => Ok(()),
  )
  let delete = @capability.TypedCapability::new(
    crud_descriptor(
      "document.delete",
      @capability.Schema::unit(),
      @capability.Schema::bool(),
    ),
    _input => Ok(()),
    _output => Ok(@capability.Value::bool(true)),
    _unit => {
      match update_document_names(app, entity, [], "delete", side_effects) {
        Err(error) => Err(error)
        Ok(_) => Ok(true)
      }
    },
    () => document_present(app, entity, "document.delete"),
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(create) is Ok(_))
  assert_true(registry.register(rename) is Ok(_))
  assert_true(registry.register(delete) is Ok(_))
  { registry, create, rename, delete, }
}

///|
fn invoke_string_lane(
  lane : Int,
  capability : @capability.TypedCapability[String, String],
  adapter : @mcp.Adapter,
  external_name : String,
  input : String,
) -> String raise {
  match lane {
    0 =>
      match capability.gui_binding().trigger(input) {
        Ok(value) => value
        Err(_) => fail("GUI CRUD operation should succeed")
      }
    1 =>
      match capability.invoke(@capability.Direct, input) {
        Ok(value) => value
        Err(_) => fail("direct CRUD operation should succeed")
      }
    _ =>
      match adapter.call_tool(external_name, @capability.Value::string(input)) {
        Ok(@capability.StringValue(value)) => value
        _ => fail("MCP CRUD operation should succeed")
      }
  }
}

///|
fn invoke_delete_lane(
  lane : Int,
  capability : @capability.TypedCapability[Unit, Bool],
  adapter : @mcp.Adapter,
) -> Bool raise {
  match lane {
    0 =>
      match capability.gui_binding().trigger(()) {
        Ok(value) => value
        Err(_) => fail("GUI delete should succeed")
      }
    1 =>
      match capability.invoke(@capability.Direct, ()) {
        Ok(value) => value
        Err(_) => fail("direct delete should succeed")
      }
    _ =>
      match adapter.call_tool("document_delete", @capability.Value::unit()) {
        Ok(@capability.BoolValue(value)) => value
        _ => fail("MCP delete should succeed")
      }
  }
}

///|
priv struct CrudTrace {
  operation_ids : String
  initial_state_json : String
  final_state_json : String
  results_json : String
  revision_before : UInt64
  revision_after : UInt64
  notifications : Int
  side_effect_count : Int
  side_effects_json : String
} derive(Eq)

///|
fn run_crud_lane(lane : Int) -> CrudTrace raise {
  let app = running_mcp_app()
  let initial_names : Array[String] = []
  let entity = match app.create_entity(initial_names) {
    Ok(value) => value
    Err(_) => fail("CRUD fixture entity creation should succeed")
  }
  let owner = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("CRUD observer entity creation should succeed")
  }
  let notifications = Ref(0)
  assert_true(
    app.update(owner, context => {
      match
        context.subscribe(entity, event => {
          if event.kind() is @core.Changed {
            notifications.val += 1
          }
          Ok(())
        }) {
        Err(error) => Err(error)
        Ok(_) => Ok(())
      }
    })
    is Ok(_),
  )
  let side_effects : Ref[Array[String]] = Ref([])
  let capabilities = install_crud_capabilities(app, entity, side_effects)
  let adapter = @mcp.Adapter::new(capabilities.registry)
  let before = match app.revision(entity) {
    Ok(value) => value
    Err(_) => fail("initial CRUD revision read should succeed")
  }
  let created = invoke_string_lane(
    lane,
    capabilities.create,
    adapter,
    "document_create",
    "draft",
  )
  assert_true(app.run_ready(16) is Ok(1))
  let renamed = invoke_string_lane(
    lane,
    capabilities.rename,
    adapter,
    "document_rename",
    "published",
  )
  assert_true(app.run_ready(16) is Ok(1))
  let deleted = invoke_delete_lane(lane, capabilities.delete, adapter)
  assert_true(app.run_ready(16) is Ok(1))
  let final_names = match app.read(entity, names => names) {
    Ok(value) => value
    Err(_) => fail("final CRUD state read should succeed")
  }
  let after = match app.revision(entity) {
    Ok(value) => value
    Err(_) => fail("final CRUD revision read should succeed")
  }
  {
    operation_ids: "document.create,document.rename,document.delete",
    initial_state_json: @capability.Value::array([]).canonical_json(),
    final_state_json: @capability.Value::array(
      final_names.map(name => @capability.Value::string(name)),
    ).canonical_json(),
    results_json: @capability.Value::array([
      @capability.Value::string(created),
      @capability.Value::string(renamed),
      @capability.Value::bool(deleted),
    ]).canonical_json(),
    revision_before: before,
    revision_after: after,
    notifications: notifications.val,
    side_effect_count: side_effects.val.length(),
    side_effects_json: @capability.Value::array(
      side_effects.val.map(effect => @capability.Value::string(effect)),
    ).canonical_json(),
  }
}

///|
test "CRUD semantic trace and committed side effects agree across GUI direct and MCP" {
  let gui = run_crud_lane(0)
  let direct = run_crud_lane(1)
  let remote = run_crud_lane(2)
  assert_true(gui == direct)
  assert_true(direct == remote)
  assert_eq(
    gui.operation_ids,
    "document.create,document.rename,document.delete",
  )
  assert_eq(gui.initial_state_json, "[]")
  assert_eq(gui.final_state_json, "[]")
  assert_eq(gui.results_json, "[\"draft\",\"published\",true]")
  assert_eq(gui.revision_before, 0)
  assert_eq(gui.revision_after, 3)
  assert_eq(gui.notifications, 3)
  assert_eq(gui.side_effect_count, 3)
  assert_eq(
    gui.side_effects_json,
    "[\"create:draft\",\"rename:published\",\"delete\"]",
  )
}

///|
test "CRUD availability failures agree before any side effect" {
  let outcomes : Array[@mcp.ErrorCode] = []
  for lane in [0, 1, 2] {
    let app = running_mcp_app()
    let initial_names : Array[String] = []
    let entity = match app.create_entity(initial_names) {
      Ok(value) => value
      Err(_) => fail("CRUD fixture entity creation should succeed")
    }
    let side_effects : Ref[Array[String]] = Ref([])
    let capabilities = install_crud_capabilities(app, entity, side_effects)
    let adapter = @mcp.Adapter::new(capabilities.registry)
    match lane {
      0 =>
        match capabilities.rename.gui_binding().trigger("missing") {
          Err(error) => {
            assert_true(error.code() is @diagnostics.AppNotRunning)
            outcomes.push(@mcp.Unavailable)
          }
          Ok(_) => fail("GUI rename must be unavailable before creation")
        }
      1 =>
        match capabilities.rename.invoke(@capability.Direct, "missing") {
          Err(error) => {
            assert_true(error.code() is @diagnostics.AppNotRunning)
            outcomes.push(@mcp.Unavailable)
          }
          Ok(_) => fail("direct rename must be unavailable before creation")
        }
      _ =>
        match
          adapter.call_tool(
            "document_rename",
            @capability.Value::string("missing"),
          ) {
          Err(error) => {
            assert_true(error.code() is @mcp.Unavailable)
            outcomes.push(error.code())
          }
          Ok(_) => fail("MCP rename must be unavailable before creation")
        }
    }
    assert_true(side_effects.val.length() == 0)
    assert_true(app.read(entity, names => names.length()) is Ok(0))
  }
  assert_true(outcomes.length() == 3)
  assert_true(outcomes[0] is @mcp.Unavailable)
  assert_true(outcomes[1] is @mcp.Unavailable)
  assert_true(outcomes[2] is @mcp.Unavailable)
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
