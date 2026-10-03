///|
/// Identity of one `App` instance. The payload is process-local and is not a
/// native handle.
pub struct AppId {
  priv value : UInt64
} derive(Eq)

///|
pub extend AppId with Eq::{not_equal, equal}

///|
/// Return the stable process-local numeric value used in diagnostics.
pub fn AppId::value(self : AppId) -> UInt64 {
  self.value
}

///|
/// Identity of an entity, unique within its owning app.
pub struct EntityId {
  priv app_id : AppId
  priv value : UInt64
} derive(Eq)

///|
pub extend EntityId with Eq::{not_equal, equal}

///|
/// Return the owning app identity.
pub fn EntityId::app_id(self : EntityId) -> AppId {
  self.app_id
}

///|
/// Return the monotonically allocated entity number within its app.
pub fn EntityId::value(self : EntityId) -> UInt64 {
  self.value
}

///|
/// Identity of a scheduled task, unique within its owning app.
pub struct TaskId {
  priv app_id : AppId
  priv value : UInt64
} derive(Eq)

///|
pub extend TaskId with Eq::{not_equal, equal}

///|
/// Return the owning app identity.
pub fn TaskId::app_id(self : TaskId) -> AppId {
  self.app_id
}

///|
/// Return the monotonically allocated task number within its app.
pub fn TaskId::value(self : TaskId) -> UInt64 {
  self.value
}

///|
/// App lifecycle states visible to applications and deterministic tests.
pub(all) enum AppLifecycle {
  New
  Running
  Stopping
  Stopped
  Failed
}

///|
/// State of a scheduled foreground or timer task.
pub(all) enum TaskStatus {
  Queued
  Running
  Completed
  Cancelled
  Failed
}

///|
let app_id_sequence : Ref[UInt64] = Ref(1)

///|
fn allocate_app_id() -> Result[AppId, @diagnostics.FrameworkError] {
  let current = app_id_sequence.val
  let max_uint64 : UInt64 = 0xffff_ffff_ffff_ffff
  if current == max_uint64 {
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.ResourceExhausted,
        "App::new",
        message="app identity space exhausted",
        subsystem="core",
      ),
    )
  } else {
    app_id_sequence.val = current + 1
    Ok({ value: current, })
  }
}
