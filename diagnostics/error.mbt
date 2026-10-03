///|
/// Stable framework error categories. These are values rather than checked
/// exceptions so callers can return and retain errors without unwinding.
pub(all) enum ErrorCode {
  AppNotRunning
  WrongApp
  EntityNotLive
  ContextExpired
  InvalidInput
  ReentrantUpdate
  CallbackFailure
  TaskFailure
  UnsupportedCapability
  StaleHandle
  PermissionDenied
  Busy
  ResourceExhausted
  WindowUnavailable
  SurfaceLost
  DeviceLost
  ConversionFailed
  WrongThread
  HostStopping
  NativeFailure
}

///|
/// Stable lowercase label for logs and machine-readable diagnostics.
pub fn ErrorCode::label(self : ErrorCode) -> String {
  match self {
    AppNotRunning => "app_not_running"
    WrongApp => "wrong_app"
    EntityNotLive => "entity_not_live"
    ContextExpired => "context_expired"
    InvalidInput => "invalid_input"
    ReentrantUpdate => "reentrant_update"
    CallbackFailure => "callback_failure"
    TaskFailure => "task_failure"
    UnsupportedCapability => "unsupported_capability"
    StaleHandle => "stale_handle"
    PermissionDenied => "permission_denied"
    Busy => "busy"
    ResourceExhausted => "resource_exhausted"
    WindowUnavailable => "window_unavailable"
    SurfaceLost => "surface_lost"
    DeviceLost => "device_lost"
    ConversionFailed => "conversion_failed"
    WrongThread => "wrong_thread"
    HostStopping => "host_stopping"
    NativeFailure => "native_failure"
  }
}

///|
/// Structured framework error with optional logical object identities.
/// IDs are app/entity/window IDs, never pointers or native handles.
pub struct FrameworkError {
  priv code : ErrorCode
  priv operation : String
  priv app_id : UInt64?
  priv entity_id : UInt64?
  priv window_id : UInt64?
  priv task_id : UInt64?
  priv subsystem : String?
  priv backend : String?
  priv message : String?
}

///|
/// Construct an error. Operation text is capped at 96 Unicode scalars;
/// subsystem/backend labels at 48; message text at 256. Truncation ends with
/// an ellipsis.
pub fn FrameworkError::new(
  code : ErrorCode,
  operation : String,
  app_id? : UInt64,
  entity_id? : UInt64,
  window_id? : UInt64,
  task_id? : UInt64,
  subsystem? : String,
  backend? : String,
  message? : String,
) -> FrameworkError {
  {
    code,
    operation: truncate_text(operation, 96),
    app_id,
    entity_id,
    window_id,
    task_id,
    subsystem: subsystem.map(text => truncate_text(text, 48)),
    backend: backend.map(text => truncate_text(text, 48)),
    message: message.map(text => truncate_text(text, 256)),
  }
}

///|
pub fn FrameworkError::code(self : FrameworkError) -> ErrorCode {
  self.code
}

///|
pub fn FrameworkError::operation(self : FrameworkError) -> String {
  self.operation
}

///|
pub fn FrameworkError::app_id(self : FrameworkError) -> UInt64? {
  self.app_id
}

///|
pub fn FrameworkError::entity_id(self : FrameworkError) -> UInt64? {
  self.entity_id
}

///|
pub fn FrameworkError::window_id(self : FrameworkError) -> UInt64? {
  self.window_id
}

///|
pub fn FrameworkError::task_id(self : FrameworkError) -> UInt64? {
  self.task_id
}

///|
pub fn FrameworkError::subsystem(self : FrameworkError) -> String? {
  self.subsystem
}

///|
pub fn FrameworkError::backend(self : FrameworkError) -> String? {
  self.backend
}

///|
pub fn FrameworkError::message(self : FrameworkError) -> String? {
  self.message
}

///|
fn truncate_text(text : String, limit : Int) -> String {
  let builder = StringBuilder()
  let mut previous : Char? = None
  let mut seen = 0
  let mut truncated = false
  for character in text {
    if seen < limit {
      if previous is Some(last) {
        builder.write_char(last)
      }
      previous = Some(character)
      seen += 1
    } else {
      truncated = true
      break
    }
  }
  if truncated {
    builder.write_char('…')
  } else if previous is Some(last) {
    builder.write_char(last)
  }
  builder.to_string()
}
