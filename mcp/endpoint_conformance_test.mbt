///|
/// Independent schema-round-trip and three-lane parity fixture for packet 0014.
struct EndpointSchemaCase {
  id : String
  schema : @capability.Schema
  value : @capability.Value
  wire_json : String
}

///|
struct EndpointSchemaRegistration {
  case : EndpointSchemaCase
  capability : @capability.TypedCapability[@capability.Value, @capability.Value]
}

///|
fn endpoint_schema_field(
  name : String,
  schema : @capability.Schema,
  required : Bool,
) -> @capability.SchemaField raise {
  match @capability.SchemaField::new(name, schema, required) {
    Ok(value) => value
    Err(_) => fail("conformance schema field should be valid")
  }
}

///|
fn endpoint_schema_record(
  fields : Array[@capability.SchemaField],
) -> @capability.Schema raise {
  match @capability.Schema::record(fields) {
    Ok(value) => value
    Err(_) => fail("conformance record schema should be valid")
  }
}

///|
fn endpoint_register_echo(
  registry : @capability.Registry,
  case : EndpointSchemaCase,
  executions : Ref[Int],
) -> EndpointSchemaRegistration raise {
  let descriptor = match
    @capability.Descriptor::new(
      case.id,
      case.id,
      "Generated schema round-trip fixture",
      @capability.Command,
      case.schema,
      case.schema,
      @capability.StateChange,
      false,
      @capability.External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("conformance descriptor should be valid")
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
  { case, capability, }
}

///|
fn endpoint_json_equal(left : Json, right : Json) -> Bool {
  match (left, right) {
    (Json::Null, Json::Null)
    | (Json::True, Json::True)
    | (Json::False, Json::False) => true
    (Json::String(a), Json::String(b)) => a == b
    (Json::Number(a, ..), Json::Number(b, ..)) => a == b
    (Json::Array(a), Json::Array(b)) => {
      if a.length() != b.length() {
        return false
      }
      for index in 0..<a.length() {
        if !endpoint_json_equal(a[index], b[index]) {
          return false
        }
      }
      true
    }
    (Json::Object(a), Json::Object(b)) => {
      if a.length() != b.length() {
        return false
      }
      for (key, value) in a.to_array() {
        match b.get(key) {
          Some(other) if endpoint_json_equal(value, other) => ()
          _ => return false
        }
      }
      true
    }
    _ => false
  }
}

///|
fn endpoint_json_member(value : Json, key : String) -> Json raise {
  match value {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(found) => found
        None => fail("conformance response is missing a JSON member")
      }
    _ => fail("conformance response member parent should be an object")
  }
}

///|
fn endpoint_has_json_member(value : Json, key : String) -> Bool {
  match value {
    Json::Object(fields) => fields.get(key) is Some(_)
    _ => false
  }
}

///|
fn endpoint_assert_invalid_params(value : Json) -> Unit raise {
  assert_true(!endpoint_has_json_member(value, "result"))
  let error = endpoint_json_member(value, "error")
  assert_true(endpoint_json_member(error, "code") is Json::Number(-32602.0, ..))
}

///|
fn endpoint_wire_request(
  rpc_method : String,
  request_id : String,
  params_json : String,
) -> String {
  let extra = if params_json.length() > 0 { "," } else { "" }
  "{\"jsonrpc\":\"2.0\",\"id\":\"\{request_id}\",\"method\":\"\{rpc_method}\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}\{extra}\{params_json}}}"
}

///|
fn endpoint_parse_wire_reply(
  server : @mcp.ProtocolServer,
  request : String,
) -> Json raise {
  match server.handle_line(request) {
    Some(reply) =>
      @json.parse(reply) catch {
        _ => fail("MCP wire path must return valid JSON")
      }
    None => fail("MCP request should return a response")
  }
}

///|
fn endpoint_schema_arguments(
  schema : @capability.Schema,
  input_json : String,
) -> String {
  if schema.is_unit() {
    "{}"
  } else if schema.is_object() {
    input_json
  } else {
    "{\"value\":\{input_json}}"
  }
}

