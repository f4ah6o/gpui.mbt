///|
/// A portable capability family for services supplied by an application host.
/// Privileged services are absent unless the host explicitly grants them.
pub(all) enum Service {
  Clipboard
  FileDialog
  FileSystem
  Notifications
  Shell
  PersistentStorage
  WindowControls
  Menus
  ApplicationMetadata
  ProcessEnvironment
  Updates
  Lifecycle
} derive(Eq)

///|
pub extend Service with Eq::{not_equal, equal}

///|
pub(all) enum CapabilityState {
  Unavailable
  Available
  RequiresUserGesture
  PermissionRequired
} derive(Eq)

///|
pub extend CapabilityState with Eq::{not_equal, equal}

///|
pub struct ServiceCapability {
  service : Service
  state : CapabilityState
}

///|
pub fn ServiceCapability::new(
  service : Service,
  state : CapabilityState,
) -> ServiceCapability {
  { service, state, }
}

///|
pub fn ServiceCapability::service(self : ServiceCapability) -> Service {
  self.service
}

///|
pub fn ServiceCapability::state(self : ServiceCapability) -> CapabilityState {
  self.state
}

///|
/// The migration contract names operations rather than mirroring a host API.
/// A host adapter must still apply its own allowlist before executing one.
pub(all) enum Operation {
  ClipboardReadText
  ClipboardWriteText
  FileDialogOpen
  FileDialogSave
  FileReadText
  FileWriteText
  NotificationShow
  OpenExternalUrl
  StorageRead
  StorageWrite
  StorageRemove
  WindowMinimize
  WindowToggleMaximize
  WindowClose
  ApplicationMetadataRead
  ProcessEnvironmentRead
  UpdateCheck
  UpdateInstall
  LifecycleQuit
} derive(Eq)

///|
pub extend Operation with Eq::{not_equal, equal}

///|
pub fn Operation::service(self : Operation) -> Service {
  match self {
    ClipboardReadText | ClipboardWriteText => Clipboard
    FileDialogOpen | FileDialogSave => FileDialog
    FileReadText | FileWriteText => FileSystem
    NotificationShow => Notifications
    OpenExternalUrl => Shell
    StorageRead | StorageWrite | StorageRemove => PersistentStorage
    WindowMinimize | WindowToggleMaximize | WindowClose => WindowControls
    ApplicationMetadataRead => ApplicationMetadata
    ProcessEnvironmentRead => ProcessEnvironment
    UpdateCheck | UpdateInstall => Updates
    LifecycleQuit => Lifecycle
  }
}

///|
pub fn Operation::label(self : Operation) -> String {
  match self {
    ClipboardReadText => "clipboard.read_text"
    ClipboardWriteText => "clipboard.write_text"
    FileDialogOpen => "file_dialog.open"
    FileDialogSave => "file_dialog.save"
    FileReadText => "file_system.read_text"
    FileWriteText => "file_system.write_text"
    NotificationShow => "notifications.show"
    OpenExternalUrl => "shell.open_external_url"
    StorageRead => "storage.read"
    StorageWrite => "storage.write"
    StorageRemove => "storage.remove"
    WindowMinimize => "window.minimize"
    WindowToggleMaximize => "window.toggle_maximize"
    WindowClose => "window.close"
    ApplicationMetadataRead => "application.metadata_read"
    ProcessEnvironmentRead => "process.environment_read"
    UpdateCheck => "updates.check"
    UpdateInstall => "updates.install"
    LifecycleQuit => "lifecycle.quit"
  }
}

///|
/// A host-owned logical scope. It is a monotonically issued value, never a JS,
/// Electron, Tauri, or native handle.
pub struct ScopeId {
  value : UInt64
}

///|
pub fn ScopeId::value(self : ScopeId) -> UInt64 {
  self.value
}

///|
pub struct RequestId {
  value : UInt64
}

///|
pub fn RequestId::value(self : RequestId) -> UInt64 {
  self.value
}

///|
/// Versioned JSON-compatible request sent from a portable app to its host.
pub struct ServiceRequest {
  id : RequestId
  scope : ScopeId
  operation : Operation
  input : @capability.Value
}

///|
pub fn ServiceRequest::id(self : ServiceRequest) -> RequestId {
  self.id
}

///|
pub fn ServiceRequest::scope(self : ServiceRequest) -> ScopeId {
  self.scope
}

///|
pub fn ServiceRequest::operation(self : ServiceRequest) -> Operation {
  self.operation
}

