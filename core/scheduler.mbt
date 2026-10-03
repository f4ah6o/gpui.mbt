///|
/// Callback type for app-executor tasks. Task contexts are valid only for the
/// callback's dynamic extent.
pub type TaskCallback = (TaskContext) -> Result[
  Unit,
  @diagnostics.FrameworkError,
]

///|
priv struct ScheduledTask {
  task : Task
  deadline_ms : UInt64
  sequence : UInt64
}

///|
priv struct TaskCell {
  id : TaskId
  mut status : TaskStatus
  cancel_requested : Ref[Bool]
  active : Ref[Bool]
  mut callback : TaskCallback?
  mut failure : @diagnostics.FrameworkError?
}

///|
/// An app-owned scheduled callback.
pub struct Task {
  priv cell : Ref[TaskCell]
}

///|
/// Cancellation view passed to one running task callback.
pub struct TaskContext {
  priv id : TaskId
  priv active : Ref[Bool]
  priv cancel_requested : Ref[Bool]
}

///|
/// Return the task's stable identity.
pub fn Task::id(self : Task) -> TaskId {
  self.cell.val.id
}

///|
/// Return the current task state.
pub fn Task::status(self : Task) -> TaskStatus {
  self.cell.val.status
}

///|
/// Return the failure recorded for a failed task.
pub fn Task::failure(self : Task) -> @diagnostics.FrameworkError? {
  self.cell.val.failure
}

///|
/// Cancel queued work or request cooperative cancellation of running work.
/// Returns false after the task has already reached a terminal state.
pub fn Task::cancel(self : Task) -> Bool {
  match self.cell.val.status {
    Queued => {
      self.cell.val.status = Cancelled
      self.cell.val.callback = None
      true
    }
    Running => {
      self.cell.val.cancel_requested.val = true
      true
    }
    Completed | Cancelled | Failed => false
  }
}

///|
/// Check the cooperative cancellation token while the task callback is live.
pub fn TaskContext::is_cancel_requested(
  self : TaskContext,
) -> Result[Bool, @diagnostics.FrameworkError] {
  if self.active.val {
    Ok(self.cancel_requested.val)
  } else {
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.ContextExpired,
        "TaskContext::is_cancel_requested",
        task_id=self.id.value(),
        subsystem="core",
        message="task context is outside its callback",
      ),
    )
  }
}

///|
/// Queue a foreground callback for the next ready-work drain. It joins the
/// FIFO immediately, ahead of notifications produced by later operations.
pub fn App::dispatch(
  self : App,
  callback : TaskCallback,
) -> Result[Task, @diagnostics.FrameworkError] {
  self.schedule_after(0, callback)
}

///|
/// Schedule a foreground callback after a monotonic delay in milliseconds.
/// Equal deadlines run in registration order. Zero-delay tasks enter the FIFO
/// at submission time.
pub fn App::schedule_after(
  self : App,
  delay_ms : UInt64,
  callback : TaskCallback,
) -> Result[Task, @diagnostics.FrameworkError] {
  match self.check_running("App::schedule_after") {
    Err(error) => Err(error)
    Ok(_) => {
      self.prune_cancelled_tasks()
      let max_uint64 : UInt64 = 0xffff_ffff_ffff_ffff
      let id_value = self.inner.val.next_task_id
      let sequence = self.inner.val.next_sequence
      if id_value == max_uint64 ||
        sequence == max_uint64 ||
        delay_ms > max_uint64 - self.inner.val.clock_ms {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.ResourceExhausted,
            "App::schedule_after",
            app_id=self.id().value(),
            subsystem="core",
            message="task identity, ordering sequence, or deadline space exhausted",
          ),
        )
      } else {
        self.inner.val.next_task_id = id_value + 1
        self.inner.val.next_sequence = sequence + 1
        let task_id = TaskId::{ app_id: self.id(), value: id_value, }
        let task = Task::{
          cell: Ref({
            id: task_id,
            status: Queued,
            cancel_requested: Ref(false),
            active: Ref(false),
            callback: Some(callback),
            failure: None,
          }),
        }
        let scheduled = {
          task,
          deadline_ms: self.inner.val.clock_ms + delay_ms,
          sequence,
        }
        if delay_ms == 0 {
          self.inner.val.work_queue.push(WorkItem::Task(scheduled))
        } else {
          self.inner.val.timers.push(scheduled)
        }
        Ok(task)
      }
    }
  }
}

