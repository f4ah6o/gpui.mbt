///|
/// Reusable portable backend conformance gate; consumes and stops a running
/// test host without depending on target-specific batching or host-state APIs.
pub fn[B : @platform.Backend] check_host(
  host : B,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match host.require_capability(@platform.NativeWindow) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match host.require_capability(@platform.TextInput) {
    Err(e) =>
      if !(e.code() is @diagnostics.UnsupportedCapability) {
        return Err(mismatch("unsupported_text_input"))
      }
    Ok(_) => return Err(mismatch("unexpected_text_input"))
  }
  match host.wake() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match host.next_event(timeout_ms=0) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match host.request_exit() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match host.create_window("must be rejected", 16.0, 16.0) {
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
