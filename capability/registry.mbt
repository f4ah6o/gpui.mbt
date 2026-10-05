///|
/// Semantic operation kind. Commands mutate or cause effects, queries read the
/// application model, and workflows are explicitly declared compositions.
pub(all) enum OperationKind {
  Command
  Query
  Workflow
} derive(Eq)

///|
pub extend OperationKind with Eq::{not_equal, equal}

///|
pub(all) enum EffectClass {
  ReadOnly
  StateChange
  ExternalSideEffect
} derive(Eq)

///|
pub extend EffectClass with Eq::{not_equal, equal}

///|
/// Registration never implies remote exposure.
pub(all) enum Exposure {
  Internal
  Local
  External
} derive(Eq)

///|
pub extend Exposure with Eq::{not_equal, equal}

///|
pub(all) enum InvocationOrigin {
  Gui
  Direct
  LocalAutomation
  RemoteMcp
} derive(Eq)

///|
pub extend InvocationOrigin with Eq::{not_equal, equal}

///|
/// Stable semantic description shared by GUI, direct API, and adapters.
pub struct Descriptor {
  priv id : String
  priv external_name : String
  priv title : String
  priv description : String
  priv kind : OperationKind
  priv input_schema : Schema
  priv output_schema : Schema
  priv effect : EffectClass
  priv idempotent : Bool
  priv exposure : Exposure
  priv version : Int
}

///|
pub fn Descriptor::new(
  id : String,
  title : String,
  description : String,
  kind : OperationKind,
  input_schema : Schema,
  output_schema : Schema,
  effect : EffectClass,
  idempotent : Bool,
  exposure : Exposure,
  external_name : String?,
  version : Int,
) -> Result[Descriptor, @diagnostics.FrameworkError] {
  if id.length() == 0 {
    Err(
      capability_error(
        @diagnostics.InvalidInput,
        "descriptor",
        "capability id must not be empty",
      ),
    )
  } else if version <= 0 {
    Err(
      capability_error(
        @diagnostics.InvalidInput,
        "descriptor",
        "capability version must be positive",
      ),
    )
  } else {
    let mapped = match external_name {
      Some(name) =>
        if name.length() == 0 {
          return Err(
            capability_error(
              @diagnostics.InvalidInput,
              "descriptor",
              "explicit external name must not be empty",
            ),
          )
        } else {
          name
        }
      None => derive_external_name(id)
    }
    Ok({
      id,
      external_name: mapped,
      title,
      description,
      kind,
      input_schema,
      output_schema,
      effect,
      idempotent,
      exposure,
      version,
    })
  }
}

///|
pub fn Descriptor::id(self : Descriptor) -> String {
  self.id
}

///|
pub fn Descriptor::external_name(self : Descriptor) -> String {
  self.external_name
}

///|
pub fn Descriptor::title(self : Descriptor) -> String {
  self.title
}

///|
pub fn Descriptor::description(self : Descriptor) -> String {
  self.description
}

///|
pub fn Descriptor::kind(self : Descriptor) -> OperationKind {
  self.kind
}

///|
pub fn Descriptor::input_schema(self : Descriptor) -> Schema {
  self.input_schema
}

///|
pub fn Descriptor::output_schema(self : Descriptor) -> Schema {
  self.output_schema
}

///|
pub fn Descriptor::effect(self : Descriptor) -> EffectClass {
  self.effect
}

///|
pub fn Descriptor::is_idempotent(self : Descriptor) -> Bool {
  self.idempotent
}

///|
pub fn Descriptor::exposure(self : Descriptor) -> Exposure {
  self.exposure
}

///|
pub fn Descriptor::version(self : Descriptor) -> Int {
  self.version
}

///|
/// A strongly typed capability. Only the erased registry edge uses Value.
pub struct TypedCapability[I, O] {
  priv descriptor : Descriptor
  priv lifetime : Ref[RegistryLifetime?]
  priv decode : (Value) -> Result[I, @diagnostics.FrameworkError]
  priv encode : (O) -> Result[Value, @diagnostics.FrameworkError]
  priv validate_input : (I) -> Result[Unit, @diagnostics.FrameworkError]
  priv validate_output : (O) -> Result[Unit, @diagnostics.FrameworkError]
  priv handler : (I) -> Result[O, @diagnostics.FrameworkError]
  priv availability : () -> Result[Unit, @diagnostics.FrameworkError]
  priv policy : (InvocationOrigin) -> Result[Unit, @diagnostics.FrameworkError]
}

