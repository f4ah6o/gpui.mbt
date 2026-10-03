///|
fn start_app() -> @core.App raise {
  let app = match @core.App::new() {
    Ok(value) => value
    Err(_) => fail("app allocation should succeed in the headless model")
  }
  match app.start() {
    Ok(_) => app
    Err(_) => fail("new app should enter running state")
  }
}

///|
fn new_int_entity(app : @core.App, value : Int) -> @core.Entity[Int] raise {
  match app.create_entity(value) {
    Ok(entity) => entity
    Err(_) => fail("running app should allocate an entity")
  }
}

///|
fn drain(app : @core.App) -> Bool {
  match app.run_ready(64) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn[T] has_error_code(
  result : Result[T, @diagnostics.FrameworkError],
  expected : @diagnostics.ErrorCode,
) -> Bool {
  match result {
    Err(error) => error.code().label() == expected.label()
    Ok(_) => false
  }
}

///|
fn has_id(ids : Array[UInt64], candidate : UInt64) -> Bool {
  for id in ids {
    if id == candidate {
      return true
    }
  }
  false
}

///|
fn subscription_matches(
  subscription : @core.Subscription?,
  expected_active : Bool,
) -> Bool {
  match subscription {
    Some(value) => value.is_active() == expected_active
    None => !expected_active
  }
}

///|
fn model_agrees_with_sequences(commands : Array[Int]) -> Bool {
  let app = match @core.App::new() {
    Ok(value) => value
    Err(_) => return false
  }
  if app.start() is Err(_) {
    return false
  }
  let mut source = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => return false
  }
  let mut owner = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => return false
  }
  let mut source_live = true
  let mut owner_live = true
  let mut source_value = 0
  let mut owner_value = 0
  let mut source_revision : UInt64 = 0
  let mut owner_revision : UInt64 = 0
  let mut subscriber_active = false
  let mut observer_active = false
  let mut subscriber : @core.Subscription? = None
  let mut observer : @core.Subscription? = None
  let mut observed_updates = 0
  let mut expected_observed_updates = 0
  let event_history : Array[(UInt64, Int, UInt64)] = []
  let expected_history : Array[(UInt64, Int, UInt64)] = []
  let entity_ids : Array[UInt64] = [source.id().value(), owner.id().value()]
  for command in commands {
    let reduced = command % 10
    let operation = if reduced < 0 { reduced + 10 } else { reduced }
    match operation {
      // Change the source and coalesce duplicate notify calls into one event.
      0 =>
        if source_live {
          let next = source_value + command % 17
          if app.update(source, context => {
              ignore(context.set(next))
              ignore(context.notify())
              ignore(context.notify())
              Ok(())
            })
            is Err(_) {
            return false
          }
          source_value = next
          source_revision += 1
          if subscriber_active {
            expected_history.push((source.id().value(), 0, source_revision))
          }
          if observer_active && owner_live {
            expected_observed_updates += 1
            owner_value += 1
            owner_revision += 1
          }
        }
      // Change source state without requesting a notification.
      1 =>
        if source_live {
          let next = source_value + 1
          if app.update(source, context => {
              ignore(context.set(next))
              Ok(())
            })
            is Err(_) {
            return false
          }
          source_value = next
          source_revision += 1
        }
      // Toggle the event subscription.
      2 =>
        if owner_live && source_live {
          if subscriber_active {
            match subscriber {
              Some(value) => value.unsubscribe()
              None => return false
            }
            subscriber_active = false
          } else {
            let result = app.update(owner, context => {
              match
                context.subscribe(source, event => {
                  let kind = if event.kind() is @core.EntityEventKind::Changed {
                    0
                  } else {
                    1
                  }
                  event_history.push(
                    (event.entity_id().value(), kind, event.revision()),
                  )
                  Ok(())
                }) {
                Err(error) => Err(error)
                Ok(created) => {
                  subscriber = Some(created)
                  Ok(())
                }
              }
            })
            if result is Err(_) {
              return false
            }
            subscriber_active = true
            owner_revision += 1
          }
        }
      // Toggle change observation. Its callback increments owner state.
      3 =>
        if owner_live && source_live {
          if observer_active {
            match observer {
              Some(value) => value.unsubscribe()
              None => return false
            }
            observer_active = false
          } else {
            let result = app.update(owner, context => {
              match
                context.observe(source, observer_context => {
                  observed_updates += 1
                  match observer_context.get() {
                    Err(error) => Err(error)
                    Ok(current) =>
                      match observer_context.set(current + 1) {
                        Err(error) => Err(error)
                        Ok(_) => observer_context.notify()
                      }
                  }
                }) {
                Err(error) => Err(error)
                Ok(created) => {
                  observer = Some(created)
                  Ok(())
                }
              }
            })
            if result is Err(_) {
              return false
            }
            observer_active = true
            owner_revision += 1
          }
        }
      // Release sends one terminal event to subscribers and deactivates both
      // registrations once release callbacks finish. Observe is change-only.
      4 =>
        if source_live {
          if app.destroy_entity(source) is Err(_) {
            return false
          }
          if subscriber_active {
            expected_history.push((source.id().value(), 1, source_revision))
          }
          source_live = false
          subscriber_active = false
          observer_active = false
        }
      // Recreate a released source with a never-reused logical identity.
      5 =>
        if !source_live {
          let previous_ids = entity_ids.copy()
          match app.create_entity(0) {
            Err(_) => return false
            Ok(created) => {
              if has_id(previous_ids, created.id().value()) {
                return false
              }
              entity_ids.push(created.id().value())
              source = created
              source_live = true
              source_value = 0
              source_revision = 0
              subscriber = None
              observer = None
            }
          }
        }
      // Destroying an observer owner deactivates its registrations.
      6 =>
        if owner_live {
          if app.destroy_entity(owner) is Err(_) {
            return false
          }
          owner_live = false
          subscriber_active = false
          observer_active = false
        }
      // A newly created owner does not inherit any previous subscriptions.
      7 =>
        if !owner_live {
          let previous_ids = entity_ids.copy()
          match app.create_entity(0) {
            Err(_) => return false
            Ok(created) => {
              if has_id(previous_ids, created.id().value()) {
                return false
              }
              entity_ids.push(created.id().value())
              owner = created
              owner_live = true
              owner_value = 0
              owner_revision = 0
              subscriber = None
              observer = None
            }
          }
        }
      // Probe the source, including stale handles after release.
      8 =>
        if source_live {
          match app.read(source, current => current) {
            Ok(current) if current == source_value => ()
            _ => return false
          }
        } else if !has_error_code(
            app.read(source, current => current),
            @diagnostics.ErrorCode::EntityNotLive,
          ) {
          return false
        }
      // Probe the observer owner, including stale handles after release.
      _ =>
        if owner_live {
          match app.read(owner, current => current) {
            Ok(current) if current == owner_value => ()
            _ => return false
          }
        } else if !has_error_code(
            app.read(owner, current => current),
            @diagnostics.ErrorCode::EntityNotLive,
          ) {
          return false
        }
    }
    if !drain(app) {
      return false
    }
    if event_history != expected_history ||
      observed_updates != expected_observed_updates ||
      !subscription_matches(subscriber, subscriber_active) ||
      !subscription_matches(observer, observer_active) {
      return false
    }
    if source_live {
      match (app.read(source, current => current), app.revision(source)) {
        (Ok(current), Ok(revision)) if current == source_value &&
          revision == source_revision => ()
        _ => return false
      }
    } else if source.is_live() {
      return false
    }
    if owner_live {
      match (app.read(owner, current => current), app.revision(owner)) {
        (Ok(current), Ok(revision)) if current == owner_value &&
          revision == owner_revision => ()
        _ => return false
      }
    } else if owner.is_live() {
      return false
    }
    if app.pending_work() != 0 {
      return false
    }
  }
  true
}