///|
fn endpoint_assert_case_parity(
  server : @mcp.ProtocolServer,
  registered : EndpointSchemaRegistration,
  index : Int,
  executions : Ref[Int],
) -> Unit raise {
  let case = registered.case
  let expected = @json.parse(case.wire_json) catch {
    _ => fail("fixture wire value should be valid JSON")
  }
  let gui = match
    registered.capability.gui_binding().trigger(case.value.clone()) {
    Ok(value) => value
    Err(_) => fail("valid schema case should pass through the GUI lane")
  }
  let direct = match
    registered.capability.invoke(@capability.Direct, case.value.clone()) {
    Ok(value) => value
    Err(_) => fail("valid schema case should pass through the direct lane")
  }
  let expected_canonical = case.value.canonical_json()
  assert_eq(gui.canonical_json(), expected_canonical)
  assert_eq(direct.canonical_json(), expected_canonical)

  let arguments = endpoint_schema_arguments(case.schema, case.wire_json)
  let params = "\"name\":\"\{@capability.json_escape(registered.capability.descriptor().external_name())}\",\"arguments\":\{arguments}"
  let response = endpoint_parse_wire_reply(
    server,
    endpoint_wire_request("tools/call", "schema-\{index}", params),
  )
  assert_true(!endpoint_has_json_member(response, "error"))
  let result = endpoint_json_member(response, "result")
  assert_true(
    endpoint_json_member(result, "resultType") is Json::String("complete"),
  )
  assert_true(endpoint_json_member(result, "isError") is Json::False)
  let structured = endpoint_json_member(result, "structuredContent")
  assert_true(endpoint_json_equal(structured, expected))
  match endpoint_json_member(result, "content") {
    Json::Array(blocks) => {
      assert_true(blocks.length() == 1)
      assert_true(
        endpoint_json_member(blocks[0], "type") is Json::String("text"),
      )
      match endpoint_json_member(blocks[0], "text") {
        Json::String(text) => assert_eq(text, expected_canonical)
        _ => fail("tool content should serialize the structured value")
      }
    }
    _ => fail("tool result should include a text content block")
  }
  assert_true(executions.val == (index + 1) * 3)
}

///|
fn endpoint_generated_array_parity(values : Array[Int]) -> Bool {
  let item_values : Array[@capability.Value] = []
  let item_json = StringBuilder()
  item_json.write_char('[')
  for index, value in values {
    if index > 0 {
      item_json.write_char(',')
    }
    item_json.write_string("\{value}")
    item_values.push(@capability.Value::int(value))
  }
  item_json.write_char(']')
  let input_json = item_json.to_string()
  let input = @capability.Value::array(item_values)
  let schema = @capability.Schema::array(@capability.Schema::int())
  let registry = @capability.Registry::new()
  let executions = Ref(0)
  let registered = endpoint_register_echo(
    registry,
    { id: "property.int_array", schema, value: input, wire_json: input_json, },
    executions,
  ) catch {
    _ => return false
  }
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
  let gui = match registered.capability.gui_binding().trigger(input.clone()) {
    Ok(value) => value.canonical_json()
    Err(_) => return false
  }
  let direct = match
    registered.capability.invoke(@capability.Direct, input.clone()) {
    Ok(value) => value.canonical_json()
    Err(_) => return false
  }
  let request = endpoint_wire_request(
    "tools/call",
    "generated-array",
    "\"name\":\"property_int_array\",\"arguments\":{\"value\":\{input_json}}",
  )
  let response = match server.handle_line(request) {
    Some(reply) => @json.parse(reply) catch { _ => return false }
    None => return false
  }
  if endpoint_has_json_member(response, "error") {
    return false
  }
  let result = endpoint_json_member(response, "result") catch {
    _ => return false
  }
  let structured = endpoint_json_member(result, "structuredContent") catch {
    _ => return false
  }
  let expected = @json.parse(input_json) catch { _ => return false }
  executions.val == 3 &&
  gui == input_json &&
  direct == input_json &&
  endpoint_json_equal(structured, expected)
}

