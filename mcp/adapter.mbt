///|
/// Protocol-facing failure categories kept distinct from semantic/domain errors.
pub(all) enum ErrorCode {
  UnknownOperation
  InvalidInput
  PermissionDenied
  Unavailable
  Stale
  DomainFailure
  AdapterClosed
} derive(Eq)

///|
pub extend ErrorCode with Eq::{not_equal, equal}

///|
pub struct AdapterError {
  priv code : ErrorCode
  priv message : String
}

///|
pub fn AdapterError::code(self : AdapterError) -> ErrorCode {
  self.code
}

///|
pub fn AdapterError::message(self : AdapterError) -> String {
  self.message
}

///|
pub struct Tool {
  priv name : String
  priv semantic_id : String
  priv title : String
  priv description : String
  priv input_schema_json : String
  priv output_schema_json : String
  priv read_only : Bool
  priv idempotent : Bool
}

///|
pub fn Tool::name(self : Tool) -> String {
  self.name
}

///|
pub fn Tool::semantic_id(self : Tool) -> String {
  self.semantic_id
}

///|
pub fn Tool::is_read_only(self : Tool) -> Bool {
  self.read_only
}

///|
pub struct Resource {
  priv uri : String
  priv semantic_id : String
  priv name : String
  priv description : String
  priv output_schema_json : String
}

///|
pub fn Resource::uri(self : Resource) -> String {
  self.uri
}

///|
pub fn Resource::semantic_id(self : Resource) -> String {
  self.semantic_id
}

///|
/// Inventory advertises only features implemented by this adapter. The initial
/// portable adapter implements tools and unit-input query resources, not prompts.
pub struct Inventory {
  priv tools : Array[Tool]
  priv resources : Array[Resource]
}

///|
pub fn Inventory::tools(self : Inventory) -> Array[Tool] {
  let result : Array[Tool] = []
  for tool in self.tools {
    result.push(tool)
  }
  result
}

///|
pub fn Inventory::resources(self : Inventory) -> Array[Resource] {
  let result : Array[Resource] = []
  for resource in self.resources {
    result.push(resource)
  }
  result
}

///|
pub fn Inventory::supports_tools(_self : Inventory) -> Bool {
  true
}

///|
pub fn Inventory::supports_resources(_self : Inventory) -> Bool {
  true
}

///|
pub fn Inventory::supports_prompts(_self : Inventory) -> Bool {
  false
}

///|
pub fn Inventory::canonical_json(self : Inventory) -> String {
  let builder = StringBuilder()
  builder.write_string("{\"tools\":[")
  for index, tool in self.tools {
    if index > 0 {
      builder.write_string(",")
    }
    builder.write_string(tool_json(tool))
  }
  builder.write_string("],\"resources\":[")
  for index, resource in self.resources {
    if index > 0 {
      builder.write_string(",")
    }
    builder.write_string(resource_json(resource))
  }
  builder.write_string("],\"prompts\":[]}")
  builder.to_string()
}

///|
priv struct AdapterState {
  mut open : Bool
}

///|
/// Optional protocol adapter. It owns no application state and no domain
/// handlers; every request returns through the semantic Registry.
pub struct Adapter {
  priv registry : @capability.Registry
  priv state : Ref[AdapterState]
}

///|
pub fn Adapter::new(registry : @capability.Registry) -> Adapter {
  { registry, state: Ref({ open: true, }), }
}

///|
pub fn Adapter::is_open(self : Adapter) -> Bool {
  self.state.val.open
}

///|
pub fn Adapter::close(self : Adapter) -> Unit {
  self.state.val.open = false
}

///|
pub fn Adapter::inventory(self : Adapter) -> Result[Inventory, AdapterError] {
  if !self.state.val.open {
    return Err({ code: AdapterClosed, message: "adapter is closed", })
  }
  if !self.registry.is_alive() {
    return Err({ code: Stale, message: "capability registry is not live", })
  }
  let tools : Array[Tool] = []
  let resources : Array[Resource] = []
  for descriptor in self.registry.external_descriptors() {
    if descriptor.kind() is @capability.Query &&
      descriptor.input_schema().is_unit() {
      resources.push(resource_from_descriptor(descriptor))
    } else {
      tools.push(tool_from_descriptor(descriptor))
    }
  }
  Ok({ tools, resources, })
}

