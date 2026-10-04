///|
/// Build a request with the required metadata for revision 2026-07-28.
fn protocol_spec_request(
  rpc_method : String,
  id : String,
  params : String,
) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\{id},\"method\":\"\{rpc_method}\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}\{if params.length() > 0 { "," } else { "" }}\{params}}}"
}

///|
fn protocol_spec_member(value : Json, key : String) -> Json raise {
  match value {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(found) => found
        None => fail("expected JSON object member")
      }
    _ => fail("expected JSON object")
  }
}

///|
fn protocol_spec_has_member(value : Json, key : String) -> Bool {
  match value {
    Json::Object(fields) => fields.get(key) is Some(_)
    _ => false
  }
}

///|
fn protocol_spec_reply(
  server : @mcp.ProtocolServer,
  request : String,
) -> Json raise {
  match server.handle_line(request) {
    Some(reply) =>
      @json.parse(reply) catch {
        _ => fail("protocol host should emit valid JSON")
      }
    None => fail("request should receive a response")
  }
}

///|
fn protocol_spec_register_int_to_string(
  registry : @capability.Registry,
  executions : Ref[Int],
) -> Unit raise {
  let descriptor = match
    @capability.Descriptor::new(
      "spec.value",
      "spec.value",
      "Conformance fixture",
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
    Err(_) => fail("valid fixture descriptor should be accepted")
  }
  let capability = @capability.TypedCapability::new(
    descriptor,
    value => value.as_int(),
    value => Ok(@capability.Value::string(value)),
    value => {
      executions.val += 1
      Ok("value-\{value}")
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  assert_true(registry.register(capability) is Ok(_))
}

///|
test "2026-07-28 responses follow the published result and schema envelope" {
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  protocol_spec_register_int_to_string(registry, executions)
  let server = @mcp.ProtocolServer::new_with_identity(
    @mcp.Adapter::new(registry),
    "spec-fixture",
    "2.1.0",
  )

  let discovery = protocol_spec_reply(
    server,
    protocol_spec_request("server/discover", "1", ""),
  )
  let discovery_result = protocol_spec_member(discovery, "result")
  assert_true(!protocol_spec_has_member(discovery, "_meta"))
  assert_true(
    protocol_spec_member(discovery_result, "resultType")
    is Json::String("complete"),
  )
  match protocol_spec_member(discovery_result, "supportedVersions") {
    Json::Array(versions) => {
      assert_true(versions.length() == 1)
      assert_true(versions[0] is Json::String("2026-07-28"))
    }
    _ => fail("discovery must return supportedVersions")
  }
  let discovery_info = protocol_spec_member(
    protocol_spec_member(discovery_result, "_meta"),
    "io.modelcontextprotocol/serverInfo",
  )
  assert_true(
    protocol_spec_member(discovery_info, "name") is Json::String("spec-fixture"),
  )
  assert_true(
    protocol_spec_member(discovery_info, "version") is Json::String("2.1.0"),
  )
  let capabilities = protocol_spec_member(discovery_result, "capabilities")
  assert_true(protocol_spec_member(capabilities, "tools") is Json::Object(_))
  assert_true(
    protocol_spec_member(capabilities, "resources") is Json::Object(_),
  )
  assert_true(!protocol_spec_has_member(capabilities, "prompts"))

  let listed = protocol_spec_reply(
    server,
    protocol_spec_request("tools/list", "2", ""),
  )
  let list_result = protocol_spec_member(listed, "result")
  assert_true(!protocol_spec_has_member(listed, "_meta"))
  assert_true(
    protocol_spec_member(list_result, "resultType") is Json::String("complete"),
  )
  assert_true(
    protocol_spec_member(list_result, "cacheScope") is Json::String("private"),
  )
  assert_true(
    protocol_spec_member(list_result, "ttlMs") is Json::Number(0.0, ..),
  )
  match protocol_spec_member(list_result, "tools") {
    Json::Array(tools) => {
      assert_true(tools.length() == 1)
      let tool = tools[0]
      assert_true(
        protocol_spec_member(tool, "name") is Json::String("spec_value"),
      )
      let input_schema = protocol_spec_member(tool, "inputSchema")
      assert_true(
        protocol_spec_member(input_schema, "type") is Json::String("object"),
      )
      let value_schema = protocol_spec_member(
        protocol_spec_member(input_schema, "properties"),
        "value",
      )
      assert_true(
        protocol_spec_member(value_schema, "type") is Json::String("integer"),
      )
      match protocol_spec_member(input_schema, "required") {
        Json::Array(required) => {
          assert_true(required.length() == 1)
          assert_true(required[0] is Json::String("value"))
        }
        _ => fail("scalar input schema must declare its required wrapper")
      }
      assert_true(
        protocol_spec_member(input_schema, "additionalProperties")
        is Json::False,
      )
      let output_schema = protocol_spec_member(tool, "outputSchema")
      assert_true(
        protocol_spec_member(output_schema, "type") is Json::String("string"),
      )
    }
    _ => fail("tools/list must return tool definitions")
  }
  let list_info = protocol_spec_member(
    protocol_spec_member(list_result, "_meta"),
    "io.modelcontextprotocol/serverInfo",
  )
  assert_true(
    protocol_spec_member(list_info, "name") is Json::String("spec-fixture"),
  )

  let called = protocol_spec_reply(
    server,
    protocol_spec_request(
      "tools/call", "3", "\"name\":\"spec_value\",\"arguments\":{\"value\":5}",
    ),
  )
  let call_result = protocol_spec_member(called, "result")
  assert_true(!protocol_spec_has_member(called, "_meta"))
  assert_true(
    protocol_spec_member(call_result, "resultType") is Json::String("complete"),
  )
  assert_true(protocol_spec_member(call_result, "isError") is Json::False)
  assert_true(
    protocol_spec_member(call_result, "structuredContent")
    is Json::String("value-5"),
  )
  match protocol_spec_member(call_result, "content") {
    Json::Array(blocks) => {
      assert_true(blocks.length() == 1)
      assert_true(
        protocol_spec_member(blocks[0], "type") is Json::String("text"),
      )
      assert_true(
        protocol_spec_member(blocks[0], "text") is Json::String("\"value-5\""),
      )
    }
    _ => fail("tool results must include unstructured content")
  }
  let call_info = protocol_spec_member(
    protocol_spec_member(call_result, "_meta"),
    "io.modelcontextprotocol/serverInfo",
  )
  assert_true(
    protocol_spec_member(call_info, "version") is Json::String("2.1.0"),
  )
  assert_true(executions.val == 1)
}

///|
test "tool execution errors stay distinct from JSON-RPC dispatch errors" {
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  protocol_spec_register_int_to_string(registry, executions)
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))

  let invalid_value = protocol_spec_reply(
    server,
    protocol_spec_request(
      "tools/call", "4", "\"name\":\"spec_value\",\"arguments\":{\"value\":\"five\"}",
    ),
  )
  assert_true(!protocol_spec_has_member(invalid_value, "error"))
  let tool_error = protocol_spec_member(invalid_value, "result")
  assert_true(
    protocol_spec_member(tool_error, "resultType") is Json::String("complete"),
  )
  assert_true(protocol_spec_member(tool_error, "isError") is Json::True)
  assert_true(protocol_spec_member(tool_error, "content") is Json::Array(_))

  let unknown_tool = protocol_spec_reply(
    server,
    protocol_spec_request(
      "tools/call", "5", "\"name\":\"missing_tool\",\"arguments\":{}",
    ),
  )
  assert_true(!protocol_spec_has_member(unknown_tool, "result"))
  let unknown_tool_error = protocol_spec_member(unknown_tool, "error")
  assert_true(
    protocol_spec_member(unknown_tool_error, "code")
    is Json::Number(-32602.0, ..),
  )

  let unknown_method = protocol_spec_reply(
    server,
    protocol_spec_request("prompts/list", "6", ""),
  )
  assert_true(!protocol_spec_has_member(unknown_method, "result"))
  assert_true(
    protocol_spec_member(protocol_spec_member(unknown_method, "error"), "code")
    is Json::Number(-32601.0, ..),
  )
  assert_true(executions.val == 0)
}
