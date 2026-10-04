///|
/// The released stateless MCP revision implemented by this adapter.
pub const MCP_PROTOCOL_VERSION : String = "2026-07-28"

///|
/// The protocol router is optional and sits above the semantic adapter. It
/// implements a deliberately small, stateless JSON-RPC surface: discovery,
/// tools, and unit-input query resources.
pub struct ProtocolServer {
  priv adapter : Adapter
  priv server_name : String
  priv server_version : String
}

///|
pub fn ProtocolServer::new(adapter : Adapter) -> ProtocolServer {
  ProtocolServer::new_with_identity(adapter, "gpui-mcp-adapter", "0.1.0")
}

///|
/// Create a protocol server with an application identity used in each modern
/// response's serverInfo metadata.
pub fn ProtocolServer::new_with_identity(
  adapter : Adapter,
  server_name : String,
  server_version : String,
) -> ProtocolServer {
  { adapter, server_name, server_version, }
}

///|
/// Closing a protocol server closes its underlying adapter. This invalidates
/// future dispatch but cannot undo a handler that has already committed.
pub fn ProtocolServer::close(self : ProtocolServer) -> Unit {
  self.adapter.close()
}

///|
/// Return the canonical result payload used by tools/list. This is also the
/// source for the checked-in reference inventory fixture.
pub fn ProtocolServer::tools_list_result_json(
  self : ProtocolServer,
) -> Result[String, AdapterError] {
  let inventory = match self.adapter.inventory() {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  let builder = StringBuilder()
  builder.write_string("{\"resultType\":\"complete\",\"tools\":[")
  for index, tool in inventory.tools() {
    if index > 0 {
      builder.write_string(",")
    }
    builder.write_string(tool_wire_json(tool))
  }
  builder.write_string(
    "],\"ttlMs\":0,\"cacheScope\":\"private\",\{self.server_info_meta_json()}}",
  )
  Ok(builder.to_string())
}

///|
pub fn ProtocolServer::handle_line(
  self : ProtocolServer,
  line : String,
) -> String? {
  if !self.adapter.is_open() {
    return Some(self.error("null", -32600, "Server is closed"))
  }
  if line.length() > MAX_REQUEST_JSON_CHARS {
    return Some(self.error("null", -32700, "Request exceeds the size limit"))
  }
  if !validate_unique_json_keys(line) {
    return Some(self.error("null", -32700, "Parse error"))
  }
  let message = @json.parse(line) catch {
    _ => return Some(self.error("null", -32700, "Parse error"))
  }
  match message {
    Json::Object(fields) => {
      let rpc_method = match fields.get("method") {
        Some(Json::String(value)) => value
        _ => return Some(self.error("null", -32600, "Invalid Request"))
      }
      match fields.get("id") {
        None =>
          // Notifications never receive a JSON-RPC response. The current
          // stdio host dispatches synchronous handlers on the input loop, so a
          // cancellation notification cannot interrupt one after it starts.
          // Late/unknown cancellations are safely ignored by the protocol.
          None
        Some(id) => {
          if !is_valid_request_id(id) {
            return Some(self.error("null", -32600, "Invalid Request"))
          }
          let id_json = id.stringify()
          if !(fields.get("jsonrpc") is Some(Json::String("2.0"))) {
            return Some(self.error(id_json, -32600, "Invalid Request"))
          }
          let params = match fields.get("params") {
            None => Json::object(Map([]))
            Some(value) =>
              match value {
                Json::Object(_) => value
                _ => return Some(self.error(id_json, -32602, "Invalid params"))
              }
          }
          match validate_request_metadata(params) {
            Some((code, message, data)) =>
              Some(self.error_with_data(id_json, code, message, data))
            None => self.dispatch(id_json, rpc_method, params)
          }
        }
      }
    }
    _ => Some(self.error("null", -32600, "Invalid Request"))
  }
}

///|
fn ProtocolServer::dispatch(
  self : ProtocolServer,
  id_json : String,
  rpc_method : String,
  params : Json,
) -> String? {
  match rpc_method {
    "server/discover" =>
      Some(self.result(id_json, self.discovery_result_json()))
    "tools/list" =>
      match self.tools_list_result_json() {
        Ok(result) => Some(self.result(id_json, result))
        Err(_) =>
          Some(
            self.error(
              id_json, -32603, "The capability inventory is unavailable",
            ),
          )
      }
    "tools/call" => self.call_tool(id_json, params)
    "resources/list" => self.list_resources(id_json)
    "resources/read" => self.read_resource(id_json, params)
    _ => Some(self.error(id_json, -32601, "Method not found"))
  }
}

///|
fn ProtocolServer::call_tool(
  self : ProtocolServer,
  id_json : String,
  params : Json,
) -> String? {
  let name = match json_member(params, "name") {
    Some(Json::String(value)) => value
    _ => return Some(self.error(id_json, -32602, "Invalid params"))
  }
  let arguments = match json_member(params, "arguments") {
    None => Json::object(Map([]))
    Some(value) =>
      match value {
        Json::Object(_) => value
        _ => return Some(self.error(id_json, -32602, "Invalid params"))
      }
  }
  let node_budget = Ref(0)
  if !json_within_transport_limits(arguments, 0, node_budget) {
    return Some(
      self.result(
        id_json,
        self.tool_error_result_json("Tool arguments exceed transport limits"),
      ),
    )
  }
  let inventory = match self.adapter.inventory() {
    Err(_) =>
      return Some(
        self.error(id_json, -32603, "The capability inventory is unavailable"),
      )
    Ok(value) => value
  }
  let mut input : @capability.Value? = None
  for tool in inventory.tools() {
    if tool.name() == name {
      input = match tool_arguments_to_value(tool, arguments) {
        Ok(value) => Some(value)
        Err(message) =>
          return Some(
            self.result(id_json, self.tool_error_result_json(message)),
          )
      }
    }
  }
  let input = match input {
    None => return Some(self.error(id_json, -32602, "Unknown tool"))
    Some(value) => value
  }
  match input.validate_transport() {
    Err(_) =>
      return Some(
        self.result(
          id_json,
          self.tool_error_result_json("Tool arguments exceed transport limits"),
        ),
      )
    Ok(_) => ()
  }
  match self.adapter.call_tool(name, input) {
    Ok(value) =>
      match value.try_canonical_json() {
        Ok(json) =>
          Some(self.result(id_json, self.tool_success_result_json(json)))
        Err(_) =>
          Some(
            self.result(
              id_json,
              self.tool_error_result_json("Tool result is not transport-safe"),
            ),
          )
      }
    Err(error) if error.code() is UnknownOperation =>
      Some(self.error(id_json, -32602, "Unknown tool"))
    Err(error) =>
      Some(self.result(id_json, self.tool_error_result_json(error.message())))
  }
}

///|
fn ProtocolServer::list_resources(
  self : ProtocolServer,
  id_json : String,
) -> String? {
  let inventory = match self.adapter.inventory() {
    Err(_) =>
      return Some(
        self.error(id_json, -32603, "The capability inventory is unavailable"),
      )
    Ok(value) => value
  }
  let builder = StringBuilder()
  builder.write_string("{\"resultType\":\"complete\",\"resources\":[")
  for index, resource in inventory.resources() {
    if index > 0 {
      builder.write_string(",")
    }
    builder.write_string(resource_wire_json(resource))
  }
  builder.write_string(
    "],\"ttlMs\":0,\"cacheScope\":\"private\",\{self.server_info_meta_json()}}",
  )
  Some(self.result(id_json, builder.to_string()))
}

///|
fn ProtocolServer::read_resource(
  self : ProtocolServer,
  id_json : String,
  params : Json,
) -> String? {
  let uri = match json_member(params, "uri") {
    Some(Json::String(value)) => value
    _ => return Some(self.error(id_json, -32602, "Invalid params"))
  }
  match self.adapter.read_resource(uri) {
    Ok(value) =>
      match value.try_canonical_json() {
        Ok(json) => {
          let inventory = match self.adapter.inventory() {
            Ok(value) => value
            Err(_) =>
              return Some(
                self.error(
                  id_json, -32603, "The capability inventory is unavailable",
                ),
              )
          }
          let mut known = false
          for resource in inventory.resources() {
            if resource.uri() == uri {
              known = true
            }
          }
          if !known {
            return Some(self.error(id_json, -32602, "Resource not found"))
          }
          Some(
            self.result(
              id_json,
              "{\"resultType\":\"complete\",\"contents\":[{\"uri\":\"\{@capability.json_escape(uri)}\",\"mimeType\":\"application/json\",\"text\":\"\{@capability.json_escape(json)}\"}],\"ttlMs\":0,\"cacheScope\":\"private\",\{self.server_info_meta_json()}}",
            ),
          )
        }
        Err(_) =>
          Some(self.error(id_json, -32603, "Resource result is not valid JSON"))
      }
    Err(error) if error.code() is UnknownOperation =>
      Some(self.error(id_json, -32602, "Resource not found"))
    Err(_) => Some(self.error(id_json, -32603, "Resource read failed"))
  }
}

///|
fn ProtocolServer::discovery_result_json(self : ProtocolServer) -> String {
  "{\"resultType\":\"complete\",\"supportedVersions\":[\"\{MCP_PROTOCOL_VERSION}\"],\"capabilities\":{\"tools\":{\"listChanged\":false},\"resources\":{}},\"ttlMs\":0,\"cacheScope\":\"private\",\{self.server_info_meta_json()}}"
}

///|
fn ProtocolServer::result(
  _self : ProtocolServer,
  id_json : String,
  result_json : String,
) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\{id_json},\"result\":\{result_json}}"
}

