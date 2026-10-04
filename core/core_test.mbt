///|
fn running_app() -> @core.App raise {
  let app = match @core.App::new() {
    Ok(app) => app
    Err(_) => fail("headless app allocation should succeed")
  }
  match app.start() {
    Ok(_) => app
    Err(_) => fail("new app should start")
  }
}

///|
fn int_entity(app : @core.App, value : Int) -> @core.Entity[Int] raise {
  match app.create_entity(value) {
    Ok(entity) => entity
    Err(_) => fail("running app should create an entity")
  }
}

///|
test "app lifecycle rejects early work and drains release before stopping" {
  let app = match @core.App::new() {
    Ok(app) => app
    Err(_) => fail("headless app allocation should succeed")
  }
  assert_true(app.lifecycle() is @core.New)
  match app.create_entity(1) {
    Err(error) => assert_true(error.code().label() == "app_not_running")
    Ok(_) => fail("entity creation before start must be rejected")
  }
  assert_true(app.start() is Ok(_))
  assert_true(app.start() is Err(_))
  let entity = int_entity(app, 1)
  assert_true(app.request_stop() is Ok(_))
  assert_true(app.lifecycle() is @core.Stopping)
  assert_true(!entity.is_live())
  assert_true(app.run_ready(0) is Ok(0))
  assert_true(app.lifecycle() is @core.Stopping)
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(app.lifecycle() is @core.Stopped)
  assert_true(app.start() is Err(_))
}

///|
test "dispatch and entity notifications use submission FIFO and read updated state" {
  let app = running_app()
  let entity = int_entity(app, 0)
  let order : Ref[Array[String]] = Ref([])
  let read_during_dispatch = Ref(false)
  assert_true(
    app.update(entity, context => {
      match
        context.subscribe(entity, event => {
          if event.kind() is @core.Changed {
            order.val.push("notification")
            match app.read(entity, value => value) {
              Ok(7) => read_during_dispatch.val = true
              _ => ()
            }
          }
          Ok(())
        }) {
        Ok(_) => Ok(())
        Err(error) => Err(error)
      }
    })
    is Ok(_),
  )
  assert_true(
    app.dispatch(_task_context => {
      order.val.push("dispatch")
      Ok(())
    })
    is Ok(_),
  )
  assert_true(
    app.update(entity, context => {
      match context.set(7) {
        Err(error) => Err(error)
        Ok(_) => context.notify()
      }
    })
    is Ok(_),
  )
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(order.val.length() == 1)
  assert_true(order.val[0] == "dispatch")
  assert_true(app.run_ready(8) is Ok(1))
  assert_true(order.val.length() == 2)
  assert_true(order.val[1] == "notification")
  assert_true(read_during_dispatch.val)
}

///|
test "timers preserve tied order, respect budgets, and reject deadline overflow" {
  let app = running_app()
  let order : Ref[Array[Int]] = Ref([])
  assert_true(
    app.schedule_after(10, _context => {
      order.val.push(1)
      Ok(())
    })
    is Ok(_),
  )
  assert_true(
    app.schedule_after(10, _context => {
      order.val.push(2)
      Ok(())
    })
    is Ok(_),
  )
  assert_true(app.pending_work() == 2)
  assert_true(app.advance_time_by(10) is Ok(_))
  assert_true(app.now_ms() == 10)
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(order.val.length() == 1 && order.val[0] == 1)
  assert_true(app.pending_work() == 1)
  assert_true(app.run_ready(0) is Ok(0))
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(order.val.length() == 2 && order.val[1] == 2)

  let max_uint64 : UInt64 = 0xffff_ffff_ffff_ffff
  let remaining = max_uint64 - app.now_ms()
  assert_true(app.advance_time_by(remaining) is Ok(_))
  match app.schedule_after(1, _context => Ok(())) {
    Err(error) => assert_true(error.code().label() == "resource_exhausted")
    Ok(_) => fail("deadline overflow must be rejected")
  }
}

