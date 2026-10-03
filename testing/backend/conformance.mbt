///|
/// Reusable host conformance gate; consumes and stops a running test host.
/// Future native backends can run this same gate without native types here.
pub fn[B : @platform.Backend] check_host(
  host : B,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if host.state() != @platform.Running {
    return Err(mismatch("running"))
  }
  match host.wake() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match host.dispatch(0) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match host.request_exit() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if host.state() != @platform.Quiescing {
    return Err(mismatch("quiescing"))
  }
  match host.create_window(16, 16, "must be rejected") {
    Err(e) =>
      if !(e.code() is @diagnostics.HostStopping) {
        return Err(mismatch("host_stopping"))
      }
    Ok(window) => {
      ignore(host.destroy_window(window))
      return Err(mismatch("late_window"))
    }
  }
  match host.stop() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match host.stop() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if host.state() != @platform.Stopped {
    return Err(mismatch("stopped"))
  }
  Ok(())
}

///|
fn mismatch(expectation : String) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.CallbackFailure,
    "backend_conformance",
    message=expectation,
  )
}
