///|
fn retention_operation(mode : String) -> AsyncCapability[Int, Int] {
  let descriptor = match
    Descriptor::new(
      "retention",
      "retention",
      "retention",
      Command,
      Schema::int(),
      Schema::int(),
      StateChange,
      false,
      External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => abort("descriptor")
  }
  AsyncCapability::new(
    descriptor,
    value => value.as_int(),
    value => Ok(Value::int(value)),
    value => Ok(value),
    _ => Ok(()),
    _ => Ok(()),
    value => {
      Ok(() => {
        if mode == "error" {
          Fail(
            capability_error(@diagnostics.CallbackFailure, "test", "failure"),
          )
        } else {
          Complete(value)
        }
      })
    },
    () => Ok(()),
    _ => Ok(()),
  )
}

///|
test "terminal jobs clear all application callbacks and captured work" {
  for mode in ["ready", "error", "cancel", "scope", "stale"] {
    let operation = retention_operation(mode)
    let registry = Registry::new()
    assert_true(registry.register_async(operation) is Ok(_))
    let scope = InvocationScope::new()
    let job = match operation.begin(Direct, 7, scope~) {
      Ok(job) => job
      Err(_) => fail("begin")
    }
    assert_true(job.start.val is Some(_))
    assert_true(job.callbacks.val is Some(_))
    if mode == "cancel" {
      ignore(job.cancel())
    } else if mode == "scope" {
      scope.cancel()
      assert_true(job.poll() is Cancelled)
    } else if mode == "stale" {
      registry.teardown()
      assert_true(job.poll() is Failed(_))
    } else {
      assert_true(job.poll() is Pending)
      assert_true(job.start.val is None)
      assert_true(job.step.val is Some(_))
      match job.poll() {
        Ready(7) => assert_eq(mode, "ready")
        Failed(_) => assert_eq(mode, "error")
        _ => fail("terminal")
      }
    }
    assert_true(job.start.val is None)
    assert_true(job.step.val is None)
    assert_true(job.callbacks.val is None)
  }
}