///|
pub fn ServiceRequest::input(self : ServiceRequest) -> @capability.Value {
  clone_value(self.input)
}

///|
/// Stable wire envelope used by Electron preload and Tauri invoke adapters.
pub fn ServiceRequest::canonical_json(self : ServiceRequest) -> String {
  "{\"version\":1,\"requestId\":\"\{self.id.value}\",\"scopeId\":\"\{self.scope.value}\",\"operation\":\"\{self.operation.label()}\",\"input\":\{self.input.canonical_json()}}"
}

///|
const MAX_LIVE_SCOPES : Int = 1024

///|
const MAX_QUEUED_RESULTS : Int = 1024

///|
const MAX_REQUEST_JSON_BYTES : Int = 1_048_576

///|
pub struct ServiceCompletion {
  id : RequestId
  scope : ScopeId
  result : Result[@capability.Value, @diagnostics.FrameworkError]
}

///|
pub fn ServiceCompletion::id(self : ServiceCompletion) -> RequestId {
  self.id
}

///|
pub fn ServiceCompletion::scope(self : ServiceCompletion) -> ScopeId {
  self.scope
}

///|
pub fn ServiceCompletion::result(
  self : ServiceCompletion,
) -> Result[@capability.Value, @diagnostics.FrameworkError] {
  match self.result {
    Err(error) => Err(error)
    Ok(value) => Ok(clone_value(value))
  }
}

///|
/// Deterministic host-service queue. Requests and completions own copied
/// framework values; adapters never receive mutable app objects or host handles.
pub struct ServiceBridge {
  capabilities : Array[ServiceCapability]
  live_scopes : Array[ScopeId]
  pending : Array[ServiceRequest]
  outbound : Array[ServiceRequest]
  completions : Array[ServiceCompletion]
  mut next_scope : UInt64
  mut next_request : UInt64
  mut closed : Bool
}

///|
/// Reject duplicate capability declarations so adapters cannot disagree about
/// which declaration wins. An empty list is default-deny.
pub fn ServiceBridge::new(
  capabilities : Array[ServiceCapability],
) -> Result[ServiceBridge, @diagnostics.FrameworkError] {
  let owned : Array[ServiceCapability] = []
  for capability in capabilities {
    for prior in owned {
      if prior.service == capability.service {
        return Err(
          service_error(
            @diagnostics.InvalidInput,
            "service_bridge.new",
            "duplicate host-service capability declaration",
          ),
        )
      }
    }
    owned.push(capability)
  }
  Ok({
    capabilities: owned,
    live_scopes: [],
    pending: [],
    outbound: [],
    completions: [],
    next_scope: 1,
    next_request: 1,
    closed: false,
  })
}

///|
pub fn ServiceBridge::new_scope(
  self : ServiceBridge,
) -> Result[ScopeId, @diagnostics.FrameworkError] {
  if self.closed {
    Err(
      service_error(
        @diagnostics.HostStopping,
        "service_bridge.new_scope",
        "the host-service bridge is closed",
      ),
    )
  } else if self.next_scope == 0xffff_ffff_ffff_ffff {
    Err(
      service_error(
        @diagnostics.ResourceExhausted,
        "service_bridge.new_scope",
        "logical service scope ids are exhausted",
      ),
    )
  } else if self.live_scopes.length() >= MAX_LIVE_SCOPES {
    Err(
      service_error(
        @diagnostics.ResourceExhausted,
        "service_bridge.new_scope",
        "the live host-service scope limit has been reached",
      ),
    )
  } else {
    let scope = ScopeId::{ value: self.next_scope, }
    self.next_scope += 1
    self.live_scopes.push(scope)
    Ok(scope)
  }
}

