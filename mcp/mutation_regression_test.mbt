///|
fn mutation_text(length : Int) -> String {
  let text = StringBuilder()
  for _ in 0..<length {
    text.write_char('x')
  }
  text.to_string()
}

///|
fn mutation_error(
  result : Result[@capability.Value, @mcp.AdapterError],
  expected : @mcp.ErrorCode,
) -> Unit raise {
  match result {
    Err(error) => assert_true(error.code() == expected)
    Ok(_) => fail("request unexpectedly succeeded")
  }
}

///|
fn mutation_register(
  registry : @capability.Registry,
  id : String,
  input : @capability.Schema,
  kind : @capability.OperationKind,
  exposure : @capability.Exposure,
  handler : (@capability.Value) -> Result[
    @capability.Value,
    @diagnostics.FrameworkError,
  ],
) -> Unit raise {
  let descriptor = match
    @capability.Descriptor::new(
      id,
      "A \"quoted\" title",
      "line one\nline two",
      kind,
      input,
      @capability.Schema::int(),
      if kind is @capability.Query {
        @capability.ReadOnly
      } else {
        @capability.StateChange
      },
      kind is @capability.Query,
      exposure,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("regression fixture descriptor rejected")
  }
  assert_true(
    registry.register(
      @capability.TypedCapability::new(
        descriptor,
        value => Ok(value),
        value => Ok(value),
        handler,
        () => Ok(()),
        _ => Ok(()),
      ),
    )
    is Ok(_),
  )
}

///|
fn mutation_counting_adapter(executions : Ref[Int]) -> @mcp.Adapter raise {
  let registry = @capability.Registry::new()
  mutation_register(
    registry,
    "regression.echo",
    @capability.Schema::int(),
    @capability.Command,
    @capability.External,
    value => {
      executions.val += 1
      Ok(value)
    },
  )
  @mcp.Adapter::new(registry)
}

///|
test "request IDs and fingerprints reject oversized input before execution" {
  let executions = Ref(0)
  let adapter = mutation_counting_adapter(executions)
  for id in ["", mutation_text(257)] {
    mutation_error(
      adapter.call_tool_with_request_id(
        id,
        "regression_echo",
        @capability.Value::int(4),
      ),
      @mcp.InvalidInput,
    )
  }
  assert_eq(executions.val, 0)
  assert_true(
    adapter.call_tool_with_request_id(
      mutation_text(256),
      "regression_echo",
      @capability.Value::int(4),
    )
    is Ok(@capability.IntValue(4)),
  )
  mutation_error(
    adapter.call_tool_with_request_id(
      "oversized-name",
      mutation_text(1_048_576),
      @capability.Value::unit(),
    ),
    @mcp.InvalidInput,
  )
  assert_eq(executions.val, 1)
}

///|
test "replay cache retains exactly the latest 128 terminal requests" {
  let executions = Ref(0)
  let adapter = mutation_counting_adapter(executions)
  for index in 0..<128 {
    assert_true(
      adapter.call_tool_with_request_id(
        "request-\{index}",
        "regression_echo",
        @capability.Value::int(index),
      )
      is Ok(@capability.IntValue(actual)) &&
      actual == index,
    )
  }
  for index in [0, 1, 127] {
    assert_true(
      adapter.call_tool_with_request_id(
        "request-\{index}",
        "regression_echo",
        @capability.Value::int(index),
      )
      is Ok(@capability.IntValue(actual)) &&
      actual == index,
    )
  }
  assert_eq(executions.val, 128)
  assert_true(
    adapter.call_tool_with_request_id(
      "request-128",
      "regression_echo",
      @capability.Value::int(128),
    )
    is Ok(@capability.IntValue(128)),
  )
  for index in [1, 127, 128] {
    assert_true(
      adapter.call_tool_with_request_id(
        "request-\{index}",
        "regression_echo",
        @capability.Value::int(index),
      )
      is Ok(@capability.IntValue(actual)) &&
      actual == index,
    )
  }
  assert_eq(executions.val, 129)
  // Reading a retained result does not refresh its terminal-completion order.
  assert_true(
    adapter.call_tool_with_request_id(
      "request-0",
      "regression_echo",
      @capability.Value::int(0),
    )
    is Ok(@capability.IntValue(0)),
  )
  assert_eq(executions.val, 130)
  assert_true(
    adapter.call_tool_with_request_id(
      "request-1",
      "regression_echo",
      @capability.Value::int(1),
    )
    is Ok(@capability.IntValue(1)),
  )
  assert_eq(executions.val, 131)
}