///|
fn ProtocolServer::error(
  _self : ProtocolServer,
  id_json : String,
  code : Int,
  message : String,
) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\{id_json},\"error\":{\"code\":\{code},\"message\":\"\{@capability.json_escape(message)}\"}}"
}

///|
fn ProtocolServer::error_with_data(
  _self : ProtocolServer,
  id_json : String,
  code : Int,
  message : String,
  data_json : String,
) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\{id_json},\"error\":{\"code\":\{code},\"message\":\"\{@capability.json_escape(message)}\",\"data\":\{data_json}}}"
}

///|
fn ProtocolServer::server_info_meta_json(self : ProtocolServer) -> String {
  "\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"\{@capability.json_escape(self.server_name)}\",\"version\":\"\{@capability.json_escape(self.server_version)}\"}}"
}

///|
fn ProtocolServer::tool_success_result_json(
  self : ProtocolServer,
  value_json : String,
) -> String {
  "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"\{@capability.json_escape(value_json)}\"}],\"structuredContent\":\{value_json},\"isError\":false,\{self.server_info_meta_json()}}"
}

///|
fn ProtocolServer::tool_error_result_json(
  self : ProtocolServer,
  message : String,
) -> String {
  "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"\{@capability.json_escape(message)}\"}],\"isError\":true,\{self.server_info_meta_json()}}"
}