///|
test "generated schemas round-trip across GUI direct and MCP wire lanes" {
  let unit = @capability.Schema::unit()
  let boolean = @capability.Schema::bool()
  let integer = @capability.Schema::int()
  let number = @capability.Schema::number()
  let string = @capability.Schema::string()
  let number_or_null = @capability.Schema::optional(number)
  let integer_array = @capability.Schema::array(integer)

  let detail = endpoint_schema_record([
    endpoint_schema_field("amount", number, true),
    endpoint_schema_field(
      "comment",
      @capability.Schema::optional(string),
      false,
    ),
  ])
  let nested = endpoint_schema_record([
    endpoint_schema_field("active", boolean, true),
    endpoint_schema_field("details", @capability.Schema::array(detail), true),
    endpoint_schema_field(
      "optionalDetails",
      @capability.Schema::optional(detail),
      true,
    ),
  ])
  let optional_record = @capability.Schema::optional(detail)
  let payment_fields = endpoint_schema_record([
    endpoint_schema_field("amount", number, true),
    endpoint_schema_field("approved", boolean, true),
  ])
  let payment = match
    @capability.SchemaVariant::new("payment", payment_fields) {
    Ok(value) => value
    Err(_) => fail("payment variant should be valid")
  }
  let notice = match @capability.SchemaVariant::new("notice", string) {
    Ok(value) => value
    Err(_) => fail("notice variant should be valid")
  }
  let tagged = match @capability.Schema::tagged("kind", [payment, notice]) {
    Ok(value) => value
    Err(_) => fail("tagged union should be valid")
  }

  let cases : Array[EndpointSchemaCase] = []
  cases.push({
    id: "schema.unit",
    schema: unit,
    value: @capability.Value::unit(),
    wire_json: "null",
  })
  cases.push({
    id: "schema.boolean",
    schema: boolean,
    value: @capability.Value::bool(true),
    wire_json: "true",
  })
  cases.push({
    id: "schema.int_min",
    schema: integer,
    value: @capability.Value::int(-2147483648),
    wire_json: "-2147483648",
  })
  cases.push({
    id: "schema.int_max",
    schema: integer,
    value: @capability.Value::int(2147483647),
    wire_json: "2147483647",
  })
  cases.push({
    id: "schema.number_integer",
    schema: number,
    value: @capability.Value::number(1.0),
    wire_json: "1",
  })
  cases.push({
    id: "schema.number_fraction",
    schema: number,
    value: @capability.Value::number(-3.25),
    wire_json: "-3.25",
  })
  cases.push({
    id: "schema.string",
    schema: string,
    value: @capability.Value::string("line\nquote\" fox 🦊"),
    wire_json: "\"line\\nquote\\\" fox 🦊\"",
  })
  cases.push({
    id: "schema.optional_number",
    schema: number_or_null,
    value: @capability.Value::unit(),
    wire_json: "null",
  })
  cases.push({
    id: "schema.int_array",
    schema: integer_array,
    value: @capability.Value::array([
      @capability.Value::int(-2147483648),
      @capability.Value::int(0),
      @capability.Value::int(2147483647),
    ]),
    wire_json: "[-2147483648,0,2147483647]",
  })
  cases.push({
    id: "schema.nested_record",
    schema: nested,
    value: @capability.Value::object([
      ("active", @capability.Value::bool(true)),
      (
        "details",
        @capability.Value::array([
          @capability.Value::object([
            ("amount", @capability.Value::number(1.0)),
            ("comment", @capability.Value::string("whole")),
          ]),
          @capability.Value::object([("amount", @capability.Value::number(2.5))]),
        ]),
      ),
      (
        "optionalDetails",
        @capability.Value::object([
          ("amount", @capability.Value::number(0.125)),
          ("comment", @capability.Value::unit()),
        ]),
      ),
    ]),
    wire_json: "{\"active\":true,\"details\":[{\"amount\":1,\"comment\":\"whole\"},{\"amount\":2.5}],\"optionalDetails\":{\"amount\":0.125,\"comment\":null}}",
  })
  cases.push({
    id: "schema.optional_record",
    schema: optional_record,
    value: @capability.Value::object([
      ("amount", @capability.Value::number(4.75)),
    ]),
    wire_json: "{\"amount\":4.75}",
  })
  cases.push({
    id: "schema.optional_record_none",
    schema: optional_record,
    value: @capability.Value::unit(),
    wire_json: "null",
  })
  cases.push({
    id: "schema.tagged_payment",
    schema: tagged,
    value: @capability.Value::object([
      ("kind", @capability.Value::string("payment")),
      (
        "value",
        @capability.Value::object([
          ("amount", @capability.Value::number(8.5)),
          ("approved", @capability.Value::bool(true)),
        ]),
      ),
    ]),
    wire_json: "{\"kind\":\"payment\",\"value\":{\"amount\":8.5,\"approved\":true}}",
  })
  cases.push({
    id: "schema.tagged_notice",
    schema: tagged,
    value: @capability.Value::object([
      ("kind", @capability.Value::string("notice")),
      ("value", @capability.Value::string("ready")),
    ]),
    wire_json: "{\"kind\":\"notice\",\"value\":\"ready\"}",
  })

  let registry = @capability.Registry::new()
  let executions = Ref(0)
  let registrations : Array[EndpointSchemaRegistration] = []
  for case in cases {
    registrations.push(endpoint_register_echo(registry, case, executions))
  }
  let server = @mcp.ProtocolServer::new(@mcp.Adapter::new(registry))
  for index, registered in registrations {
    if !registered.case.schema.accepts(registered.case.value) {
      fail("conformance fixture value rejected for \{registered.case.id}")
    }
    endpoint_assert_case_parity(server, registered, index, executions)
  }

  let listed = endpoint_parse_wire_reply(
    server,
    endpoint_wire_request("tools/list", "schema-list", ""),
  )
  let list_result = endpoint_json_member(listed, "result")
  match endpoint_json_member(list_result, "tools") {
    Json::Array(tools) => {
      assert_true(tools.length() == cases.length())
      for registered in registrations {
        let external_name = registered.capability.descriptor().external_name()
        let mut found = false
        for tool in tools {
          let listed_name = endpoint_json_member(tool, "name")
          if listed_name is Json::String(name) && name == external_name {
            found = true
            let input_schema = endpoint_json_member(tool, "inputSchema")
            assert_true(
              endpoint_json_member(input_schema, "type")
              is Json::String("object"),
            )
            let expected_output = @json.parse(
              registered.case.schema.canonical_json(),
            ) catch {
              _ => fail("descriptor output schema should be valid JSON")
            }
            assert_true(
              endpoint_json_equal(
                endpoint_json_member(tool, "outputSchema"),
                expected_output,
              ),
            )
            if registered.case.schema.is_unit() {
              match endpoint_json_member(input_schema, "properties") {
                Json::Object(properties) =>
                  assert_true(properties.length() == 0)
                _ => fail("unit input schema should have no properties")
              }
              assert_true(
                endpoint_json_member(input_schema, "additionalProperties")
                is Json::False,
              )
            } else if registered.case.schema.is_object() {
              let schema_has_object_type = match expected_output {
                Json::Object(fields) =>
                  fields.get("type") is Some(Json::String("object"))
                _ => false
              }
              if schema_has_object_type {
                assert_true(endpoint_json_equal(input_schema, expected_output))
              } else {
                match endpoint_json_member(input_schema, "allOf") {
                  Json::Array(all_of) => {
                    assert_true(all_of.length() == 1)
                    assert_true(endpoint_json_equal(all_of[0], expected_output))
                  }
                  _ =>
                    fail("tagged object input must use an object allOf wrapper")
                }
              }
            } else {
              let wrapped_schema = endpoint_json_member(
                endpoint_json_member(input_schema, "properties"),
                "value",
              )
              assert_true(endpoint_json_equal(wrapped_schema, expected_output))
              match endpoint_json_member(input_schema, "required") {
                Json::Array(required) => {
                  assert_true(required.length() == 1)
                  assert_true(required[0] is Json::String("value"))
                }
                _ => fail("wrapped input schema should require its value")
              }
              assert_true(
                endpoint_json_member(input_schema, "additionalProperties")
                is Json::False,
              )
            }
          }
        }
        assert_true(found)
      }
    }
    _ => fail("tools/list must advertise the generated schemas")
  }
  assert_true(executions.val == cases.length() * 3)
}