///|
/// Advance the deterministic monotonic clock. Native backends feed elapsed
/// time through this boundary; M1 does not read wall-clock time itself.
pub fn App::advance_time_by(
  self : App,
  delta_ms : UInt64,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check_running("App::advance_time_by") {
    Err(error) => Err(error)
    Ok(_) =>
      if !(self.inner.val.phase is Idle) || self.inner.val.draining {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.ReentrantUpdate,
            "App::advance_time_by",
            app_id=self.id().value(),
            subsystem="core",
            message="the test clock can advance only between callbacks",
          ),
        )
      } else {
        let max_uint64 : UInt64 = 0xffff_ffff_ffff_ffff
        if delta_ms > max_uint64 - self.inner.val.clock_ms {
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "App::advance_time_by",
              app_id=self.id().value(),
              subsystem="core",
              message="clock advance would overflow the monotonic time range",
            ),
          )
        } else {
          self.inner.val.clock_ms += delta_ms
          self.promote_due_tasks()
          Ok(())
        }
      }
  }
}

///|
/// Return the scheduler's monotonic time in milliseconds.
pub fn App::now_ms(self : App) -> UInt64 {
  self.inner.val.clock_ms
}

///|
/// Process at most `budget` ready notifications, deferred updates, and tasks.
/// Work is FIFO. Due timers are promoted by deadline, then registration order.
pub fn App::run_ready(
  self : App,
  budget : Int,
) -> Result[Int, @diagnostics.FrameworkError] {
  let lifecycle = self.inner.val.lifecycle
  if !(lifecycle is Running) && !(lifecycle is Stopping) {
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.AppNotRunning,
        "App::run_ready",
        app_id=self.id().value(),
        subsystem="core",
        message="app lifecycle is \{lifecycle.label()}",
      ),
    )
  } else if self.inner.val.draining || !(self.inner.val.phase is Idle) {
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.ReentrantUpdate,
        "App::run_ready",
        app_id=self.id().value(),
        subsystem="core",
        message="ready work cannot be drained from inside a callback",
      ),
    )
  } else if budget < 0 {
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.InvalidInput,
        "App::run_ready",
        app_id=self.id().value(),
        subsystem="core",
        message="budget must be non-negative",
      ),
    )
  } else {
    self.inner.val.draining = true
    self.prune_cancelled_tasks()
    self.promote_due_tasks()
    let mut processed = 0
    while processed < budget && !self.inner.val.work_queue.is_empty() {
      let item = self.inner.val.work_queue.remove(0)
      match item {
        Notification(callback) => self.run_dispatched(callback)
        DeferredUpdate(callback) => self.run_dispatched(callback)
        StopEntities => {
          let previous_phase = self.inner.val.phase
          self.inner.val.phase = Dispatching
          self.release_all_entities()
          self.inner.val.phase = previous_phase
        }
        Task(scheduled) => self.run_task(scheduled)
      }
      processed += 1
      self.promote_due_tasks()
      self.prune_cancelled_tasks()
    }
    self.inner.val.draining = false
    self.finish_stop_if_drained()
    Ok(processed)
  }
}

///|
/// Return the number of active ready and timed callbacks.
pub fn App::pending_work(self : App) -> Int {
  let mut count = 0
  for item in self.inner.val.work_queue {
    match item {
      Task(scheduled) if scheduled.task.cell.val.status is Queued => count += 1
      Notification(_) | DeferredUpdate(_) | StopEntities => count += 1
      Task(_) => ()
    }
  }
  for scheduled in self.inner.val.timers {
    if scheduled.task.cell.val.status is Queued {
      count += 1
    }
  }
  count
}