///|
pub fn[I, O] TypedCapability::new(
  descriptor : Descriptor,
  decode : (Value) -> Result[I, @diagnostics.FrameworkError],
  encode : (O) -> Result[Value, @diagnostics.FrameworkError],
  handler : (I) -> Result[O, @diagnostics.FrameworkError],
  availability : () -> Result[Unit, @diagnostics.FrameworkError],
  policy : (InvocationOrigin) -> Result[Unit, @diagnostics.FrameworkError],
) -> TypedCapability[I, O] {
  TypedCapability::new_with_validation(
    descriptor,
    decode,
    encode,
    _input => Ok(()),
    _output => Ok(()),
    handler,
    availability,
    policy,
  )
}

///|
/// Add shared domain validators without routing internal typed values through
/// the transport projection. Erased callers decode first, then use these same
/// validators and handler as direct and GUI callers.
pub fn[I, O] TypedCapability::new_with_validation(
  descriptor : Descriptor,
  decode : (Value) -> Result[I, @diagnostics.FrameworkError],
  encode : (O) -> Result[Value, @diagnostics.FrameworkError],
  validate_input : (I) -> Result[Unit, @diagnostics.FrameworkError],
  validate_output : (O) -> Result[Unit, @diagnostics.FrameworkError],
  handler : (I) -> Result[O, @diagnostics.FrameworkError],
  availability : () -> Result[Unit, @diagnostics.FrameworkError],
  policy : (InvocationOrigin) -> Result[Unit, @diagnostics.FrameworkError],
) -> TypedCapability[I, O] {
  {
    descriptor,
    lifetime: Ref(None),
    decode,
    encode,
    validate_input,
    validate_output,
    handler,
    availability,
    policy,
  }
}

///|
pub fn[I, O] TypedCapability::descriptor(
  self : TypedCapability[I, O],
) -> Descriptor {
  self.descriptor
}

///|
/// Invoke the typed domain operation without forcing its values through a
/// transport representation. External schema validation remains at the erased
/// boundary; domain validators and the handler are shared by all entry paths.
pub fn[I, O] TypedCapability::invoke(
  self : TypedCapability[I, O],
  origin : InvocationOrigin,
  input : I,
) -> Result[O, @diagnostics.FrameworkError] {
  match self.check(origin) {
    Err(error) => Err(error)
    Ok(_) => self.invoke_typed(input)
  }
}

///|
fn[I, O] TypedCapability::invoke_value(
  self : TypedCapability[I, O],
  origin : InvocationOrigin,
  input : Value,
) -> Result[Value, @diagnostics.FrameworkError] {
  // Own the public mutable arrays before any user-supplied authorization or
  // decoder closure runs; otherwise its aliases could change the request
  // after validation and before schema projection.
  match input.try_clone_transport() {
    Err(error) => Err(error)
    Ok(owned_input) =>
      match self.check(origin) {
        Err(error) => Err(error)
        Ok(_) =>
          if !self.descriptor.input_schema.accepts(owned_input) {
            Err(
              capability_error(
                @diagnostics.InvalidInput,
                self.descriptor.id,
                "input does not satisfy the declared schema",
              ),
            )
          } else {
            let decoded = (self.decode)(owned_input)
            match self.complete_stage(Ok(())) {
              Err(error) => return Err(error)
              Ok(_) => ()
            }
            match decoded {
              Err(error) =>
                Err(
                  boundary_conversion_error(
                    @diagnostics.InvalidInput,
                    self.descriptor.id,
                    "input conversion failed",
                    error,
                  ),
                )
              Ok(typed_input) =>
                match self.invoke_typed(typed_input) {
                  Err(error) => Err(error)
                  Ok(output) =>
                    match self.encode_output_value(output) {
                      Ok(encoded) => Ok(encoded)
                      Err(error) => Err(error)
                    }
                }
            }
          }
      }
  }
}

///|
fn[I, O] TypedCapability::invoke_typed(
  self : TypedCapability[I, O],
  input : I,
) -> Result[O, @diagnostics.FrameworkError] {
  match self.complete_stage(Ok(())) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match self.complete_stage((self.validate_input)(input)) {
    Err(error) => Err(error)
    Ok(_) =>
      match self.complete_stage((self.handler)(input)) {
        Err(error) => Err(error)
        Ok(output) =>
          match self.complete_stage((self.validate_output)(output)) {
            Err(error) => Err(error)
            Ok(_) => Ok(output)
          }
      }
  }
}

