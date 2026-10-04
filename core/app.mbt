///|
/// App owns entity lifetimes, event delivery, a deterministic foreground
/// scheduler, and the error sink used by its callbacks.
pub struct App {
  priv inner : Ref[AppInner]
}

///|
priv struct AppInner {
  id : AppId
  mut lifecycle : AppLifecycle
  lifetime : AppLifetime
  mut next_entity_id : UInt64
  mut next_task_id : UInt64
  mut next_sequence : UInt64
  mut clock_ms : UInt64
  mut phase : CallbackPhase
  mut draining : Bool
  mut current_task : Task?
  entities : Array[EntityControl]
  timers : Array[ScheduledTask]
  work_queue : Array[WorkItem]
  diagnostics : @diagnostics.DiagnosticSink
}

///|
priv struct EntityControl {
  id : EntityId
  release : () -> Unit
}

///|
priv enum CallbackPhase {
  Idle
  Reading
  Updating
  Dispatching
}

///|
priv enum WorkItem {
  Notification(() -> Unit)
  DeferredUpdate(() -> Unit)
  StopEntities
  Task(ScheduledTask)
}

///|
/// Create an app in `New` state. Call `start` before creating entities or
/// scheduling work.
pub fn App::new() -> Result[App, @diagnostics.FrameworkError] {
  match allocate_app_id() {
    Err(error) => Err(error)
    Ok(id) =>
      match @diagnostics.DiagnosticSink::new(64) {
        Err(_) =>
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.ResourceExhausted,
              "App::new",
              app_id=id.value(),
              subsystem="core",
              message="failed to create the app diagnostic sink",
            ),
          )
        Ok(diagnostics) =>
          Ok({
            inner: Ref({
              id,
              lifecycle: New,
              lifetime: { app_id: id, alive: Ref(true), running: Ref(false), },
              next_entity_id: 1,
              next_task_id: 1,
              next_sequence: 1,
              clock_ms: 0,
              phase: Idle,
              draining: false,
              current_task: None,
              entities: [],
              timers: [],
              work_queue: [],
              diagnostics,
            }),
          })
      }
  }
}

///|
/// Return this app's process-local identity.
pub fn App::id(self : App) -> AppId {
  self.inner.val.id
}

///|
/// Return the current app lifecycle state.
pub fn App::lifecycle(self : App) -> AppLifecycle {
  self.inner.val.lifecycle
}

///|
/// Enter the running state exactly once.
pub fn App::start(self : App) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.inner.val.lifecycle {
    New => {
      self.inner.val.lifecycle = Running
      self.inner.val.lifetime.running.val = true
      Ok(())
    }
    _ =>
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "App::start",
          app_id=self.id().value(),
          subsystem="core",
          message="an app can be started only once",
        ),
      )
  }
}

///|
/// Begin orderly shutdown. New work is rejected immediately; entity release
/// callbacks are delivered by `run_ready`, after the current callback if any.
pub fn App::request_stop(
  self : App,
) -> Result[Unit, @diagnostics.FrameworkError] {
  // Revoke owner handles before any cancellation or release can reenter.
  self.inner.val.lifetime.alive.val = false
  self.inner.val.lifetime.running.val = false
  match self.inner.val.lifecycle {
    New => {
      self.inner.val.lifecycle = Stopped
      Ok(())
    }
    Running => {
      self.inner.val.lifecycle = Stopping
      self.cancel_all_tasks()
      if self.inner.val.phase is Idle {
        self.release_all_entities()
      } else {
        self.inner.val.work_queue.push(StopEntities)
      }
      self.finish_stop_if_drained()
      Ok(())
    }
    Stopping | Stopped => Ok(())
    Failed => {
      self.inner.val.lifecycle = Stopped
      self.inner.val.entities.clear()
      self.inner.val.timers.clear()
      Ok(())
    }
  }
}

///|
/// Return a snapshot of the app's bounded, chronological error diagnostics.
pub fn App::diagnostics(self : App) -> Array[@diagnostics.Diagnostic] {
  self.inner.val.diagnostics.snapshot()
}

///|
fn App::check_running(
  self : App,
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if self.inner.val.lifecycle is Running {
    Ok(())
  } else {
    let state = self.inner.val.lifecycle.label()
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.AppNotRunning,
        operation,
        app_id=self.id().value(),
        subsystem="core",
        message="app lifecycle is \{state}",
      ),
    )
  }
}

///|
fn AppLifecycle::label(self : AppLifecycle) -> String {
  match self {
    New => "new"
    Running => "running"
    Stopping => "stopping"
    Stopped => "stopped"
    Failed => "failed"
  }
}

///|
fn App::record_error(self : App, error : @diagnostics.FrameworkError) -> Unit {
  self.inner.val.diagnostics.record(error)
}

///|
fn callback_error_context(error : @diagnostics.FrameworkError) -> String {
  let code = error.code().label()
  let operation = error.operation()
  let detail = match error.message() {
    Some(message) => message
    None => "no message supplied"
  }
  "callback returned \{code} from \{operation}: \{detail}"
}

///|
fn App::enqueue_notification(self : App, callback : () -> Unit) -> Unit {
  self.inner.val.work_queue.push(WorkItem::Notification(callback))
}

///|
fn App::enqueue_update(self : App, callback : () -> Unit) -> Unit {
  self.inner.val.work_queue.push(WorkItem::DeferredUpdate(callback))
}

///|
fn App::release_all_entities(self : App) -> Unit {
  for control in self.inner.val.entities {
    (control.release)()
  }
}

///|
fn App::finish_stop_if_drained(self : App) -> Unit {
  if self.inner.val.lifecycle is Stopping &&
    self.inner.val.work_queue.is_empty() {
    self.inner.val.lifecycle = Stopped
    self.inner.val.entities.clear()
    self.inner.val.timers.clear()
  }
}

///|
/// Read-only lifetime of an app. It does not retain the app, its entities, or
/// callbacks. It is valid during New/Running and permanently revoked as soon
/// as request_stop begins, even when entity release is deferred.
pub struct AppLifetime {
  priv app_id : AppId
  priv alive : Ref[Bool]
  priv running : Ref[Bool]
}

///|
pub fn App::lifetime(self : App) -> AppLifetime {
  self.inner.val.lifetime
}

///|
pub fn AppLifetime::app_id(self : AppLifetime) -> AppId {
  self.app_id
}

///|
pub fn AppLifetime::is_alive(self : AppLifetime) -> Bool {
  self.alive.val
}

///|
/// Readiness is separate from lifetime: a New app may configure owned handles
/// but cannot execute them until start succeeds.
pub fn AppLifetime::is_running(self : AppLifetime) -> Bool {
  self.running.val
}
