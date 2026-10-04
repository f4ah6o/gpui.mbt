///|
/// Protocol-facing failure categories kept distinct from semantic/domain errors.
pub(all) enum ErrorCode {
  UnknownOperation
  InvalidInput
  PermissionDenied
  Unavailable
  Stale
  DomainFailure
  ProjectionFailed
  RequestConflict
  RequestInProgress
  OutcomeNotRetained
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
fn copy_adapter_error(error : AdapterError) -> AdapterError {
  { code: error.code, message: error.message, }
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
  mut completed_requests : Array[CompletedRequest]
  mut in_flight_requests : Array[InFlightRequest]
}

///|
priv struct CompletedRequest {
  request_id : String
  fingerprint : String
  outcome : Result[@capability.Value, AdapterError]?
}

///|
priv struct InFlightRequest {
  request_id : String
  fingerprint : String
}

///|
const MAX_REQUEST_ID_LENGTH : Int = 256

///|
const MAX_REQUEST_JSON_CHARS : Int = 1_048_576

///|
const MAX_RETAINED_REQUESTS : Int = 128

///|
const MAX_RETAINED_OUTCOME_CHARS : Int = 262_144

///|
const MAX_IN_FLIGHT_REQUESTS : Int = 128

///|
/// Optional protocol adapter. It owns no application state and no domain
/// handlers; every request returns through the semantic Registry.
pub struct Adapter {
  priv registry : @capability.Registry
  priv state : Ref[AdapterState]
}

///|
pub fn Adapter::new(registry : @capability.Registry) -> Adapter {
  {
    registry,
    state: Ref({ open: true, completed_requests: [], in_flight_requests: [], }),
  }
}

///|
pub fn Adapter::is_open(self : Adapter) -> Bool {
  self.state.val.open
}

///|
pub fn Adapter::close(self : Adapter) -> Unit {
  self.state.val.open = false
  self.state.val.completed_requests.clear()
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
  let inventory = match self.inventory() {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  for tool in inventory.tools {
    if tool.name == name {
      match
        self.registry.invoke(tool.semantic_id, @capability.RemoteMcp, input) {
        Ok(value) => return Ok(value)
        Err(error) => return Err(map_error(error))
      }
    }
  }
  Err({ code: UnknownOperation, message: "unknown tool: \{name}", })
}

///|
/// Call a tool with session-local duplicate suppression. The adapter retains
/// the most recent 128 terminal outcomes, with each successful result capped at
/// 256 KiB of canonical JSON; a larger result leaves a no-reexecution
/// tombstone. Requests older than the retention window may execute again. This
/// does not promise persistence across restart or exactly-once execution across
/// processes. Every replay re-checks registry liveness, availability, and
/// origin policy. Host cancellation/disconnect cannot interrupt a synchronous
/// handler that has started, so loss of the response is ambiguous.
pub fn Adapter::call_tool_with_request_id(
  self : Adapter,
  request_id : String,
  name : String,
  input : @capability.Value,
) -> Result[@capability.Value, AdapterError] {
  if !self.state.val.open {
    return Err({ code: AdapterClosed, message: "adapter is closed", })
  }
  if request_id.length() == 0 || request_id.length() > MAX_REQUEST_ID_LENGTH {
    return Err({
      code: InvalidInput,
      message: "request id must contain 1 to 256 characters",
    })
  }
  // The caller may retain and mutate public array/object storage. Own one
  // validated copy so later policy and decode callbacks cannot make the
  // request fingerprint diverge from the payload dispatched below.
  let owned_input = match input.try_clone_transport() {
    Err(error) => return Err(map_error(error))
    Ok(value) => value
  }
  let input_json = match owned_input.try_canonical_json() {
    Err(error) => return Err(map_error(error))
    Ok(json) => json
  }
  let fingerprint = "\{name.length()}:\{name};\{input_json.length()}:\{input_json}"
  if fingerprint.length() > MAX_REQUEST_JSON_CHARS {
    return Err({
      code: InvalidInput,
      message: "request exceeds the 1048576 character limit",
    })
  }
  for active in self.state.val.in_flight_requests {
    if active.request_id == request_id {
      if active.fingerprint != fingerprint {
        return Err({
          code: RequestConflict,
          message: "request id is already executing with different tool arguments",
        })
      }
      match self.registry.authorize_external(name, @capability.RemoteMcp) {
        Err(error) => return Err(map_error(error))
        Ok(_) => ()
      }
      if active.fingerprint == fingerprint {
        return Err({
          code: RequestInProgress,
          message: "request with this id is already executing",
        })
      }
      return Err({
        code: RequestConflict,
        message: "request id is already executing with different tool arguments",
      })
    }
  }
  for completed in self.state.val.completed_requests {
    if completed.request_id == request_id {
      if completed.fingerprint != fingerprint {
        return Err({
          code: RequestConflict,
          message: "request id was already used with different tool arguments",
        })
      }
      match self.registry.authorize_external(name, @capability.RemoteMcp) {
        Err(error) => return Err(map_error(error))
        Ok(_) => ()
      }
      return replay_outcome(completed.outcome)
    }
  }

  if self.state.val.in_flight_requests.length() >= MAX_IN_FLIGHT_REQUESTS {
    return Err({
      code: Unavailable,
      message: "adapter in-flight request limit has been reached",
    })
  }
  self.state.val.in_flight_requests.push({ request_id, fingerprint, })
  let outcome = self.call_tool(name, owned_input)
  self.remove_in_flight_request(request_id)
  if !self.state.val.open {
    return Err({
      code: AdapterClosed,
      message: "adapter closed while request ran; its domain effect may already be committed",
    })
  }
  let retained = match outcome {
    Ok(value) =>
      match value.try_canonical_json() {
        Ok(json) if json.length() <= MAX_RETAINED_OUTCOME_CHARS =>
          Some(Ok(value.clone()))
        _ => None
      }
    Err(error) => Some(Err(copy_adapter_error(error)))
  }
  if self.state.val.completed_requests.length() >= MAX_RETAINED_REQUESTS {
    let remaining : Array[CompletedRequest] = []
    let mut index = 1
    while index < self.state.val.completed_requests.length() {
      remaining.push(self.state.val.completed_requests[index])
      index += 1
    }
    self.state.val.completed_requests = remaining
  }
  self.state.val.completed_requests.push({
    request_id,
    fingerprint,
    outcome: retained,
  })
  outcome
}

///|
fn Adapter::remove_in_flight_request(
  self : Adapter,
  request_id : String,
) -> Unit {
  let remaining : Array[InFlightRequest] = []
  for active in self.state.val.in_flight_requests {
    if active.request_id != request_id {
      remaining.push(active)
    }
  }
  self.state.val.in_flight_requests = remaining
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
    @diagnostics.InvalidInput => InvalidInput
    @diagnostics.ConversionFailed =>
      if error.subsystem() is Some("capability_projection") {
        ProjectionFailed
      } else {
        DomainFailure
      }
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

///|
fn replay_outcome(
  outcome : Result[@capability.Value, AdapterError]?,
) -> Result[@capability.Value, AdapterError] {
  match outcome {
    None =>
      Err({
        code: OutcomeNotRetained,
        message: "request already completed; its large result was not retained, and it will not be executed again",
      })
    Some(Ok(value)) => Ok(value.clone())
    Some(Err(error)) => Err(copy_adapter_error(error))
  }
}