///|
/// Queue a copied request. Unlisted and explicitly unavailable services fail
/// before any host adapter is called.
pub fn ServiceBridge::request(
  self : ServiceBridge,
  scope : ScopeId,
  operation : Operation,
  input : @capability.Value,
) -> Result[RequestId, @diagnostics.FrameworkError] {
  if self.closed {
    Err(
      service_error(
        @diagnostics.HostStopping,
        "service_bridge.request",
        "the host-service bridge is closed",
      ),
    )
  } else if !self.contains_scope(scope) {
    Err(
      service_error(
        @diagnostics.StaleHandle,
        "service_bridge.request",
        "the logical service scope is no longer live",
      ),
    )
  } else if !self.service_enabled(operation.service()) {
    Err(
      service_error(
        @diagnostics.UnsupportedCapability,
        "service_bridge.request",
        "the host did not grant \{operation.service().label()}",
      ),
    )
  } else if self.pending.length() + self.completions.length() >=
    MAX_QUEUED_RESULTS {
    Err(
      service_error(
        @diagnostics.ResourceExhausted,
        "service_bridge.request",
        "drain host-service requests or completions before submitting more",
      ),
    )
  } else {
    match input.try_canonical_json() {
      Err(error) => Err(error)
      Ok(_) if self.next_request == 0xffff_ffff_ffff_ffff =>
        Err(
          service_error(
            @diagnostics.ResourceExhausted,
            "service_bridge.request",
            "host-service request ids are exhausted",
          ),
        )
      Ok(input_json) => {
        let id = RequestId::{ value: self.next_request, }
        let prefix = "{\"version\":1,\"requestId\":\"\{id.value}\",\"scopeId\":\"\{scope.value}\",\"operation\":\"\{operation.label()}\",\"input\":"
        if utf8_byte_length(prefix) + utf8_byte_length(input_json) + 1 >
          MAX_REQUEST_JSON_BYTES {
          Err(
            service_error(
              @diagnostics.ResourceExhausted,
              "service_bridge.request",
              "the host-service request envelope exceeds the JSON transport size limit",
            ),
          )
        } else {
          // Validation bounds recursion and payload size before this copy.
          let owned_input = input.clone()
          let request = ServiceRequest::{
            id,
            scope,
            operation,
            input: owned_input,
          }
          self.next_request += 1
          self.pending.push(request)
          self.outbound.push(request)
          Ok(id)
        }
      }
    }
  }
}

///|
/// Transfer accepted requests to a host adapter in acceptance order.
pub fn ServiceBridge::take_requests(
  self : ServiceBridge,
) -> Array[ServiceRequest] {
  let requests : Array[ServiceRequest] = []
  for request in self.outbound {
    requests.push(request)
  }
  self.outbound.clear()
  requests
}

///|
/// Complete one outstanding request. Unknown, duplicate, mismatched, or stale
/// replies are dropped and return false. A host callback can therefore arrive
/// safely after teardown without targeting a newly-created scope.
pub fn ServiceBridge::complete(
  self : ServiceBridge,
  id : RequestId,
  scope : ScopeId,
  result : Result[@capability.Value, @diagnostics.FrameworkError],
) -> Bool {
  if self.closed || !self.contains_scope(scope) {
    return false
  }
  let mut pending_index = -1
  for index, request in self.pending {
    if request.id.value == id.value && request.scope.value == scope.value {
      pending_index = index
    }
  }
  if pending_index < 0 {
    false
  } else {
    let completion_result = match result {
      Err(error) => Err(error)
      Ok(value) =>
        match value.try_canonical_json() {
          Err(_) => return false
          Ok(value_json) => {
            let prefix = "{\"version\":1,\"requestId\":\"\{id.value}\",\"scopeId\":\"\{scope.value}\",\"ok\":true,\"value\":"
            if utf8_byte_length(prefix) + utf8_byte_length(value_json) + 1 >
              MAX_REQUEST_JSON_BYTES {
              return false
            }
            Ok(value.clone())
          }
        }
    }
    self.completions.push({ id, scope, result: completion_result, })
    remove_request(self.pending, pending_index)
    true
  }
}

///|
pub fn ServiceBridge::drain_completions(
  self : ServiceBridge,
) -> Array[ServiceCompletion] {
  let values : Array[ServiceCompletion] = []
  for completion in self.completions {
    values.push(completion)
  }
  self.completions.clear()
  values
}

///|
/// Destroying a logical owner drops queued work and already-arrived results.
/// In-flight adapter work may finish, but its completion will be rejected.
pub fn ServiceBridge::destroy_scope(
  self : ServiceBridge,
  scope : ScopeId,
) -> Bool {
  let mut found = false
  let mut index = 0
  while index < self.live_scopes.length() {
    if self.live_scopes[index].value == scope.value {
      remove_scope(self.live_scopes, index)
      found = true
      break
    }
    index += 1
  }
  if found {
    remove_scope_requests(self.pending, scope)
    remove_scope_requests(self.outbound, scope)
    remove_scope_completions(self.completions, scope)
  }
  found
}

