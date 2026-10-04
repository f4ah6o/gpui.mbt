///|
/// Small reference fixture: every entry path invokes the same typed handler;
/// only MCP transport passes through the registry and protocol adapter.
priv struct Fixture {
  server : @mcp.ProtocolServer
  add : @capability.TypedCapability[Int, Int]
  read : @capability.TypedCapability[Unit, Int]
  gui_add : @capability.GuiBinding[Int, Int]
}

///|
let active_fixture : Ref[Fixture?] = Ref(None)

///|
let fixture_closed : Ref[Bool] = Ref(false)

///|
fn closed_fixture_error() -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.HostStopping,
    "mcp_stdio_fixture",
    subsystem="mcp-stdio-fixture",
    message="fixture is closed; call start to begin a new lifetime",
  )
}

///|
fn add_capability(
  counter : Ref[Int],
) -> Result[@capability.TypedCapability[Int, Int], @diagnostics.FrameworkError] {
  let descriptor = match
    @capability.Descriptor::new(
      "demo.counter.add",
      "Add to the demo counter",
      "Add a non-negative integer to the shared reference counter.",
      @capability.Command,
      @capability.Schema::int(),
      @capability.Schema::int(),
      @capability.StateChange,
      false,
      @capability.External,
      Some("counter_add"),
      1,
    ) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  let state = counter
  Ok(
    @capability.TypedCapability::new_with_validation(
      descriptor,
      value => value.as_int(),
      value => Ok(@capability.Value::int(value)),
      delta => {
        if delta < 0 || delta > 1_000_000 {
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "counter_add",
              subsystem="mcp-stdio-fixture",
              message="delta must be between 0 and 1000000",
            ),
          )
        } else {
          Ok(())
        }
      },
      value => {
        if value < 0 || value > 1_000_000 {
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "counter_add",
              subsystem="mcp-stdio-fixture",
              message="counter result is outside the fixture limit",
            ),
          )
        } else {
          Ok(())
        }
      },
      delta => {
        if state.val > 1_000_000 - delta {
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.ResourceExhausted,
              "counter_add",
              subsystem="mcp-stdio-fixture",
              message="counter reached the fixture limit",
            ),
          )
        } else {
          state.val += delta
          Ok(state.val)
        }
      },
      () => Ok(()),
      _origin => Ok(()),
    ),
  )
}

///|
fn read_capability(
  counter : Ref[Int],
) -> Result[@capability.TypedCapability[Unit, Int], @diagnostics.FrameworkError] {
  let descriptor = match
    @capability.Descriptor::new(
      "demo.counter.read",
      "Read the demo counter",
      "Read the counter value shared by GUI, direct, and MCP calls.",
      @capability.Query,
      @capability.Schema::unit(),
      @capability.Schema::int(),
      @capability.ReadOnly,
      true,
      @capability.External,
      Some("counter_read"),
      1,
    ) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  let state = counter
  Ok(
    @capability.TypedCapability::new(
      descriptor,
      _ => Ok(()),
      value => Ok(@capability.Value::int(value)),
      _ => Ok(state.val),
      () => Ok(()),
      _origin => Ok(()),
    ),
  )
}

///|
fn create_fixture() -> Result[Fixture, @diagnostics.FrameworkError] {
  let counter = Ref(0)
  let add = match add_capability(counter) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  let read = match read_capability(counter) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  let registry = @capability.Registry::new()
  match registry.register(add) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match registry.register(read) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  Ok({
    server: @mcp.ProtocolServer::new_with_identity(
      @mcp.Adapter::new(registry),
      "gpui-mbt-stdio-fixture",
      "0.1.0",
    ),
    add,
    read,
    gui_add: add.gui_binding(),
  })
}

///|
fn ensure_fixture() -> Result[Fixture, @diagnostics.FrameworkError] {
  match active_fixture.val {
    Some(fixture) if !fixture_closed.val => Ok(fixture)
    _ => Err(closed_fixture_error())
  }
}

///|
fn direct_result(result : Result[Int, @diagnostics.FrameworkError]) -> String {
  match result {
    Ok(value) => "{\"ok\":true,\"value\":\{value}}"
    Err(error) =>
      "{\"ok\":false,\"code\":\"\{error.code().label()}\",\"operation\":\"\{@capability.json_escape(error.operation())}\"}"
  }
}

///|
#export_name("gpui_mcp_stdio_start")
pub fn mcp_stdio_start() -> String {
  match active_fixture.val {
    Some(_) if !fixture_closed.val => "started"
    _ =>
      match create_fixture() {
        Err(_) => "start_failed"
        Ok(fixture) => {
          active_fixture.val = Some(fixture)
          fixture_closed.val = false
          "started"
        }
      }
  }
}

///|
#export_name("gpui_mcp_stdio_handle_line")
pub fn mcp_stdio_handle_line(line : String) -> String {
  match active_fixture.val {
    None => ""
    Some(fixture) =>
      match fixture.server.handle_line(line) {
        None => ""
        Some(response) => response
      }
  }
}

///|
#export_name("gpui_mcp_stdio_tools_inventory_json")
pub fn mcp_stdio_tools_inventory_json() -> String {
  match ensure_fixture() {
    Err(_) => "{}"
    Ok(fixture) =>
      match fixture.server.tools_list_result_json() {
        Err(_) => "{}"
        Ok(json) => json
      }
  }
}

///|
#export_name("gpui_mcp_stdio_direct_add")
pub fn mcp_stdio_direct_add(delta : Int) -> String {
  match ensure_fixture() {
    Err(error) => direct_result(Err(error))
    Ok(fixture) => direct_result(fixture.add.invoke(@capability.Direct, delta))
  }
}

///|
#export_name("gpui_mcp_stdio_gui_add")
pub fn mcp_stdio_gui_add(delta : Int) -> String {
  match ensure_fixture() {
    Err(error) => direct_result(Err(error))
    Ok(fixture) => direct_result(fixture.gui_add.trigger(delta))
  }
}

///|
#export_name("gpui_mcp_stdio_direct_read")
pub fn mcp_stdio_direct_read() -> String {
  match ensure_fixture() {
    Err(error) => direct_result(Err(error))
    Ok(fixture) => direct_result(fixture.read.invoke(@capability.Direct, ()))
  }
}

///|
#export_name("gpui_mcp_stdio_close")
pub fn mcp_stdio_close() -> Unit {
  match active_fixture.val {
    Some(_) if fixture_closed.val => ()
    Some(fixture) => {
      fixture.server.close()
      fixture_closed.val = true
    }
    None => ()
  }
}