///|
test "failed updates retain visible writes and later listeners still run" {
  let app = running_app()
  let entity = int_entity(app, 0)
  let observer = int_entity(app, 0)
  let later_listener_ran = Ref(false)
  let owned_subscription : Ref[@core.Subscription?] = Ref(None)
  assert_true(
    app.update(observer, context => {
      match
        context.subscribe(entity, _event => {
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "first_listener",
              message="listener detail",
            ),
          )
        }) {
        Err(error) => Err(error)
        Ok(_) =>
          match
            context.subscribe(entity, _event => {
              later_listener_ran.val = true
              Ok(())
            }) {
            Err(error) => Err(error)
            Ok(subscription) => {
              owned_subscription.val = Some(subscription)
              Ok(())
            }
          }
      }
    })
    is Ok(_),
  )
  let failed_update = app.update(entity, context => {
    match context.set(9) {
      Err(error) => Err(error)
      Ok(_) =>
        match context.notify() {
          Err(error) => Err(error)
          Ok(_) =>
            Err(
              @diagnostics.FrameworkError::new(
                @diagnostics.InvalidInput,
                "validate_value",
                message="kept partial write",
              ),
            )
        }
    }
  })
  match failed_update {
    Err(error) => {
      assert_true(error.code().label() == "callback_failure")
      assert_true(
        error.message() ==
        Some(
          "callback returned invalid_input from validate_value: kept partial write",
        ),
      )
    }
    Ok(_) => fail("entered update error should be returned")
  }
  assert_true(app.revision(entity) is Ok(1))
  assert_true(app.read(entity, value => value) is Ok(9))
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(later_listener_ran.val)
  assert_true(app.diagnostics().length() == 2)
  match owned_subscription.val {
    Some(subscription) => {
      assert_true(subscription.is_active())
      assert_true(app.destroy_entity(entity) is Ok(_))
      assert_true(subscription.is_active())
      assert_true(app.run_ready(8) is Ok(1))
      assert_true(app.diagnostics().length() == 3)
      assert_true(later_listener_ran.val)
      assert_true(app.destroy_entity(observer) is Ok(_))
      assert_true(!subscription.is_active())
      assert_true(app.run_ready(8) is Ok(1))
    }
    None => fail("owner should retain its subscription")
  }
}

///|
test "foreign handles and callback reentry fail before user code or queue drain" {
  let first = running_app()
  let second = running_app()
  let first_entity = int_entity(first, 1)
  let foreign_entity = int_entity(second, 2)
  let callback_ran = Ref(false)

  match first.read(foreign_entity, _value => 0) {
    Err(error) => assert_true(error.code().label() == "wrong_app")
    Ok(_) => fail("foreign entity reads must be rejected")
  }
  match
    first.update(foreign_entity, _context => {
      callback_ran.val = true
      Ok(())
    }) {
    Err(error) => assert_true(error.code().label() == "wrong_app")
    Ok(_) => fail("foreign entity updates must be rejected")
  }
  assert_true(first.destroy_entity(foreign_entity) is Err(_))
  assert_true(!callback_ran.val)

  let dispatched = first.dispatch(_context => Ok(()))
  assert_true(dispatched is Ok(_))
  let read_guard = Ref("")
  let update_guard = Ref("")
  assert_true(
    first.read(first_entity, _value => {
      match first.run_ready(1) {
        Err(error) => read_guard.val = error.code().label()
        Ok(_) => read_guard.val = "unexpectedly_drained"
      }
      match
        first.update(first_entity, _context => {
          callback_ran.val = true
          Ok(())
        }) {
        Err(error) => update_guard.val = error.code().label()
        Ok(_) => update_guard.val = "unexpectedly_updated"
      }
      0
    })
    is Ok(0),
  )
  assert_true(read_guard.val == "reentrant_update")
  assert_true(update_guard.val == "reentrant_update")
  assert_true(first.pending_work() == 1)

  assert_true(
    first.update(first_entity, _context => {
      match first.run_ready(1) {
        Err(error) => update_guard.val = error.code().label()
        Ok(_) => update_guard.val = "unexpectedly_drained"
      }
      Ok(())
    })
    is Ok(_),
  )
  assert_true(update_guard.val == "reentrant_update")
  assert_true(!callback_ran.val)
  assert_true(first.run_ready(1) is Ok(1))
}