///|
// Stable suite ID: core-model
test "quickcheck: entity state and revisions agree with a lifecycle model" {
  @quickcheck.check(
    (commands : Array[Int]) => model_agrees_with_sequences(commands),
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=584118800423729943,
    counterexample_context=commands => {
      let builder = StringBuilder()
      builder.write_string("core-model-v1 commands=[")
      for index, command in commands {
        if index > 0 {
          builder.write_string(",")
        }
        builder.write_string(command.to_string())
      }
      builder.write_string("]")
      builder.to_string()
    },
  )
}

///|
test "contexts expire and read callbacks cannot reenter an update" {
  let app = start_app()
  let entity = new_int_entity(app, 3)
  let mut saved_context : @core.Context[Int]? = None
  let mut update_drain_error : @diagnostics.FrameworkError? = None
  assert_true(
    app.update(entity, context => {
      saved_context = Some(context)
      update_drain_error = match app.run_ready(1) {
        Err(error) => Some(error)
        Ok(_) => None
      }
      Ok(())
    })
    is Ok(_),
  )
  match update_drain_error {
    Some(error) =>
      assert_true(error.code() is @diagnostics.ErrorCode::ReentrantUpdate)
    None => fail("ready-work drain must be rejected during an update")
  }
  match saved_context {
    None => fail("update callback should have received a context")
    Some(context) => {
      match context.get() {
        Err(error) =>
          assert_true(error.code() is @diagnostics.ErrorCode::ContextExpired)
        Ok(_) => fail("context read must fail after the update returns")
      }
      match context.set(9) {
        Err(error) =>
          assert_true(error.code() is @diagnostics.ErrorCode::ContextExpired)
        Ok(_) => fail("context write must fail after the update returns")
      }
    }
  }

  match app.read(entity, _ => app.update(entity, _ => Ok(()))) {
    Ok(Err(error)) =>
      assert_true(error.code() is @diagnostics.ErrorCode::ReentrantUpdate)
    _ => fail("an update attempted from App::read must be rejected")
  }
  match app.read(entity, _ => app.run_ready(1)) {
    Ok(Err(error)) =>
      assert_true(error.code() is @diagnostics.ErrorCode::ReentrantUpdate)
    _ => fail("ready-work drain must be rejected during a read")
  }
}

