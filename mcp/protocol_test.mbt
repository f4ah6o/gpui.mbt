///|
fn protocol_test_record(
  fields : Array[@capability.SchemaField],
) -> @capability.Schema raise {
  match @capability.Schema::record(fields) {
    Ok(value) => value
    Err(_) => fail("protocol test record schema should be valid")
  }
}

///|
fn protocol_test_field(
  name : String,
  schema : @capability.Schema,
  required : Bool,
) -> @capability.SchemaField raise {
  match @capability.SchemaField::new(name, schema, required) {
    Ok(value) => value
    Err(_) => fail("protocol test field should be valid")
  }
}

///|
fn protocol_test_register_echo(
  registry : @capability.Registry,
  id : String,
  schema : @capability.Schema,
  executions : Ref[Int],
) -> Unit raise {
  let descriptor = match
    @capability.Descriptor::new(
      id,
      id,
      "protocol decoder test",
      @capability.Query,
      schema,
      schema,
      @capability.ReadOnly,
      true,
      @capability.External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("protocol test descriptor should be valid")
  }
  let capability = @capability.TypedCapability::new(
    descriptor,
    value => Ok(value),
    value => Ok(value),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  assert_true(registry.register(capability) is Ok(_))
}

///|
fn protocol_request(
  rpc_method : String,
  id_json : String,
  extra_json : String,
) -> String {
  let extra = if extra_json.length() == 0 { "" } else { ",\{extra_json}" }
  "{\"jsonrpc\":\"2.0\",\"id\":\{id_json},\"method\":\"\{rpc_method}\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"\{@mcp.MCP_PROTOCOL_VERSION}\",\"io.modelcontextprotocol/clientCapabilities\":{}}\{extra}}}"
}

///|
fn protocol_reply(server : @mcp.ProtocolServer, request : String) -> Json raise {
  match server.handle_line(request) {
    Some(reply) =>
      @json.parse(reply) catch {
        _ => fail("protocol response should be valid JSON")
      }
    None => fail("request should produce a protocol response")
  }
}

///|
fn protocol_member(value : Json, key : String) -> Json raise {
  match value {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(found) => found
        None => fail("protocol response is missing a member")
      }
    _ => fail("protocol response member parent should be an object")
  }
}

///|
fn protocol_number(value : Json, expected : Double) -> Unit raise {
  match value {
    Json::Number(actual, ..) => assert_true(actual == expected)
    _ => fail("protocol structured content should contain a number")
  }
}

///|
test "stateless protocol discovery metadata and generated tool schemas are JSON" {
  let number = @capability.Schema::number()
  let optional_number = @capability.Schema::optional(number)
  let record = protocol_test_record([
    protocol_test_field("amount", number, true),
    protocol_test_field("samples", @capability.Schema::array(number), true),
    protocol_test_field("note", optional_number, false),
  ])
  let variant = match @capability.SchemaVariant::new("payment", record) {
    Ok(value) => value
    Err(_) => fail("protocol test variant should be valid")
  }
  let tagged = match @capability.Schema::tagged("kind", [variant]) {
    Ok(value) => value
    Err(_) => fail("protocol test tagged schema should be valid")
  }
  let executions = Ref(0)
  let registry = @capability.Registry::new()
  protocol_test_register_echo(registry, "number.echo", number, executions)
  protocol_test_register_echo(registry, "record.echo", record, executions)
  protocol_test_register_echo(registry, "tagged.echo", tagged, executions)
  let server = @mcp.ProtocolServer::new_with_identity(
    @mcp.Adapter::new(registry),
    "fixture-service",
    "3.4.5",
  )

  let discovery = protocol_reply(
    server,
    protocol_request("server/discover", "1", ""),
  )
  let discovery_result = protocol_member(discovery, "result")
  assert_true(
    protocol_member(discovery_result, "supportedVersions") is Json::Array(_),
  )
  let info = protocol_member(
    protocol_member(discovery_result, "_meta"),
    "io.modelcontextprotocol/serverInfo",
  )
  assert_true(protocol_member(info, "name") is Json::String("fixture-service"))
  assert_true(protocol_member(info, "version") is Json::String("3.4.5"))

  let list = protocol_reply(server, protocol_request("tools/list", "2", ""))
  let listed_tools = protocol_member(protocol_member(list, "result"), "tools")
  assert_true(listed_tools is Json::Array(_))
  match listed_tools {
    Json::Array(tools) => {
      assert_true(tools.length() == 3)
      for tool in tools {
        assert_true(protocol_member(tool, "inputSchema") is Json::Object(_))
        assert_true(protocol_member(tool, "outputSchema") is Json::Object(_))
      }
    }
    _ => fail("tools/list should contain an array")
  }
}