///|
fn App::run_dispatched(self : App, callback : () -> Unit) -> Unit {
  let previous_phase = self.inner.val.phase
  self.inner.val.phase = Dispatching
  callback()
  self.inner.val.phase = previous_phase
}

///|
fn App::promote_due_tasks(self : App) -> Unit {
  let initial_length = self.inner.val.timers.length()
  for _ in 0..<initial_length {
    match self.find_earliest_due_task() {
      None => ()
      Some(index) => {
        let scheduled = self.inner.val.timers.remove(index)
        if scheduled.task.cell.val.status is Queued {
          self.inner.val.work_queue.push(WorkItem::Task(scheduled))
        }
      }
    }
  }
}

///|
fn App::find_earliest_due_task(self : App) -> Int? {
  let mut earliest : Int? = None
  for index in 0..<self.inner.val.timers.length() {
    let candidate = self.inner.val.timers[index]
    if candidate.task.cell.val.status is Queued &&
      candidate.deadline_ms <= self.inner.val.clock_ms {
      match earliest {
        None => earliest = Some(index)
        Some(previous_index) => {
          let previous = self.inner.val.timers[previous_index]
          if candidate.deadline_ms < previous.deadline_ms ||
            (
              candidate.deadline_ms == previous.deadline_ms &&
              candidate.sequence < previous.sequence
            ) {
            earliest = Some(index)
          }
        }
      }
    }
  }
  earliest
}

///|
fn App::prune_cancelled_tasks(self : App) -> Unit {
  self.inner.val.timers.retain(scheduled => {
    scheduled.task.cell.val.status is Queued
  })
  self.inner.val.work_queue.retain(item => {
    match item {
      Task(scheduled) => scheduled.task.cell.val.status is Queued
      Notification(_) | DeferredUpdate(_) | StopEntities => true
    }
  })
}

///|
fn App::run_task(self : App, scheduled : ScheduledTask) -> Unit {
  let task = scheduled.task
  if task.cell.val.status is Queued && self.inner.val.lifecycle is Running {
    task.cell.val.status = Running
    task.cell.val.active.val = true
    self.inner.val.current_task = Some(task)
    let context = TaskContext::{
      id: task.cell.val.id,
      active: task.cell.val.active,
      cancel_requested: task.cell.val.cancel_requested,
    }
    let previous_phase = self.inner.val.phase
    self.inner.val.phase = Dispatching
    let result = match task.cell.val.callback {
      None => Ok(())
      Some(callback) => callback(context)
    }
    self.inner.val.phase = previous_phase
    task.cell.val.active.val = false
    task.cell.val.callback = None
    self.inner.val.current_task = None
    if task.cell.val.cancel_requested.val ||
      !(self.inner.val.lifecycle is Running) {
      task.cell.val.status = Cancelled
    } else {
      match result {
        Ok(_) => task.cell.val.status = Completed
        Err(error) => {
          let failure = @diagnostics.FrameworkError::new(
            @diagnostics.TaskFailure,
            "Task::run",
            app_id=self.id().value(),
            task_id=task.cell.val.id.value(),
            subsystem="core",
            message=callback_error_context(error),
          )
          task.cell.val.failure = Some(failure)
          task.cell.val.status = Failed
          self.record_error(failure)
        }
      }
    }
  }
}

///|
fn App::cancel_all_tasks(self : App) -> Unit {
  match self.inner.val.current_task {
    Some(task) => ignore(task.cancel())
    None => ()
  }
  for scheduled in self.inner.val.timers {
    ignore(scheduled.task.cancel())
  }
  self.inner.val.timers.clear()
  self.inner.val.work_queue.retain(item => {
    match item {
      Notification(_) | StopEntities => true
      DeferredUpdate(_) => false
      Task(scheduled) => {
        ignore(scheduled.task.cancel())
        false
      }
    }
  })
}