///|
test "nested requests preserve other in-flight entries and reject conflicting payloads" {
  let registry = @capability.Registry::new()
  let holder : Ref[@mcp.Adapter?] = Ref(None)
  let executions = Ref(0)
  let observed : Array[@mcp.ErrorCode] = []
  let policy_checks = Ref(0)
  let descriptor = mcp_command_descriptor(
    "regression.nested",
    @capability.External,
  )
  assert_true(
    registry.register(
      @capability.TypedCapability::new(
        descriptor,
        value => Ok(value),
        value => Ok(value),
        value => {
          executions.val += 1
          if value is @capability.IntValue(0) && executions.val < 5 {
            match holder.val {
              Some(adapter) => {
                // A different ID may run while the outer request is active.
                ignore(
                  adapter.call_tool_with_request_id(
                    "inner",
                    "regression_nested",
                    @capability.Value::int(1),
                  ),
                )
                for input in [0, 2] {
                  match
                    adapter.call_tool_with_request_id(
                      "outer",
                      "regression_nested",
                      @capability.Value::int(input),
                    ) {
                    Err(error) => observed.push(error.code())
                    Ok(_) => ()
                  }
                }
              }
              None => ()
            }
          }
          Ok(value)
        },
        () => Ok(()),
        _ => {
          policy_checks.val += 1
          Ok(())
        },
      ),
    )
    is Ok(_),
  )
  let adapter = @mcp.Adapter::new(registry)
  holder.val = Some(adapter)
  assert_true(
    adapter.call_tool_with_request_id(
      "outer",
      "regression_nested",
      @capability.Value::int(0),
    )
    is Ok(@capability.IntValue(0)),
  )
  assert_eq(executions.val, 2)
  assert_eq(observed.length(), 2)
  assert_true(observed[0] is @mcp.RequestInProgress)
  assert_true(observed[1] is @mcp.RequestConflict)
  assert_eq(policy_checks.val, 3)
}

///|
test "in-flight admission is bounded independently of completed retention" {
  let registry = @capability.Registry::new()
  let holder : Ref[@mcp.Adapter?] = Ref(None)
  let executions = Ref(0)
  let terminal : Ref[@mcp.ErrorCode?] = Ref(None)
  mutation_register(
    registry,
    "regression.depth",
    @capability.Schema::int(),
    @capability.Command,
    @capability.External,
    value => {
      executions.val += 1
      match (value, holder.val) {
        (@capability.IntValue(depth), Some(adapter)) if depth < 129 =>
          match
            adapter.call_tool_with_request_id(
              "depth-\{depth + 1}",
              "regression_depth",
              @capability.Value::int(depth + 1),
            ) {
            Err(error) => terminal.val = Some(error.code())
            Ok(_) => ()
          }
        _ => ()
      }
      Ok(value)
    },
  )
  let adapter = @mcp.Adapter::new(registry)
  holder.val = Some(adapter)
  assert_true(
    adapter.call_tool_with_request_id(
      "depth-0",
      "regression_depth",
      @capability.Value::int(0),
    )
    is Ok(@capability.IntValue(0)),
  )
  assert_eq(executions.val, 128)
  assert_true(terminal.val is Some(@mcp.Unavailable))
  // Unwinding clears all active slots and still retains the outer completion.
  assert_true(
    adapter.call_tool_with_request_id(
      "depth-0",
      "regression_depth",
      @capability.Value::int(0),
    )
    is Ok(@capability.IntValue(0)),
  )
  assert_eq(executions.val, 128)
  assert_true(
    adapter.call_tool_with_request_id(
      "later",
      "regression_depth",
      @capability.Value::int(129),
    )
    is Ok(@capability.IntValue(129)),
  )
  assert_eq(executions.val, 129)
}