///|
fn tool_wire_json(tool : Tool) -> String {
  let input_schema = if tool.input_is_unit() {
    "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}"
  } else if tool.input_is_object() {
    let schema = tool.input_schema_json()
    if schema.has_prefix("{\"type\":\"object\"") {
      schema
    } else {
      "{\"type\":\"object\",\"allOf\":[\{schema}]}"
    }
  } else {
    "{\"type\":\"object\",\"properties\":{\"value\":\{tool.input_schema_json()}},\"required\":[\"value\"],\"additionalProperties\":false}"
  }
  let read_only = if tool.is_read_only() { "true" } else { "false" }
  let idempotent = if tool.is_idempotent() { "true" } else { "false" }
  "{\"name\":\"\{@capability.json_escape(tool.name())}\",\"title\":\"\{@capability.json_escape(tool.title())}\",\"description\":\"\{@capability.json_escape(tool.description())}\",\"inputSchema\":\{input_schema},\"outputSchema\":\{tool.output_schema_json()},\"annotations\":{\"readOnlyHint\":\{read_only},\"idempotentHint\":\{idempotent}}}"
}

///|
fn resource_wire_json(resource : Resource) -> String {
  "{\"uri\":\"\{@capability.json_escape(resource.uri())}\",\"name\":\"\{@capability.json_escape(resource.name())}\",\"description\":\"\{@capability.json_escape(resource.description())}\",\"mimeType\":\"application/json\"}"
}