///|
test "callback failures become diagnostics and do not stop later listeners" {
  let app = start_app()
  let source = new_int_entity(app, 1)
  let owner = new_int_entity(app, 0)
  let mut later_listener_calls = 0
  match
    app.update(owner, context => {
      ignore(context.set(9))
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.ErrorCode::InvalidInput,
          "test_update_failure",
          message="original update detail",
        ),
      )
    }) {
    Err(error) => {
      assert_true(error.code() is @diagnostics.ErrorCode::CallbackFailure)
      assert_true(
        error.message() ==
        Some(
          "callback returned invalid_input from test_update_failure: original update detail",
        ),
      )
    }
    Ok(_) => fail("update callback error must be returned as CallbackFailure")
  }
  assert_true(app.revision(owner) is Ok(1))
  assert_true(app.read(owner, value => value) is Ok(9))

  let subscribe_result = app.update(owner, context => {
    match
      context.subscribe(source, _ => {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.ErrorCode::InvalidInput,
            "test_listener_failure",
          ),
        )
      }) {
      Err(error) => Err(error)
      Ok(_) =>
        match
          context.subscribe(source, _ => {
            later_listener_calls += 1
            Ok(())
          }) {
          Err(error) => Err(error)
          Ok(_) => Ok(())
        }
    }
  })
  assert_true(subscribe_result is Ok(_))
  assert_true(
    app.update(source, context => {
      ignore(context.notify())
      Ok(())
    })
    is Ok(_),
  )
  assert_true(drain(app))
  assert_true(later_listener_calls == 1)
  let diagnostics = app.diagnostics()
  let mut saw_callback_failure = false
  for diagnostic in diagnostics {
    if diagnostic.error().code() is @diagnostics.ErrorCode::CallbackFailure {
      saw_callback_failure = true
    }
  }
  assert_true(saw_callback_failure)
}