///|
test "handler conversion errors remain domain failures rather than projection failures" {
  let registry = @capability.Registry::new()
  mutation_register(
    registry,
    "regression.failure",
    @capability.Schema::int(),
    @capability.Command,
    @capability.External,
    _ => {
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.ConversionFailed,
          "domain decoding",
          subsystem="domain",
          message="domain-specific conversion failed",
        ),
      )
    },
  )
  let adapter = @mcp.Adapter::new(registry)
  mutation_error(
    adapter.call_tool("regression_failure", @capability.Value::int(1)),
    @mcp.DomainFailure,
  )
}

///|
test "inventory JSON and resource routing preserve all exposed entries and annotations" {
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  for
    entry in [
      ("a.query", @capability.Query),
      ("b.command", @capability.Command),
    ] {
    let (id, kind) = entry
    mutation_register(
      registry,
      id,
      @capability.Schema::int(),
      kind,
      @capability.External,
      value => Ok(value),
    )
  }
  for entry in [("a.resource", 11), ("b.resource", 22)] {
    let (id, answer) = entry
    mutation_register(
      registry,
      id,
      @capability.Schema::unit(),
      @capability.Query,
      @capability.External,
      _ => {
        executions.val += 1
        Ok(@capability.Value::int(answer))
      },
    )
  }
  for
    entry in [
      ("hidden.internal", @capability.Internal),
      ("hidden.local", @capability.Local),
    ] {
    let (id, exposure) = entry
    mutation_register(
      registry,
      id,
      @capability.Schema::int(),
      @capability.Command,
      exposure,
      value => {
        executions.val += 1
        Ok(value)
      },
    )
  }
  let adapter = @mcp.Adapter::new(registry)
  let inventory = match adapter.inventory() {
    Ok(value) => value
    Err(_) => fail("inventory should be available")
  }
  let encoded = @json.parse(inventory.canonical_json())
  for key in ["tools", "resources"] {
    match protocol_member(encoded, key) {
      Json::Array(entries) => assert_eq(entries.length(), 2)
      _ => fail("inventory entries must be JSON arrays")
    }
  }
  let server = @mcp.ProtocolServer::new(adapter)
  let tools = protocol_member(
    protocol_member(
      protocol_reply(server, protocol_request("tools/list", "1", "")),
      "result",
    ),
    "tools",
  )
  match tools {
    Json::Array(entries) => {
      assert_eq(entries.length(), 2)
      for index, entry in entries {
        assert_true(
          protocol_member(entry, "title") is Json::String("A \"quoted\" title"),
        )
        assert_true(
          protocol_member(entry, "description")
          is Json::String("line one\nline two"),
        )
        let annotations = protocol_member(entry, "annotations")
        for key in ["readOnlyHint", "idempotentHint"] {
          if index == 0 {
            assert_true(protocol_member(annotations, key) is Json::True)
          } else {
            assert_true(protocol_member(annotations, key) is Json::False)
          }
        }
      }
    }
    _ => fail("tools must be a JSON array")
  }
  let resources = protocol_member(
    protocol_member(
      protocol_reply(server, protocol_request("resources/list", "2", "")),
      "result",
    ),
    "resources",
  )
  match resources {
    Json::Array(entries) => assert_eq(entries.length(), 2)
    _ => fail("resources must be a JSON array")
  }
  for entry in [("a_resource", "11"), ("b_resource", "22")] {
    let (name, expected) = entry
    let uri = "gpui://capability/\{name}"
    let reply = protocol_reply(
      server,
      protocol_request("resources/read", "3", "\"uri\":\"\{uri}\""),
    )
    match protocol_member(protocol_member(reply, "result"), "contents") {
      Json::Array(contents) => {
        assert_eq(contents.length(), 1)
        assert_true(
          protocol_member(contents[0], "uri") is Json::String(actual) &&
          actual == uri,
        )
        assert_true(
          protocol_member(contents[0], "text") is Json::String(actual) &&
          actual == expected,
        )
      }
      _ => fail("resource contents must be an array")
    }
  }
  mutation_error(
    adapter.read_resource("gpui://capability/missing"),
    @mcp.UnknownOperation,
  )
  for name in ["hidden_internal", "hidden_local"] {
    mutation_error(
      adapter.call_tool(name, @capability.Value::int(0)),
      @mcp.UnknownOperation,
    )
  }
  assert_eq(executions.val, 2)
}