///|
fn tool_arguments_to_value(
  tool : Tool,
  arguments : Json,
) -> Result[@capability.Value, String] {
  match arguments {
    Json::Object(fields) =>
      if tool.input_is_unit() {
        if fields.length() == 0 {
          Ok(@capability.Value::unit())
        } else {
          Err("This tool accepts no arguments")
        }
      } else {
        let schema = @json.parse(tool.input_schema_json()) catch {
          _ => return Err("Capability input schema is invalid")
        }
        if tool.input_is_object() {
          json_to_schema_value(arguments, schema, 0, Ref(0))
        } else if fields.length() == 1 {
          match fields.get("value") {
            Some(value) => json_to_schema_value(value, schema, 0, Ref(0))
            None => Err("Scalar tool input must be provided as arguments.value")
          }
        } else {
          Err("Scalar tool input must contain only arguments.value")
        }
      }
    _ => Err("Tool arguments must be a JSON object")
  }
}

///|
fn json_to_schema_value(
  value : Json,
  schema : Json,
  depth : Int,
  nodes : Ref[Int],
) -> Result[@capability.Value, String] {
  nodes.val += 1
  if depth > 32 || nodes.val > 10_000 {
    return Err("Tool arguments exceed transport limits")
  }
  match json_member(schema, "anyOf") {
    Some(Json::Array(choices)) => {
      if value is Json::Null {
        return Ok(@capability.Value::unit())
      }
      for choice in choices {
        if !(json_member(choice, "type") is Some(Json::String("null"))) {
          return json_to_schema_value(value, choice, depth + 1, nodes)
        }
      }
      return Err("Optional input schema has no value branch")
    }
    _ => ()
  }
  match json_member(schema, "oneOf") {
    Some(Json::Array(choices)) => {
      for choice in choices {
        if tagged_choice_matches(value, choice) {
          return json_to_schema_value(value, choice, depth + 1, nodes)
        }
      }
      return Err("Input does not match a tagged variant")
    }
    _ => ()
  }
  match json_member(schema, "const") {
    Some(Json::String(expected)) =>
      match value {
        Json::String(actual) if actual == expected =>
          return Ok(@capability.Value::string(actual))
        _ => return Err("Input does not match a tagged discriminator")
      }
    _ => ()
  }
  let schema_type = match json_member(schema, "type") {
    Some(Json::String(value)) => value
    _ => return Err("Unsupported capability input schema")
  }
  match value {
    Json::Null =>
      if schema_type == "null" {
        Ok(@capability.Value::unit())
      } else {
        Err("Expected a non-null value")
      }
    Json::True | Json::False =>
      if schema_type == "boolean" {
        Ok(@capability.Value::bool(value is Json::True))
      } else {
        Err("Expected a value matching the capability schema")
      }
    Json::String(text) =>
      if schema_type == "string" {
        Ok(@capability.Value::string(text))
      } else {
        Err("Expected a value matching the capability schema")
      }
    Json::Number(number, ..) =>
      if schema_type == "number" {
        Ok(@capability.Value::number(number))
      } else if schema_type == "integer" &&
        number >= -2147483648.0 &&
        number <= 2147483647.0 &&
        number == number.to_int().to_double() {
        Ok(@capability.Value::int(number.to_int()))
      } else {
        Err("Expected a value matching the capability schema")
      }
    Json::Array(values) => {
      if schema_type != "array" {
        return Err("Expected a value matching the capability schema")
      }
      let item_schema = match json_member(schema, "items") {
        Some(value) => value
        None => return Err("Array input schema has no items schema")
      }
      let result : Array[@capability.Value] = []
      for child in values {
        match json_to_schema_value(child, item_schema, depth + 1, nodes) {
          Ok(value) => result.push(value)
          Err(message) => return Err(message)
        }
      }
      Ok(@capability.Value::array(result))
    }
    Json::Object(fields) => {
      if schema_type != "object" {
        return Err("Expected a value matching the capability schema")
      }
      let properties = match json_member(schema, "properties") {
        Some(Json::Object(value)) => value
        _ => return Err("Object input schema has no properties")
      }
      let result : Array[(String, @capability.Value)] = []
      for (key, child) in fields.to_array() {
        let child_schema = match properties.get(key) {
          Some(value) => value
          None => return Err("Unknown input field")
        }
        match json_to_schema_value(child, child_schema, depth + 1, nodes) {
          Ok(value) => result.push((key, value))
          Err(message) => return Err(message)
        }
      }
      Ok(@capability.Value::object(result))
    }
  }
}