///|
test "released source notifies before deactivating its subscriptions" {
  let app = start_app()
  let source = new_int_entity(app, 0)
  let owner = new_int_entity(app, 0)
  let mut seen_releases = 0
  let mut subscription : @core.Subscription? = None
  assert_true(
    app.update(owner, context => {
      match
        context.subscribe(source, event => {
          if event.kind() is @core.EntityEventKind::Released {
            seen_releases += 1
          }
          Ok(())
        }) {
        Err(error) => Err(error)
        Ok(created) => {
          subscription = Some(created)
          Ok(())
        }
      }
    })
    is Ok(_),
  )
  assert_true(app.destroy_entity(source) is Ok(_))
  match subscription {
    None => fail("subscription should have been created")
    Some(created) => assert_true(created.is_active())
  }
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(seen_releases == 1)
  match subscription {
    None => fail("subscription should still be retained for the check")
    Some(created) => assert_true(!created.is_active())
  }
  assert_true(drain(app))
  assert_true(seen_releases == 1)
  let mut original_source_error : @diagnostics.FrameworkError? = None
  match
    app.update(owner, context => {
      match context.subscribe(source, _ => Ok(())) {
        Err(error) => {
          original_source_error = Some(error)
          Err(error)
        }
        Ok(_) => Ok(())
      }
    }) {
    Err(error) => {
      assert_true(error.code() is @diagnostics.ErrorCode::CallbackFailure)
      assert_true(
        error.message() ==
        Some(
          "callback returned entity_not_live from Context::subscribe: entity has been released",
        ),
      )
    }
    Ok(_) => fail("released source must reject new listeners")
  }
  match original_source_error {
    Some(error) =>
      assert_true(error.code() is @diagnostics.ErrorCode::EntityNotLive)
    None => fail("the failed subscription must expose its source error")
  }
}

///|
test "unsubscribing or destroying an observer suppresses its queued update" {
  let app = start_app()
  let source = new_int_entity(app, 0)
  let observer = new_int_entity(app, 0)
  let mut observer_calls = 0
  let mut subscription : @core.Subscription? = None
  assert_true(
    app.update(observer, context => {
      match
        context.observe(source, observer_context => {
          observer_calls += 1
          observer_context.set(1)
        }) {
        Err(error) => Err(error)
        Ok(created) => {
          subscription = Some(created)
          Ok(())
        }
      }
    })
    is Ok(_),
  )
  assert_true(
    app.update(source, context => {
      ignore(context.notify())
      Ok(())
    })
    is Ok(_),
  )
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(observer_calls == 0)
  match subscription {
    None => fail("observer subscription should exist")
    Some(created) => created.unsubscribe()
  }
  assert_true(drain(app))
  assert_true(observer_calls == 0)

  let owner_to_destroy = new_int_entity(app, 0)
  assert_true(
    app.update(owner_to_destroy, context => {
      match
        context.observe(source, _ => {
          observer_calls += 1
          Ok(())
        }) {
        Err(error) => Err(error)
        Ok(_) => Ok(())
      }
    })
    is Ok(_),
  )
  assert_true(
    app.update(source, context => {
      ignore(context.notify())
      Ok(())
    })
    is Ok(_),
  )
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(app.destroy_entity(owner_to_destroy) is Ok(_))
  assert_true(drain(app))
  assert_true(observer_calls == 0)
}