///|
pub fn ServiceBridge::close(self : ServiceBridge) -> Unit {
  self.closed = true
  self.live_scopes.clear()
  self.pending.clear()
  self.outbound.clear()
  self.completions.clear()
}

///|
pub fn ServiceBridge::is_closed(self : ServiceBridge) -> Bool {
  self.closed
}

///|
pub fn ServiceBridge::pending_count(self : ServiceBridge) -> Int {
  self.pending.length()
}

///|
pub fn ServiceBridge::completion_count(self : ServiceBridge) -> Int {
  self.completions.length()
}

///|
pub fn ServiceBridge::capability_state(
  self : ServiceBridge,
  service : Service,
) -> CapabilityState {
  for capability in self.capabilities {
    if capability.service == service {
      return capability.state
    }
  }
  Unavailable
}

///|
fn ServiceBridge::contains_scope(self : ServiceBridge, scope : ScopeId) -> Bool {
  for current in self.live_scopes {
    if current.value == scope.value {
      return true
    }
  }
  false
}

///|
fn ServiceBridge::service_enabled(
  self : ServiceBridge,
  service : Service,
) -> Bool {
  match self.capability_state(service) {
    Unavailable => false
    Available | RequiresUserGesture | PermissionRequired => true
  }
}

///|
fn Service::label(self : Service) -> String {
  match self {
    Clipboard => "clipboard"
    FileDialog => "file_dialog"
    FileSystem => "file_system"
    Notifications => "notifications"
    Shell => "shell"
    PersistentStorage => "persistent_storage"
    WindowControls => "window_controls"
    Menus => "menus"
    ApplicationMetadata => "application_metadata"
    ProcessEnvironment => "process_environment"
    Updates => "updates"
    Lifecycle => "lifecycle"
  }
}

///|
fn clone_value(value : @capability.Value) -> @capability.Value {
  match value {
    @capability.UnitValue => @capability.UnitValue
    @capability.BoolValue(boolean) => @capability.BoolValue(boolean)
    @capability.IntValue(integer) => @capability.IntValue(integer)
    @capability.NumberValue(number) => @capability.NumberValue(number)
    @capability.StringValue(string) => @capability.StringValue(string)
    @capability.ArrayValue(values) => {
      let copied : Array[@capability.Value] = []
      for item in values {
        copied.push(clone_value(item))
      }
      @capability.ArrayValue(copied)
    }
    @capability.ObjectValue(fields) => {
      let copied : Array[(String, @capability.Value)] = []
      for field in fields {
        let (name, item) = field
        copied.push((name, clone_value(item)))
      }
      @capability.ObjectValue(copied)
    }
  }
}

///|
fn utf8_byte_length(text : String) -> Int {
  let mut bytes = 0
  for character in text {
    let codepoint = character.to_int()
    if codepoint < 0x80 {
      bytes += 1
    } else if codepoint < 0x800 {
      bytes += 2
    } else if codepoint <= 0xffff {
      bytes += 3
    } else {
      bytes += 4
    }
  }
  bytes
}

///|
fn remove_request(requests : Array[ServiceRequest], index : Int) -> Unit {
  let mut cursor = index
  while cursor + 1 < requests.length() {
    requests[cursor] = requests[cursor + 1]
    cursor += 1
  }
  ignore(requests.pop())
}

///|
fn remove_scope(scopes : Array[ScopeId], index : Int) -> Unit {
  let mut cursor = index
  while cursor + 1 < scopes.length() {
    scopes[cursor] = scopes[cursor + 1]
    cursor += 1
  }
  ignore(scopes.pop())
}

///|
fn remove_scope_requests(
  requests : Array[ServiceRequest],
  scope : ScopeId,
) -> Unit {
  let mut index = 0
  while index < requests.length() {
    if requests[index].scope.value == scope.value {
      remove_request(requests, index)
    } else {
      index += 1
    }
  }
}

///|
fn remove_scope_completions(
  values : Array[ServiceCompletion],
  scope : ScopeId,
) -> Unit {
  let mut index = 0
  while index < values.length() {
    if values[index].scope.value == scope.value {
      let mut cursor = index
      while cursor + 1 < values.length() {
        values[cursor] = values[cursor + 1]
        cursor += 1
      }
      ignore(values.pop())
    } else {
      index += 1
    }
  }
}

///|
fn service_error(
  code : @diagnostics.ErrorCode,
  operation : String,
  message : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    code,
    operation,
    subsystem="host-services",
    message~,
  )
}