///|
fn mutation_protocol_error(
  reply : Json,
  code : Double,
  message : String?,
) -> Unit raise {
  let error = protocol_member(reply, "error")
  protocol_number(protocol_member(error, "code"), code)
  match message {
    Some(expected) =>
      assert_true(
        protocol_member(error, "message") is Json::String(actual) &&
        actual == expected,
      )
    None => ()
  }
}

///|
test "protocol IDs enforce safe integers and bounded strings before dispatch" {
  let server = @mcp.ProtocolServer::new(
    @mcp.Adapter::new(@capability.Registry::new()),
  )
  for
    id in [
      "null",
      "true",
      "false",
      "[]",
      "{}",
      "1.5",
      "-9007199254740992",
      "9007199254740992",
      "\"\{mutation_text(257)}\"",
    ] {
    let reply = protocol_reply(
      server,
      protocol_request("server/discover", id, ""),
    )
    mutation_protocol_error(reply, -32600.0, Some("Invalid Request"))
    assert_true(protocol_member(reply, "id") is Json::Null)
  }
  for
    id in [
      "0",
      "-9007199254740991",
      "9007199254740991",
      "\"\"",
      "\"\{mutation_text(256)}\"",
    ] {
    let reply = protocol_reply(
      server,
      protocol_request("server/discover", id, ""),
    )
    assert_true(protocol_member(reply, "result") is Json::Object(_))
    assert_true(protocol_member(reply, "id") == @json.parse(id))
  }
  let wrong_version = protocol_request("server/discover", "123", "").replace(
    old="\"jsonrpc\":\"2.0\"",
    new="\"jsonrpc\":\"1.0\"",
  )
  let reply = protocol_reply(server, wrong_version)
  mutation_protocol_error(reply, -32600.0, Some("Invalid Request"))
  protocol_number(protocol_member(reply, "id"), 123.0)
  let oversized = protocol_request(
    "server/discover",
    "1",
    "\"padding\":\"\{mutation_text(1_048_576)}\"",
  )
  mutation_protocol_error(
    protocol_reply(server, oversized),
    -32700.0,
    Some("Request exceeds the size limit"),
  )
}

///|
fn mutation_tool_result(
  server : @mcp.ProtocolServer,
  name : String,
  arguments : String,
) -> Json raise {
  protocol_member(
    protocol_reply(
      server,
      protocol_request(
        "tools/call",
        "1",
        "\"name\":\"\{name}\",\"arguments\":\{arguments}",
      ),
    ),
    "result",
  )
}

///|
fn mutation_tool_error(result : Json, expected : String) -> Unit raise {
  assert_true(protocol_member(result, "isError") is Json::True)
  match protocol_member(result, "content") {
    Json::Array(contents) => {
      assert_eq(contents.length(), 1)
      assert_true(
        protocol_member(contents[0], "text") is Json::String(actual) &&
        actual == expected,
      )
    }
    _ => fail("tool errors must contain diagnostic text")
  }
}

///|
test "unit and scalar argument shapes reject extras without executing" {
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  for
    entry in [
      ("shape.unit", @capability.Schema::unit()),
      ("shape.integer", @capability.Schema::int()),
    ] {
    let (id, schema) = entry
    mutation_register(
      registry,
      id,
      schema,
      @capability.Command,
      @capability.External,
      _ => {
        executions.val += 1
        Ok(@capability.Value::int(1))
      },
    )
  }
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
  assert_true(
    protocol_member(mutation_tool_result(server, "shape_unit", "{}"), "isError")
    is Json::False,
  )
  mutation_tool_error(
    mutation_tool_result(server, "shape_unit", "{\"unused\":1}"),
    "This tool accepts no arguments",
  )
  mutation_tool_error(
    mutation_tool_result(server, "shape_integer", "{\"value\":1,\"extra\":2}"),
    "Scalar tool input must contain only arguments.value",
  )
  mutation_tool_error(
    mutation_tool_result(server, "shape_integer", "{}"),
    "Scalar tool input must contain only arguments.value",
  )
  mutation_tool_error(
    mutation_tool_result(server, "shape_integer", "{\"other\":1}"),
    "Scalar tool input must be provided as arguments.value",
  )
  assert_eq(executions.val, 1)
}