///|
fn[I, O] TypedCapability::encode_output_value(
  self : TypedCapability[I, O],
  output : O,
) -> Result[Value, @diagnostics.FrameworkError] {
  let encoded = (self.encode)(output)
  match self.complete_stage(Ok(())) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match encoded {
    Err(error) =>
      Err(
        projection_error(
          self.descriptor.id,
          "output conversion failed",
          Some(error),
        ),
      )
    Ok(encoded) =>
      match encoded.validate_transport() {
        Err(error) =>
          Err(
            projection_error(
              self.descriptor.id,
              "output is outside the transport-safe value subset",
              Some(error),
            ),
          )
        Ok(_) =>
          if self.descriptor.output_schema.accepts(encoded) {
            Ok(encoded)
          } else {
            Err(
              projection_error(
                self.descriptor.id,
                "output does not satisfy the declared schema",
                None,
              ),
            )
          }
      }
  }
}

///|
fn[I, O] TypedCapability::check(
  self : TypedCapability[I, O],
  origin : InvocationOrigin,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check_exposure(origin) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match self.complete_stage((self.availability)()) {
    Err(error) => Err(error)
    Ok(_) => self.complete_stage((self.policy)(origin))
  }
}

///|
fn[I, O] TypedCapability::check_exposure(
  self : TypedCapability[I, O],
  origin : InvocationOrigin,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.complete_stage(Ok(())) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if !exposure_allows(self.descriptor.exposure, origin) {
    Err(
      capability_error(
        @diagnostics.PermissionDenied,
        self.descriptor.id,
        "invocation origin is outside the capability exposure policy",
      ),
    )
  } else {
    Ok(())
  }
}

///|
fn[I, O] TypedCapability::authorize(
  self : TypedCapability[I, O],
  origin : InvocationOrigin,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check_exposure(origin) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  self.complete_stage((self.policy)(origin))
}

///|
/// Application callbacks can synchronously stop their owner. Check after each
/// callback before running the next stage or publishing its result/error.
fn[I, O, T] TypedCapability::complete_stage(
  self : TypedCapability[I, O],
  result : Result[T, @diagnostics.FrameworkError],
) -> Result[T, @diagnostics.FrameworkError] {
  match self.lifetime.val {
    None => result
    Some(lifetime) =>
      match lifetime.check("invoke") {
        Err(error) => Err(error)
        Ok(_) => result
      }
  }
}

///|
/// GUI controls bind to the typed capability rather than duplicating handlers.
pub struct GuiBinding[I, O] {
  priv capability : TypedCapability[I, O]
}

///|
pub fn[I, O] TypedCapability::gui_binding(
  self : TypedCapability[I, O],
) -> GuiBinding[I, O] {
  { capability: self, }
}

///|
pub fn[I, O] GuiBinding::trigger(
  self : GuiBinding[I, O],
  input : I,
) -> Result[O, @diagnostics.FrameworkError] {
  self.capability.invoke(Gui, input)
}

///|
pub fn[I, O] GuiBinding::is_enabled(self : GuiBinding[I, O]) -> Bool {
  self.capability.check(Gui) is Ok(_)
}

///|
priv struct RegistryEntry {
  begin : ((InvocationOrigin, Value, InvocationScope) -> Result[
    Invocation[Value],
    @diagnostics.FrameworkError,
  ])?
  descriptor : Descriptor
  authorize : (InvocationOrigin) -> Result[Unit, @diagnostics.FrameworkError]
  invoke : (InvocationOrigin, Value) -> Result[
    Value,
    @diagnostics.FrameworkError,
  ]
}

///|
priv struct RegistryState {
  entries : Array[RegistryEntry]
}

///|
priv struct RegistryLifetime {
  alive : Ref[Bool]
  owner : Ref[@core.AppLifetime?]
}

///|
fn RegistryLifetime::is_alive(self : RegistryLifetime) -> Bool {
  self.alive.val &&
  (match self.owner.val {
    None => true
    Some(owner) => owner.is_alive()
  })
}

///|
fn RegistryLifetime::check(
  self : RegistryLifetime,
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if !self.is_alive() {
    return Err(stale_registry_error(operation))
  }
  match self.owner.val {
    Some(owner) if !owner.is_running() =>
      Err(
        capability_error(
          @diagnostics.AppNotRunning,
          "registry.\{operation}",
          "capability owner has not started",
        ),
      )
    _ => Ok(())
  }
}

///|
/// Deterministic semantic registry. Entries are maintained in semantic-ID order
/// so enumeration and manifests do not depend on registration order.
pub struct Registry {
  priv state : Ref[RegistryState]
  priv lifetime : RegistryLifetime
}

///|
pub fn Registry::new() -> Registry {
  {
    state: Ref({ entries: [], }),
    lifetime: { alive: Ref(true), owner: Ref(None), },
  }
}

///|
pub fn Registry::is_alive(self : Registry) -> Bool {
  self.lifetime.is_alive()
}