///|
test "dispatch and notifications preserve one FIFO submission order" {
  let app = start_app()
  let source = new_int_entity(app, 0)
  let owner = new_int_entity(app, 0)
  let order : Array[String] = []
  assert_true(
    app.update(owner, context => {
      match
        context.subscribe(source, _ => {
          order.push("notification")
          Ok(())
        }) {
        Ok(_) => Ok(())
        Err(error) => Err(error)
      }
    })
    is Ok(_),
  )
  assert_true(
    app.dispatch(_ => {
      order.push("dispatch")
      Ok(())
    })
    is Ok(_),
  )
  assert_true(
    app.update(source, context => {
      ignore(context.notify())
      Ok(())
    })
    is Ok(_),
  )
  assert_true(drain(app))
  assert_true(order == ["dispatch", "notification"])
}

///|
test "updates requested by event callbacks are deferred and reads remain valid" {
  let app = start_app()
  let source = new_int_entity(app, 0)
  let owner = new_int_entity(app, 0)
  let target = new_int_entity(app, 4)
  let mut event_read : Int? = None
  let mut update_accepted = false
  assert_true(
    app.update(owner, context => {
      match
        context.subscribe(source, _ => {
          event_read = match app.read(source, value => value) {
            Ok(value) => Some(value)
            Err(_) => None
          }
          update_accepted = app.update(target, target_context => {
              target_context.set(8)
            })
            is Ok(_)
          Ok(())
        }) {
        Err(error) => Err(error)
        Ok(_) => Ok(())
      }
    })
    is Ok(_),
  )
  assert_true(
    app.update(source, context => {
      ignore(context.set(6))
      ignore(context.notify())
      Ok(())
    })
    is Ok(_),
  )
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(event_read == Some(6))
  assert_true(update_accepted)
  assert_true(app.read(target, value => value) is Ok(4))
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(app.read(target, value => value) is Ok(8))
  assert_true(app.revision(target) is Ok(1))
}

///|
test "cancelled timers leave pending work and expired task contexts" {
  let app = start_app()
  let mut called = false
  let mut saved_context : @core.TaskContext? = None
  let delayed = match
    app.schedule_after(100, context => {
      called = true
      saved_context = Some(context)
      Ok(())
    }) {
    Ok(task) => task
    Err(_) => fail("valid timer should be scheduled")
  }
  assert_true(app.pending_work() == 1)
  assert_true(delayed.cancel())
  assert_true(app.pending_work() == 0)
  assert_true(app.advance_time_by(100) is Ok(_))
  assert_true(drain(app))
  assert_true(!called)
  assert_true(delayed.status() is @core.TaskStatus::Cancelled)
  assert_true(saved_context is None)

  let immediate = match
    app.dispatch(context => {
      saved_context = Some(context)
      Ok(())
    }) {
    Ok(task) => task
    Err(_) => fail("dispatch should queue a task")
  }
  assert_true(drain(app))
  assert_true(immediate.status() is @core.TaskStatus::Completed)
  match saved_context {
    None => fail("task callback should retain its context for the test")
    Some(context) =>
      match context.is_cancel_requested() {
        Err(error) =>
          assert_true(error.code() is @diagnostics.ErrorCode::ContextExpired)
        Ok(_) => fail("task context must expire after callback completion")
      }
  }

  let mut task_to_cancel : @core.Task? = None
  let mut cancellation_seen = false
  let mut cancellation_accepted = false
  let cooperative = match
    app.dispatch(context => {
      match task_to_cancel {
        None => ()
        Some(task) => cancellation_accepted = task.cancel()
      }
      cancellation_seen = match context.is_cancel_requested() {
        Ok(requested) => requested
        Err(_) => false
      }
      Ok(())
    }) {
    Ok(task) => task
    Err(_) => fail("cooperative cancellation task should queue")
  }
  task_to_cancel = Some(cooperative)
  assert_true(drain(app))
  assert_true(cancellation_accepted)
  assert_true(cancellation_seen)
  assert_true(cooperative.status() is @core.TaskStatus::Cancelled)
}