///|
fn tagged_choice_matches(value : Json, choice : Json) -> Bool {
  let actual = match value {
    Json::Object(fields) => fields
    _ => return false
  }
  let properties = match json_member(choice, "properties") {
    Some(Json::Object(fields)) => fields
    _ => return false
  }
  for (key, property_schema) in properties.to_array() {
    match json_member(property_schema, "const") {
      Some(Json::String(expected)) =>
        match actual.get(key) {
          Some(Json::String(got)) if expected == got => return true
          _ => ()
        }
      _ => ()
    }
  }
  false
}

///|
fn json_within_transport_limits(
  value : Json,
  depth : Int,
  nodes : Ref[Int],
) -> Bool {
  nodes.val += 1
  if depth > 32 || nodes.val > 10_000 {
    return false
  }
  match value {
    Json::Array(values) => {
      for child in values {
        if !json_within_transport_limits(child, depth + 1, nodes) {
          return false
        }
      }
      true
    }
    Json::Object(fields) => {
      for (_, child) in fields.to_array() {
        if !json_within_transport_limits(child, depth + 1, nodes) {
          return false
        }
      }
      true
    }
    _ => true
  }
}

///|
fn json_member(value : Json, key : String) -> Json? {
  match value {
    Json::Object(fields) => fields.get(key)
    _ => None
  }
}

///|
fn is_valid_request_id(value : Json) -> Bool {
  match value {
    Json::String(value) => value.length() <= 256
    Json::Number(number, ..) =>
      number == number &&
      number >= -9007199254740991.0 &&
      number <= 9007199254740991.0 &&
      number == number.floor()
    _ => false
  }
}

///|
fn validate_request_metadata(params : Json) -> (Int, String, String)? {
  let meta = match json_member(params, "_meta") {
    Some(value) if value is Json::Object(_) => value
    _ => return Some((-32602, "Missing protocol request metadata", "{}"))
  }
  let version = match
    json_member(meta, "io.modelcontextprotocol/protocolVersion") {
    Some(Json::String(value)) => value
    _ => return Some((-32602, "Missing protocol version metadata", "{}"))
  }
  match json_member(meta, "io.modelcontextprotocol/clientCapabilities") {
    Some(Json::Object(_)) => ()
    _ => return Some((-32602, "Missing client capabilities metadata", "{}"))
  }
  if version != MCP_PROTOCOL_VERSION {
    Some(
      (
        -32022,
        "Unsupported protocol version",
        "{\"supported\":[\"\{MCP_PROTOCOL_VERSION}\"],\"requested\":\"\{@capability.json_escape(version)}\"}",
      ),
    )
  } else {
    None
  }
}