///|
test "schema-directed wire decoding preserves integer-looking numbers in scalar and nested inputs" {
  let number = @capability.Schema::number()
  let optional_number = @capability.Schema::optional(number)
  let record = protocol_test_record([
    protocol_test_field("amount", number, true),
    protocol_test_field("samples", @capability.Schema::array(number), true),
    protocol_test_field("note", optional_number, false),
  ])
  let variant = match @capability.SchemaVariant::new("payment", record) {
    Ok(value) => value
    Err(_) => fail("protocol test variant should be valid")
  }
  let tagged = match @capability.Schema::tagged("kind", [variant]) {
    Ok(value) => value
    Err(_) => fail("protocol test tagged schema should be valid")
  }
  let executions = Ref(0)
  let registry = @capability.Registry::new()
  protocol_test_register_echo(registry, "number.echo", number, executions)
  protocol_test_register_echo(registry, "record.echo", record, executions)
  protocol_test_register_echo(registry, "tagged.echo", tagged, executions)
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))

  let scalar = protocol_reply(
    server,
    protocol_request(
      "tools/call", "3", "\"name\":\"number_echo\",\"arguments\":{\"value\":1}",
    ),
  )
  protocol_number(
    protocol_member(protocol_member(scalar, "result"), "structuredContent"),
    1.0,
  )
  let scalar_result = protocol_member(scalar, "result")
  let scalar_info = protocol_member(
    protocol_member(scalar_result, "_meta"),
    "io.modelcontextprotocol/serverInfo",
  )
  assert_true(
    protocol_member(scalar_info, "name") is Json::String("gpui-mcp-adapter"),
  )

  let scalar_decimal = protocol_reply(
    server,
    protocol_request(
      "tools/call", "4", "\"name\":\"number_echo\",\"arguments\":{\"value\":1.0}",
    ),
  )
  protocol_number(
    protocol_member(
      protocol_member(scalar_decimal, "result"),
      "structuredContent",
    ),
    1.0,
  )

  let record_reply = protocol_reply(
    server,
    protocol_request(
      "tools/call", "5", "\"name\":\"record_echo\",\"arguments\":{\"amount\":1,\"samples\":[2,3.5],\"note\":null}",
    ),
  )
  let record_result = protocol_member(
    protocol_member(record_reply, "result"),
    "structuredContent",
  )
  protocol_number(protocol_member(record_result, "amount"), 1.0)
  match protocol_member(record_result, "samples") {
    Json::Array(samples) => {
      assert_true(samples.length() == 2)
      protocol_number(samples[0], 2.0)
      protocol_number(samples[1], 3.5)
    }
    _ => fail("record samples should be an array")
  }
  assert_true(protocol_member(record_result, "note") is Json::Null)

  let tagged_reply = protocol_reply(
    server,
    protocol_request(
      "tools/call", "6", "\"name\":\"tagged_echo\",\"arguments\":{\"kind\":\"payment\",\"value\":{\"amount\":7,\"samples\":[8],\"note\":null}}",
    ),
  )
  let tagged_result = protocol_member(
    protocol_member(tagged_reply, "result"),
    "structuredContent",
  )
  assert_true(protocol_member(tagged_result, "kind") is Json::String("payment"))
  let tagged_value = protocol_member(tagged_result, "value")
  protocol_number(protocol_member(tagged_value, "amount"), 7.0)
  assert_true(executions.val == 4)
}

///|
test "protocol rejects unsupported metadata and ambiguous keys before handlers run" {
  let executions = Ref(0)
  let registry = @capability.Registry::new()
  protocol_test_register_echo(
    registry,
    "number.echo",
    @capability.Schema::number(),
    executions,
  )
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))

  let unsupported = protocol_request("server/discover", "7", "").replace(
    old="2026-07-28",
    new="2025-03-26",
  )
  let unsupported_reply = protocol_reply(server, unsupported)
  assert_true(protocol_member(unsupported_reply, "error") is Json::Object(_))

  let duplicate = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"method\":\"tools/call\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}},\"name\":\"number_echo\",\"arguments\":{\"value\":8}}}"
  let duplicate_reply = protocol_reply(server, duplicate)
  assert_true(protocol_member(duplicate_reply, "error") is Json::Object(_))
  assert_true(executions.val == 0)

  assert_true(
    server.handle_line(
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}",
    )
    is None,
  )
  server.close()
  let closed = protocol_reply(
    server,
    protocol_request("server/discover", "9", ""),
  )
  assert_true(protocol_member(closed, "error") is Json::Object(_))
  assert_true(executions.val == 0)
}