///|
test "schema mismatch diagnostics identify the rejected wire type before execution" {
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  protocol_test_register_echo(
    registry,
    "types.integer",
    @capability.Schema::int(),
    executions,
  )
  protocol_test_register_echo(
    registry,
    "types.boolean",
    @capability.Schema::bool(),
    executions,
  )
  protocol_test_register_echo(
    registry,
    "types.string",
    @capability.Schema::string(),
    executions,
  )
  let record = protocol_test_record([
    protocol_test_field("empty", @capability.Schema::unit(), true),
  ])
  protocol_test_register_echo(registry, "types.record", record, executions)
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
  for
    value in [
      "true", "false", "\"7\"", "[]", "{}", "0.5", "2147483648", "-2147483649",
    ] {
    mutation_tool_error(
      mutation_tool_result(server, "types_integer", "{\"value\":\{value}}"),
      "Expected a value matching the capability schema",
    )
  }
  mutation_tool_error(
    mutation_tool_result(server, "types_integer", "{\"value\":null}"),
    "Expected a non-null value",
  )
  assert_eq(executions.val, 0)
  for
    entry in [
      ("types_boolean", "true"),
      ("types_boolean", "false"),
      ("types_string", "\"seven\""),
    ] {
    let (name, value) = entry
    let result = mutation_tool_result(server, name, "{\"value\":\{value}}")
    assert_true(protocol_member(result, "isError") is Json::False)
    assert_true(
      protocol_member(result, "structuredContent") == @json.parse(value),
    )
  }
  let unit_record = mutation_tool_result(
    server, "types_record", "{\"empty\":null}",
  )
  assert_true(protocol_member(unit_record, "isError") is Json::False)
  assert_true(
    protocol_member(protocol_member(unit_record, "structuredContent"), "empty")
    is Json::Null,
  )
  assert_eq(executions.val, 4)
}

///|
fn mutation_nested_schema(
  shape : Int,
  wrappers : Int,
  optional_depth : Int,
) -> (@capability.Schema, String) raise {
  let mut schema = @capability.Schema::int()
  let mut value = "1"
  for _ in 0..<optional_depth {
    schema = @capability.Schema::optional(schema)
  }
  for _ in 0..<wrappers {
    if shape == 0 {
      schema = @capability.Schema::array(schema)
      value = "[\{value}]"
    } else if shape == 1 {
      schema = protocol_test_record([protocol_test_field("child", schema, true)])
      value = "{\"child\":\{value}}"
    } else {
      let variant = match @capability.SchemaVariant::new("node", schema) {
        Ok(value) => value
        Err(_) => fail("nested variant should be valid")
      }
      schema = match @capability.Schema::tagged("kind", [variant]) {
        Ok(value) => value
        Err(_) => fail("nested tagged schema should be valid")
      }
      value = "{\"kind\":\"node\",\"value\":\{value}}"
    }
  }
  (schema, value)
}

///|
test "schema traversal depth counts optional array record and tagged branches" {
  // Schema traversal can be deeper than wire JSON because optional and tagged
  // branches each add a decoding step. This exercises the decoder budget even
  // though the request remains inside the lexical transport guard.
  for shape in 0..<3 {
    for exceeds in [false, true] {
      let wrappers = if shape == 2 {
        if exceeds {
          9
        } else {
          8
        }
      } else if exceeds {
        17
      } else {
        16
      }
      let (schema, value) = mutation_nested_schema(shape, wrappers, 16)
      let arguments = if schema.is_object() {
        value
      } else {
        "{\"value\":\{value}}"
      }
      let registry = @capability.Registry::new()
      let executions = Ref(0)
      mutation_register(
        registry,
        "limits.deep",
        schema,
        @capability.Command,
        @capability.External,
        _ => {
          executions.val += 1
          Ok(@capability.Value::int(1))
        },
      )
      let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
      let result = mutation_tool_result(server, "limits_deep", arguments)
      if exceeds {
        mutation_tool_error(result, "Tool arguments exceed transport limits")
        assert_eq(executions.val, 0)
      } else {
        assert_true(protocol_member(result, "isError") is Json::False)
        assert_eq(executions.val, 1)
      }
    }
  }
}