///|
pub fn Adapter::call_tool(
  self : Adapter,
  name : String,
  input : @capability.Value,
) -> Result[@capability.Value, AdapterError] {
  if !self.state.val.open {
    return Err({ code: AdapterClosed, message: "adapter is closed", })
  }
  match self.registry.invoke_external(name, @capability.RemoteMcp, input) {
    Ok(value) => Ok(value)
    Err(error) => Err(map_error(error))
  }
}

///|
pub fn Adapter::read_resource(
  self : Adapter,
  uri : String,
) -> Result[@capability.Value, AdapterError] {
  if !self.state.val.open {
    return Err({ code: AdapterClosed, message: "adapter is closed", })
  }
  let inventory = match self.inventory() {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  for resource in inventory.resources {
    if resource.uri == uri {
      match
        self.registry.invoke(
          resource.semantic_id,
          @capability.RemoteMcp,
          @capability.Value::unit(),
        ) {
        Ok(value) => return Ok(value)
        Err(error) => return Err(map_error(error))
      }
    }
  }
  Err({ code: UnknownOperation, message: "unknown resource: \{uri}", })
}

///|
fn tool_from_descriptor(descriptor : @capability.Descriptor) -> Tool {
  {
    name: descriptor.external_name(),
    semantic_id: descriptor.id(),
    title: descriptor.title(),
    description: descriptor.description(),
    input_schema_json: descriptor.input_schema().canonical_json(),
    output_schema_json: descriptor.output_schema().canonical_json(),
    read_only: descriptor.effect() is @capability.ReadOnly,
    idempotent: descriptor.is_idempotent(),
  }
}

///|
fn resource_from_descriptor(descriptor : @capability.Descriptor) -> Resource {
  {
    uri: "gpui://capability/\{descriptor.external_name()}",
    semantic_id: descriptor.id(),
    name: descriptor.external_name(),
    description: descriptor.description(),
    output_schema_json: descriptor.output_schema().canonical_json(),
  }
}

///|
fn tool_json(tool : Tool) -> String {
  "{\"name\":\"\{@capability.json_escape(tool.name)}\",\"semantic_id\":\"\{@capability.json_escape(tool.semantic_id)}\",\"title\":\"\{@capability.json_escape(tool.title)}\",\"description\":\"\{@capability.json_escape(tool.description)}\",\"input_schema\":\{tool.input_schema_json},\"output_schema\":\{tool.output_schema_json},\"read_only\":\{if tool.read_only { "true" } else { "false" }},\"idempotent\":\{if tool.idempotent { "true" } else { "false" }}}"
}

///|
fn resource_json(resource : Resource) -> String {
  "{\"uri\":\"\{@capability.json_escape(resource.uri)}\",\"semantic_id\":\"\{@capability.json_escape(resource.semantic_id)}\",\"name\":\"\{@capability.json_escape(resource.name)}\",\"description\":\"\{@capability.json_escape(resource.description)}\",\"output_schema\":\{resource.output_schema_json}}"
}

///|
fn map_error(error : @diagnostics.FrameworkError) -> AdapterError {
  let code = match error.code() {
    @diagnostics.UnsupportedCapability => UnknownOperation
    @diagnostics.InvalidInput | @diagnostics.ConversionFailed => InvalidInput
    @diagnostics.PermissionDenied => PermissionDenied
    @diagnostics.EntityNotLive | @diagnostics.StaleHandle => Stale
    @diagnostics.AppNotRunning | @diagnostics.Busy => Unavailable
    _ => DomainFailure
  }
  let detail = match error.message() {
    Some(message) => message
    None => error.operation()
  }
  { code, message: detail, }
}