///|
test "task failures preserve causes and stop requests cancel queued work cooperatively" {
  let app = running_app()
  let failure_task = match
    app.dispatch(_context => {
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "task_validation",
          message="bad task input",
        ),
      )
    }) {
    Ok(task) => task
    Err(_) => fail("running app should accept a task")
  }
  assert_true(app.run_ready(1) is Ok(1))
  assert_true(failure_task.status() is @core.Failed)
  match failure_task.failure() {
    Some(error) => {
      assert_true(error.code().label() == "task_failure")
      assert_true(
        error.message() ==
        Some(
          "callback returned invalid_input from task_validation: bad task input",
        ),
      )
    }
    None => fail("failed task should keep its error")
  }

  let app_to_stop = running_app()
  let token_seen = Ref(false)
  let stop_request_succeeded = Ref(false)
  let task_context_valid = Ref(false)
  let cancel_me = match
    app_to_stop.dispatch(context => {
      stop_request_succeeded.val = app_to_stop.request_stop() is Ok(_)
      match context.is_cancel_requested() {
        Ok(value) => {
          token_seen.val = value
          task_context_valid.val = true
        }
        Err(_) => task_context_valid.val = false
      }
      Ok(())
    }) {
    Ok(task) => task
    Err(_) => fail("running app should accept a task")
  }
  let queued = match app_to_stop.dispatch(_context => Ok(())) {
    Ok(task) => task
    Err(_) => fail("running app should accept queued work")
  }
  assert_true(app_to_stop.run_ready(8) is Ok(2))
  assert_true(stop_request_succeeded.val)
  assert_true(task_context_valid.val)
  assert_true(token_seen.val)
  assert_true(cancel_me.status() is @core.Cancelled)
  assert_true(queued.status() is @core.Cancelled)
  assert_true(app_to_stop.lifecycle() is @core.Stopped)
}

///|
test "stop inside update expires context immediately and defers release safely" {
  let app = running_app()
  let entity = int_entity(app, 0)
  let context_access : Ref[String?] = Ref(None)
  assert_true(
    app.update(entity, context => {
      match context.set(3) {
        Err(error) => Err(error)
        Ok(_) =>
          match app.request_stop() {
            Err(error) => Err(error)
            Ok(_) =>
              match context.get() {
                Err(error) => {
                  context_access.val = Some(error.code().label())
                  Ok(())
                }
                Ok(_) => Ok(())
              }
          }
      }
    })
    is Ok(_),
  )
  assert_true(context_access.val == Some("app_not_running"))
  assert_true(entity.is_live())
  assert_true(app.lifecycle() is @core.Stopping)
  assert_true(app.run_ready(8) is Ok(2))
  assert_true(!entity.is_live())
  assert_true(app.lifecycle() is @core.Stopped)
}

///|
test "new apps may be stopped directly and ready-work budgets reject negatives" {
  let app = match @core.App::new() {
    Ok(app) => app
    Err(_) => fail("headless app allocation should succeed")
  }
  assert_true(app.request_stop() is Ok(_))
  assert_true(app.lifecycle() is @core.Stopped)
  assert_true(app.request_stop() is Ok(_))

  let running = running_app()
  match running.run_ready(-1) {
    Err(error) => assert_true(error.code().label() == "invalid_input")
    Ok(_) => fail("negative ready-work budgets must be rejected")
  }
}

///|
test "app lifetime token is shared read only and revoked before deferred shutdown" {
  let app = running_app()
  let first = app.lifetime()
  let second = app.lifetime()
  let unrelated = running_app().lifetime()
  assert_true(first.app_id() == app.id())
  assert_true(first.is_alive())
  let entity = int_entity(app, 1)
  let observed_revocation = Ref(false)
  assert_true(
    app.update(entity, _context => {
      ignore(app.request_stop())
      observed_revocation.val = !first.is_alive() &&
        !second.is_alive() &&
        entity.is_live()
      ignore(app.request_stop())
      Ok(())
    })
    is Ok(_),
  )
  assert_true(observed_revocation.val)
  assert_true(unrelated.is_alive())
  assert_true(app.run_ready(8) is Ok(_))
  assert_true(!app.lifetime().is_alive())
  assert_true(app.request_stop() is Ok(_))
  assert_true(!first.is_alive())
  let never_started = match @core.App::new() {
    Ok(app) => app
    Err(_) => fail("app allocation should succeed")
  }
  let token = never_started.lifetime()
  assert_true(token.is_alive())
  assert_true(never_started.request_stop() is Ok(_))
  assert_true(!token.is_alive())
}