///|
/// Construct a registry owned by an app. Configuration is allowed before
/// start; stopping the owner revokes all registry and typed/GUI handles.
pub fn Registry::new_owned(
  owner : @core.App,
) -> Result[Registry, @diagnostics.FrameworkError] {
  let registry = Registry::new()
  match registry.attach_owner(owner) {
    Err(error) => Err(error)
    Ok(_) => Ok(registry)
  }
}

///|
/// Adopt an existing registry, including handles already registered with it.
/// Ownership is irreversible; reattaching the same live owner is idempotent.
pub fn Registry::attach_owner(
  self : Registry,
  owner : @core.App,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if !self.is_alive() || !owner.lifetime().is_alive() {
    return Err(stale_registry_error("attach_owner"))
  }
  match self.lifetime.owner.val {
    Some(current) if current.app_id() != owner.id() =>
      Err(
        capability_error(
          @diagnostics.InvalidInput,
          "registry.attach_owner",
          "registry already belongs to another app",
        ),
      )
    _ => {
      self.lifetime.owner.val = Some(owner.lifetime())
      Ok(())
    }
  }
}

///|
pub fn[I, O] Registry::register(
  self : Registry,
  capability : TypedCapability[I, O],
) -> Result[Unit, @diagnostics.FrameworkError] {
  if !self.is_alive() {
    return Err(stale_registry_error("register"))
  }
  let descriptor = capability.descriptor()
  for entry in self.state.val.entries {
    if entry.descriptor.id == descriptor.id {
      return Err(
        capability_error(
          @diagnostics.InvalidInput,
          "registry.register",
          "duplicate capability id: \{descriptor.id}",
        ),
      )
    }
    if descriptor.exposure is External &&
      entry.descriptor.exposure is External &&
      entry.descriptor.external_name == descriptor.external_name {
      return Err(
        capability_error(
          @diagnostics.InvalidInput,
          "registry.register",
          "external name collision: \{descriptor.external_name}",
        ),
      )
    }
  }
  if capability.lifetime.val is Some(_) {
    return Err(
      capability_error(
        @diagnostics.InvalidInput,
        "registry.register",
        "capability already belongs to a registry",
      ),
    )
  }
  capability.lifetime.val = Some(self.lifetime)
  let erased = RegistryEntry::{
    descriptor,
    begin: None,
    authorize: origin => capability.check(origin),
    invoke: (origin, input) => capability.invoke_value(origin, input),
  }
  self.state.val.entries.push(erased)
  Ok(())
}

///|
pub fn Registry::descriptors(self : Registry) -> Array[Descriptor] {
  let values : Array[Descriptor] = []
  if self.is_alive() {
    for entry in self.state.val.entries {
      values.push(entry.descriptor)
    }
  }
  sort_descriptors(values)
}

///|
pub fn Registry::external_descriptors(self : Registry) -> Array[Descriptor] {
  let values : Array[Descriptor] = []
  if self.is_alive() {
    for entry in self.state.val.entries {
      if entry.descriptor.exposure is External {
        values.push(entry.descriptor)
      }
    }
  }
  sort_descriptors(values)
}

///|
pub fn Registry::invoke(
  self : Registry,
  id : String,
  origin : InvocationOrigin,
  input : Value,
) -> Result[Value, @diagnostics.FrameworkError] {
  match self.lifetime.check("invoke") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for entry in self.state.val.entries {
    if entry.descriptor.id == id {
      return (entry.invoke)(origin, input)
    }
  }
  Err(
    capability_error(
      @diagnostics.UnsupportedCapability,
      "registry.invoke",
      "unknown capability: \{id}",
    ),
  )
}

///|
pub fn Registry::invoke_external(
  self : Registry,
  external_name : String,
  origin : InvocationOrigin,
  input : Value,
) -> Result[Value, @diagnostics.FrameworkError] {
  match self.lifetime.check("invoke_external") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for entry in self.state.val.entries {
    if entry.descriptor.exposure is External &&
      entry.descriptor.external_name == external_name {
      return (entry.invoke)(origin, input)
    }
  }
  Err(
    capability_error(
      @diagnostics.UnsupportedCapability,
      "registry.invoke_external",
      "unknown external capability: \{external_name}",
    ),
  )
}

///|
/// Re-check liveness, availability, and origin policy without running the
/// capability handler. Adapters use this before replaying a cached response.
pub fn Registry::authorize_external(
  self : Registry,
  external_name : String,
  origin : InvocationOrigin,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.lifetime.check("authorize_external") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for entry in self.state.val.entries {
    if entry.descriptor.exposure is External &&
      entry.descriptor.external_name == external_name {
      return (entry.authorize)(origin)
    }
  }
  Err(
    capability_error(
      @diagnostics.UnsupportedCapability,
      "registry.authorize_external",
      "unknown external capability: \{external_name}",
    ),
  )
}