///|
test "schema traversal node budget counts optional decoding steps" {
  for size in [4999, 5000] {
    let registry = @capability.Registry::new()
    let executions = Ref(0)
    mutation_register(
      registry,
      "limits.nodes",
      @capability.Schema::array(
        @capability.Schema::optional(@capability.Schema::int()),
      ),
      @capability.Command,
      @capability.External,
      _ => {
        executions.val += 1
        Ok(@capability.Value::int(1))
      },
    )
    let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
    let array = StringBuilder()
    array.write_char('[')
    for index in 0..<size {
      if index > 0 {
        array.write_char(',')
      }
      array.write_char('1')
    }
    array.write_char(']')
    let result = mutation_tool_result(
      server,
      "limits_nodes",
      "{\"value\":\{array.to_string()}}",
    )
    if size == 5000 {
      mutation_tool_error(result, "Tool arguments exceed transport limits")
      assert_eq(executions.val, 0)
    } else {
      assert_true(protocol_member(result, "isError") is Json::False)
      assert_eq(executions.val, 1)
    }
  }
}

///|
test "unique-key scanning bounds nested objects and rejects truncated lexical input" {
  for count in [32, 33] {
    let mut input = "0"
    for _ in 0..<count {
      input = "{\"child\":\{input}}"
    }
    assert_eq(@mcp.validate_unique_json_keys(input), count == 32)
  }
  for
    input in [
      "{\"", "{\"a\":1,\"a\"", "[\"unterminated", "{\"a\",1}", "", " ", "{", "{\"key\"",
      "{\"key\":1", "{\"key\":1,", "[", "[1", "[1,", "\"truncated", "\"raw\nnewline\"",
      "{\"a\" 0}", "\"raw\n",
    ] {
    assert_false(@mcp.validate_unique_json_keys(input))
  }
  assert_true(
    @mcp.validate_unique_json_keys(" \t\r\n { \"a\" : [ 1 , 2 ] } \n"),
  )
  // At the node limit, a missing final array value must not be interpreted as
  // a successful scan that leaves its closing delimiter for the parent.
  let exhausted = StringBuilder()
  exhausted.write_char('[')
  for _ in 0..<9999 {
    exhausted.write_string("0,")
  }
  exhausted.write_char(']')
  assert_false(@mcp.validate_unique_json_keys(exhausted.to_string()))
}

///|
test "single-resource servers return the matching URI and valid JSON" {
  let registry = @capability.Registry::new()
  mutation_register(
    registry,
    "only.resource",
    @capability.Schema::unit(),
    @capability.Query,
    @capability.External,
    _ => Ok(@capability.Value::int(8)),
  )
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
  let reply = protocol_reply(
    server,
    protocol_request(
      "resources/read", "1", "\"uri\":\"gpui://capability/only_resource\"",
    ),
  )
  match protocol_member(protocol_member(reply, "result"), "contents") {
    Json::Array(contents) => {
      assert_eq(contents.length(), 1)
      assert_true(protocol_member(contents[0], "text") is Json::String("8"))
    }
    _ => fail("a matching resource must return its contents")
  }
}

///|
test "optional unit and nested tagged inputs retain their specific decoder errors" {
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  mutation_register(
    registry,
    "shape.nullable-unit",
    @capability.Schema::optional(@capability.Schema::unit()),
    @capability.Command,
    @capability.External,
    _ => {
      executions.val += 1
      Ok(@capability.Value::int(1))
    },
  )
  let variant = match
    @capability.SchemaVariant::new("count", @capability.Schema::int()) {
    Ok(value) => value
    Err(_) => fail("tagged fixture should be valid")
  }
  let tagged = match @capability.Schema::tagged("kind", [variant]) {
    Ok(value) => value
    Err(_) => fail("tagged fixture should be valid")
  }
  mutation_register(
    registry,
    "shape.tagged-array",
    @capability.Schema::array(tagged),
    @capability.Command,
    @capability.External,
    _ => {
      executions.val += 1
      Ok(@capability.Value::int(1))
    },
  )
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
  assert_true(
    protocol_member(
      mutation_tool_result(server, "shape_nullable_unit", "{\"value\":null}"),
      "isError",
    )
    is Json::False,
  )
  mutation_tool_error(
    mutation_tool_result(server, "shape_nullable_unit", "{\"value\":1}"),
    "Optional input schema has no value branch",
  )
  mutation_tool_error(
    mutation_tool_result(server, "shape_tagged_array", "{\"value\":[7]}"),
    "Input does not match a tagged variant",
  )
  assert_eq(executions.val, 1)
}