///|
test "int32 limits and closed-record and tagged rejection do not execute the handler" {
  let integer_registry = @capability.Registry::new()
  let integer_executions = Ref(0)
  let integer_registration = endpoint_register_echo(
    integer_registry,
    {
      id: "invalid.int32",
      schema: @capability.Schema::int(),
      value: @capability.Value::int(0),
      wire_json: "0",
    },
    integer_executions,
  )
  let integer_server = @mcp.ProtocolServer::new(
    @mcp.Adapter::new(integer_registry),
  )
  for (case_id, overflow) in [("upper", "2147483648"), ("lower", "-2147483649")] {
    let response = endpoint_parse_wire_reply(
      integer_server,
      endpoint_wire_request(
        "tools/call",
        "bad-int-\{case_id}",
        "\"name\":\"\{integer_registration.capability.descriptor().external_name()}\",\"arguments\":{\"value\":\{overflow}}",
      ),
    )
    endpoint_assert_invalid_params(response)
    assert_true(integer_executions.val == 0)
  }

  let closed_record = endpoint_schema_record([
    endpoint_schema_field("id", @capability.Schema::int(), true),
    endpoint_schema_field("label", @capability.Schema::string(), false),
  ])
  let record_registry = @capability.Registry::new()
  let record_executions = Ref(0)
  let record_registration = endpoint_register_echo(
    record_registry,
    {
      id: "invalid.closed_record",
      schema: closed_record,
      value: @capability.Value::object([("id", @capability.Value::int(1))]),
      wire_json: "{\"id\":1}",
    },
    record_executions,
  )
  let record_server = @mcp.ProtocolServer::new(
    @mcp.Adapter::new(record_registry),
  )
  for
    (case_id, args) in [
      ("unknown", "{\"id\":1,\"extra\":true}"),
      ("required", "{\"label\":\"missing id\"}"),
    ] {
    let response = endpoint_parse_wire_reply(
      record_server,
      endpoint_wire_request(
        "tools/call",
        "bad-record-\{case_id}",
        "\"name\":\"\{record_registration.capability.descriptor().external_name()}\",\"arguments\":\{args}",
      ),
    )
    endpoint_assert_invalid_params(response)
    assert_true(record_executions.val == 0)
  }

  let tagged_variant = match
    @capability.SchemaVariant::new("allowed", @capability.Schema::string()) {
    Ok(value) => value
    Err(_) => fail("single tagged test variant should be valid")
  }
  let tagged = match @capability.Schema::tagged("kind", [tagged_variant]) {
    Ok(value) => value
    Err(_) => fail("single tagged test schema should be valid")
  }
  let tagged_registry = @capability.Registry::new()
  let tagged_executions = Ref(0)
  let tagged_registration = endpoint_register_echo(
    tagged_registry,
    {
      id: "invalid.tagged_const",
      schema: tagged,
      value: @capability.Value::object([
        ("kind", @capability.Value::string("allowed")),
        ("value", @capability.Value::string("ok")),
      ]),
      wire_json: "{\"kind\":\"allowed\",\"value\":\"ok\"}",
    },
    tagged_executions,
  )
  let tagged_server = @mcp.ProtocolServer::new(
    @mcp.Adapter::new(tagged_registry),
  )
  let wrong_tag = endpoint_parse_wire_reply(
    tagged_server,
    endpoint_wire_request(
      "tools/call",
      "wrong-tag",
      "\"name\":\"\{tagged_registration.capability.descriptor().external_name()}\",\"arguments\":{\"kind\":\"rejected\",\"value\":\"no\"}",
    ),
  )
  endpoint_assert_invalid_params(wrong_tag)
  assert_true(tagged_executions.val == 0)
}

///|
test "quickcheck: generated bounded integer arrays preserve three lane results" {
  @quickcheck.check(
    (values : Array[Int]) => endpoint_generated_array_parity(values),
    count=64,
    max_size=24,
    max_shrinks=500,
    seed=2026100414,
  )
}