///|
/// Invalidate all registry, typed, GUI, and adapter-facing handles. Revocation
/// is permanent and repeated teardown is harmless.
pub fn Registry::teardown(self : Registry) -> Unit {
  self.lifetime.alive.val = false
  self.state.val.entries.clear()
}

///|
/// Deterministic transport-neutral manifest for explicitly external entries.
pub fn Registry::external_manifest_json(self : Registry) -> String {
  let builder = StringBuilder()
  builder.write_string("{\"schema_version\":1,\"capabilities\":[")
  let mut emitted = 0
  if self.is_alive() {
    for descriptor in self.external_descriptors() {
      if emitted > 0 {
        builder.write_string(",")
      }
      builder.write_string(descriptor_manifest_json(descriptor))
      emitted += 1
    }
  }
  builder.write_string("]}")
  builder.to_string()
}

///|
fn exposure_allows(exposure : Exposure, origin : InvocationOrigin) -> Bool {
  match origin {
    Gui | Direct => true
    LocalAutomation => !(exposure is Internal)
    RemoteMcp => exposure is External
  }
}

///|
fn derive_external_name(id : String) -> String {
  let builder = StringBuilder()
  for character in id {
    match character {
      '.' | '-' | '/' => builder.write_char('_')
      _ => builder.write_char(character)
    }
  }
  builder.to_string()
}

///|
fn sort_descriptors(values : Array[Descriptor]) -> Array[Descriptor] {
  let sorted : Array[Descriptor] = []
  for value in values {
    sorted.push(value)
  }
  let mut index = 0
  while index < sorted.length() {
    let mut minimum = index
    let mut candidate = index + 1
    while candidate < sorted.length() {
      if sorted[candidate].id < sorted[minimum].id {
        minimum = candidate
      }
      candidate += 1
    }
    if minimum != index {
      let previous = sorted[index]
      sorted[index] = sorted[minimum]
      sorted[minimum] = previous
    }
    index += 1
  }
  sorted
}

///|
fn descriptor_manifest_json(descriptor : Descriptor) -> String {
  "{\"id\":\"\{json_escape(descriptor.id)}\",\"external_name\":\"\{json_escape(descriptor.external_name)}\",\"title\":\"\{json_escape(descriptor.title)}\",\"description\":\"\{json_escape(descriptor.description)}\",\"kind\":\"\{operation_kind_label(descriptor.kind)}\",\"input_schema\":\{descriptor.input_schema.canonical_json()},\"output_schema\":\{descriptor.output_schema.canonical_json()},\"effect\":\"\{effect_label(descriptor.effect)}\",\"idempotent\":\{if descriptor.idempotent { "true" } else { "false" }},\"exposure\":\"external\",\"version\":\{descriptor.version}}"
}

///|
pub fn operation_kind_label(kind : OperationKind) -> String {
  match kind {
    Command => "command"
    Query => "query"
    Workflow => "workflow"
  }
}

///|
pub fn effect_label(effect : EffectClass) -> String {
  match effect {
    ReadOnly => "read_only"
    StateChange => "state_change"
    ExternalSideEffect => "external_side_effect"
  }
}

///|
fn stale_registry_error(operation : String) -> @diagnostics.FrameworkError {
  capability_error(
    @diagnostics.StaleHandle,
    "registry.\{operation}",
    "capability registry has been torn down",
  )
}

///|
fn boundary_conversion_error(
  code : @diagnostics.ErrorCode,
  operation : String,
  prefix : String,
  error : @diagnostics.FrameworkError,
) -> @diagnostics.FrameworkError {
  let detail = match error.message() {
    Some(message) => "\{prefix}: \{message}"
    None => prefix
  }
  capability_error(code, operation, detail)
}

///|
fn projection_error(
  operation : String,
  prefix : String,
  error : @diagnostics.FrameworkError?,
) -> @diagnostics.FrameworkError {
  let detail = match error {
    Some(cause) =>
      match cause.message() {
        Some(message) => "\{prefix}: \{message}"
        None => prefix
      }
    None => prefix
  }
  @diagnostics.FrameworkError::new(
    @diagnostics.ConversionFailed,
    operation,
    subsystem="capability_projection",
    message=detail,
  )
}

///|
fn capability_error(
  code : @diagnostics.ErrorCode,
  operation : String,
  message : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    code,
    operation,
    subsystem="capability",
    message~,
  )
}
