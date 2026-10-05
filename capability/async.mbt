///|
/// A monotonic, portable cancellation scope. Cancellation cannot be reset.
/// Pass it before begin to cancel synchronously reentrant admission callbacks.
pub struct InvocationScope {
  priv cancelled : Ref[Bool]
}

///|
pub fn InvocationScope::new() -> InvocationScope {
  { cancelled: Ref(false), }
}

///|
pub fn InvocationScope::cancel(self : InvocationScope) -> Unit {
  self.cancelled.val = true
}

///|
/// Each resume executes at most one application factory or work step. A step
/// must do bounded work and return control; this API does not preempt callbacks.
pub(all) enum WorkStep[O] {
  Pending
  Complete(O)
  Fail(@diagnostics.FrameworkError)
}

///|
pub(all) enum InvocationOutcome[O] {
  Pending
  Ready(O)
  Failed(@diagnostics.FrameworkError)
  Cancelled
  Busy
  Consumed
}

///|
pub(all) enum Cancellation {
  Cancelled
  AlreadyCancelled
  TooLate
}

///|
pub struct Invocation[O] {
  priv start : Ref[
    (() -> Result[() -> WorkStep[O], @diagnostics.FrameworkError])?,
  ]
  priv step : Ref[(() -> WorkStep[O])?]
  priv lifetime : Ref[RegistryLifetime?]
  priv callbacks : Ref[InvocationCallbacks[O]?]
  priv busy : Ref[Bool]
  priv cancelled : Ref[Bool]
  priv scope : InvocationScope
  priv consumed : Ref[Bool]
}

///|
priv struct InvocationCallbacks[O] {
  authorize : () -> Result[Unit, @diagnostics.FrameworkError]
  admission : () -> Result[Unit, @diagnostics.FrameworkError]
  validate : (O) -> Result[Unit, @diagnostics.FrameworkError]
}

///|
fn[O] Invocation::liveness(
  self : Invocation[O],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.lifetime.val {
    None => Ok(())
    Some(lifetime) => lifetime.check("poll")
  }
}

///|
fn[O] Invocation::clear(self : Invocation[O]) -> Unit {
  self.start.val = None
  self.step.val = None
  self.callbacks.val = None
}

///|
pub fn[O] Invocation::cancel(self : Invocation[O]) -> Cancellation {
  if self.is_cancelled() {
    self.clear()
    AlreadyCancelled
  } else if self.consumed.val {
    TooLate
  } else {
    self.cancelled.val = true
    self.clear()
    Cancelled
  }
}

///|
fn[O] Invocation::check(
  self : Invocation[O],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.liveness() {
    Err(error) => Err(error)
    Ok(_) =>
      if self.is_cancelled() {
        Ok(())
      } else {
        match self.callbacks.val {
          Some(callbacks) => (callbacks.authorize)()
          None => Ok(())
        }
      }
  }
}

///|
/// Ready and Failed are delivered once. Later resumes return Consumed (or
/// Failed(StaleHandle) after owner revocation). No typed output is retained.
pub fn[O] Invocation::poll(self : Invocation[O]) -> InvocationOutcome[O] {
  // Lock before *any* callback, including policy. Reentrant resumes cannot
  // advance work or recursively authorize the same job.
  if self.busy.val {
    return Busy
  }
  self.busy.val = true
  let outcome = self.advance()
  self.busy.val = false
  outcome
}

///|
fn[O] Invocation::advance(self : Invocation[O]) -> InvocationOutcome[O] {
  match self.liveness() {
    Err(error) => {
      self.clear()
      self.consumed.val = true
      return Failed(error)
    }
    Ok(_) => ()
  }
  if self.is_cancelled() {
    self.clear()
    return Cancelled
  }
  if self.consumed.val {
    return Consumed
  }
  match self.check() {
    Err(error) => return self.finish(Fail(error))
    Ok(_) => ()
  }
  if self.is_cancelled() {
    self.clear()
    return Cancelled
  }
  match self.start.val {
    Some(start) => {
      let admitted = match self.callbacks.val {
        Some(callbacks) => (callbacks.admission)()
        None => Ok(())
      }
      match self.liveness() {
        Err(error) => return self.finish(Fail(error))
        Ok(_) => ()
      }
      if self.is_cancelled() {
        self.clear()
        return Cancelled
      }
      match admitted {
        Err(error) => return self.finish(Fail(error))
        Ok(_) => ()
      }
      match self.check() {
        Err(error) => return self.finish(Fail(error))
        Ok(_) => ()
      }
      if self.is_cancelled() {
        self.clear()
        return Cancelled
      }
      self.start.val = None
      let started = start()
      match started {
        Err(error) => self.finish(Fail(error))
        Ok(step) => {
          // A factory is a turn on its own, never an unbounded spin to ready.
          let result = self.finish(Pending)
          if result is Pending {
            self.step.val = Some(step)
          }
          result
        }
      }
    }
    None =>
      match self.step.val {
        Some(step) => self.finish(step())
        None => Consumed
      }
  }
}

///|
fn[O] Invocation::finish(
  self : Invocation[O],
  result : WorkStep[O],
) -> InvocationOutcome[O] {
  // Reauthorize every returned result/error, including a successful commit.
  // Availability is intentionally absent here: the effect can change it.
  let checked = self.check()
  match self.liveness() {
    Err(error) => {
      self.clear()
      self.consumed.val = true
      return Failed(error)
    }
    Ok(_) => ()
  }
  if self.is_cancelled() {
    self.clear()
    return Cancelled
  }
  match checked {
    Err(error) => {
      self.clear()
      self.consumed.val = true
      return Failed(error)
    }
    Ok(_) => ()
  }
  match result {
    Pending => Pending
    Fail(error) => {
      self.clear()
      self.consumed.val = true
      Failed(error)
    }
    Complete(output) => {
      let validated = match self.callbacks.val {
        Some(callbacks) => (callbacks.validate)(output)
        None => Ok(())
      }
      // Output validation is an application callback, too.
      let authorized = self.check()
      let cancelled = self.is_cancelled()
      self.clear()
      self.consumed.val = true
      match self.liveness() {
        Err(error) => return Failed(error)
        Ok(_) => ()
      }
      if cancelled {
        self.clear()
        return Cancelled
      }
      match authorized {
        Err(error) => Failed(error)
        Ok(_) =>
          match validated {
            Err(error) => Failed(error)
            Ok(_) => Ready(output)
          }
      }
    }
  }
}

///|
/// An additive cooperative capability. snapshot_input must make a deep owned
/// snapshot even when decode returns application-owned mutable storage.
pub struct AsyncCapability[I, O] {
  priv semantic : TypedCapability[I, O]
  priv snapshot_input : (I) -> Result[I, @diagnostics.FrameworkError]
  priv start : (I) -> Result[() -> WorkStep[O], @diagnostics.FrameworkError]
}

///|
pub fn[I, O] AsyncCapability::new(
  descriptor : Descriptor,
  decode : (Value) -> Result[I, @diagnostics.FrameworkError],
  encode : (O) -> Result[Value, @diagnostics.FrameworkError],
  snapshot_input : (I) -> Result[I, @diagnostics.FrameworkError],
  validate_input : (I) -> Result[Unit, @diagnostics.FrameworkError],
  validate_output : (O) -> Result[Unit, @diagnostics.FrameworkError],
  start : (I) -> Result[() -> WorkStep[O], @diagnostics.FrameworkError],
  availability : () -> Result[Unit, @diagnostics.FrameworkError],
  policy : (InvocationOrigin) -> Result[Unit, @diagnostics.FrameworkError],
) -> AsyncCapability[I, O] {
  {
    semantic: TypedCapability::new_with_validation(
      descriptor,
      decode,
      encode,
      validate_input,
      validate_output,
      _ => {
        Err(
          capability_error(
            @diagnostics.UnsupportedCapability,
            descriptor.id,
            "cooperative capability requires begin/poll",
          ),
        )
      },
      availability,
      policy,
    ),
    snapshot_input,
    start,
  }
}

///|
pub fn[I, O] AsyncCapability::descriptor(
  self : AsyncCapability[I, O],
) -> Descriptor {
  self.semantic.descriptor()
}

///|
pub fn[I, O] AsyncCapability::begin(
  self : AsyncCapability[I, O],
  origin : InvocationOrigin,
  input : I,
  scope? : InvocationScope = InvocationScope::new(),
) -> Result[Invocation[O], @diagnostics.FrameworkError] {
  match self.admit(origin, scope) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  self.capture(origin, input, scope)
}

///|
fn[I, O] AsyncCapability::capture(
  self : AsyncCapability[I, O],
  origin : InvocationOrigin,
  input : I,
  scope : InvocationScope,
  cancelled? : Ref[Bool] = Ref(false),
) -> Result[Invocation[O], @diagnostics.FrameworkError] {
  match self.stage(Ok(()), scope) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let owned = self.stage((self.snapshot_input)(input), scope)
  match owned {
    Err(error) => Err(error)
    Ok(owned) => {
      match self.stage((self.semantic.validate_input)(owned), scope) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match self.stage(self.semantic.authorize(origin), scope) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      Ok({
        start: Ref(Some(() => (self.start)(owned))),
        step: Ref(None),
        lifetime: self.semantic.lifetime,
        callbacks: Ref(
          Some({
            admission: () => {
              self.semantic.complete_stage((self.semantic.availability)())
            },
            authorize: () => self.semantic.authorize(origin),
            validate: self.semantic.validate_output,
          }),
        ),
        busy: Ref(false),
        cancelled,
        scope,
        consumed: Ref(false),
      })
    }
  }
}

///|
fn[I, O] AsyncCapability::begin_value(
  self : AsyncCapability[I, O],
  origin : InvocationOrigin,
  input : Value,
  scope : InvocationScope,
) -> Result[Invocation[Value], @diagnostics.FrameworkError] {
  match self.stage(Ok(()), scope) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let input = match input.try_clone_transport() {
    Err(error) => return Err(error)
    Ok(input) => input
  }
  match self.admit(origin, scope) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if !self.semantic.descriptor.input_schema.accepts(input) {
    return Err(
      capability_error(
        @diagnostics.InvalidInput,
        self.descriptor().id,
        "input does not satisfy the declared schema",
      ),
    )
  }
  let decoded = (self.semantic.decode)(input)
  match self.stage(Ok(()), scope) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let decoded = match decoded {
    Err(error) =>
      return Err(
        boundary_conversion_error(
          @diagnostics.InvalidInput,
          self.descriptor().id,
          "input conversion failed",
          error,
        ),
      )
    Ok(input) => input
  }
  // Project only at the erased boundary; the same owned typed snapshot and
  // input/domain callbacks are used for every origin.
  let semantic = self.semantic
  let cancelled = Ref(false)
  let projected : AsyncCapability[I, Value] = {
    semantic: {
      descriptor: semantic.descriptor,
      lifetime: semantic.lifetime,
      decode: semantic.decode,
      encode: value => Ok(value),
      validate_input: semantic.validate_input,
      validate_output: _ => Ok(()),
      handler: _ => {
        Err(
          capability_error(
            @diagnostics.UnsupportedCapability,
            semantic.descriptor.id,
            "cooperative capability requires begin/poll",
          ),
        )
      },
      availability: semantic.availability,
      policy: semantic.policy,
    },
    snapshot_input: self.snapshot_input,
    start: input => {
      match (self.start)(input) {
        Err(error) => Err(error)
        Ok(step) =>
          Ok(() => {
            match step() {
              Pending => Pending
              Fail(error) => Fail(error)
              Complete(output) => {
                if cancelled.val || scope.cancelled.val {
                  return Pending
                }
                match semantic.authorize(origin) {
                  Err(error) => return Fail(error)
                  Ok(_) => ()
                }
                if cancelled.val || scope.cancelled.val {
                  return Pending
                }
                match
                  semantic.complete_stage((semantic.validate_output)(output)) {
                  Err(error) => Fail(error)
                  Ok(_) => {
                    if cancelled.val || scope.cancelled.val {
                      return Pending
                    }
                    match semantic.authorize(origin) {
                      Err(error) => return Fail(error)
                      Ok(_) => ()
                    }
                    if cancelled.val || scope.cancelled.val {
                      return Pending
                    }
                    match semantic.encode_output_value(output) {
                      Err(error) => Fail(error)
                      Ok(value) =>
                        match value.try_clone_transport() {
                          Err(error) => Fail(error)
                          Ok(owned) => Complete(owned)
                        }
                    }
                  }
                }
              }
            }
          })
      }
    },
  }
  projected.capture(origin, decoded, scope, cancelled~)
}

///|
pub fn[I, O] Registry::register_async(
  self : Registry,
  capability : AsyncCapability[I, O],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.register(capability.semantic) {
    Err(error) => Err(error)
    Ok(_) => {
      let index = self.state.val.entries.length() - 1
      let entry = self.state.val.entries[index]
      self.state.val.entries[index] = {
        ..entry,
        invoke: (_, _) => {
          Err(
            capability_error(
              @diagnostics.UnsupportedCapability,
              capability.descriptor().id,
              "cooperative capability requires begin/poll",
            ),
          )
        },
        begin: Some((origin, input, scope) => {
          capability.begin_value(origin, input, scope)
        }),
      }
      Ok(())
    }
  }
}

///|
/// Complete semantic discovery includes cooperative entries. Legacy adapters
/// use this execution-mode query to omit entries they cannot drive.
pub fn Registry::is_async(self : Registry, id : String) -> Bool {
  if !self.is_alive() {
    return false
  }
  for entry in self.state.val.entries {
    if entry.descriptor.id == id {
      return entry.begin is Some(_)
    }
  }
  false
}

///|
pub fn Registry::begin(
  self : Registry,
  id : String,
  origin : InvocationOrigin,
  input : Value,
  scope? : InvocationScope = InvocationScope::new(),
) -> Result[Invocation[Value], @diagnostics.FrameworkError] {
  match self.lifetime.check("begin") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for entry in self.state.val.entries {
    if entry.descriptor.id == id {
      match entry.begin {
        Some(begin) => return begin(origin, input, scope)
        None => break
      }
    }
  }
  Err(
    capability_error(
      @diagnostics.UnsupportedCapability,
      "registry.begin",
      "unknown or synchronous capability: \{id}",
    ),
  )
}

///|
pub fn Registry::begin_external(
  self : Registry,
  name : String,
  origin : InvocationOrigin,
  input : Value,
  scope? : InvocationScope = InvocationScope::new(),
) -> Result[Invocation[Value], @diagnostics.FrameworkError] {
  match self.lifetime.check("begin_external") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for entry in self.state.val.entries {
    if entry.descriptor.exposure is External &&
      entry.descriptor.external_name == name {
      match entry.begin {
        Some(begin) => return begin(origin, input, scope)
        None => break
      }
    }
  }
  Err(
    capability_error(
      @diagnostics.UnsupportedCapability,
      "registry.begin_external",
      "unknown or synchronous external capability: \{name}",
    ),
  )
}

///|
pub struct AsyncGuiBinding[I, O] {
  priv capability : AsyncCapability[I, O]
}

///|
pub fn[I, O] AsyncCapability::gui_binding(
  self : AsyncCapability[I, O],
) -> AsyncGuiBinding[I, O] {
  { capability: self, }
}

///|
pub fn[I, O] AsyncGuiBinding::begin(
  self : AsyncGuiBinding[I, O],
  input : I,
  scope? : InvocationScope = InvocationScope::new(),
) -> Result[Invocation[O], @diagnostics.FrameworkError] {
  self.capability.begin(Gui, input, scope~)
}

///|
pub fn[I, O] AsyncGuiBinding::is_enabled(self : AsyncGuiBinding[I, O]) -> Bool {
  self.capability.semantic.check(Gui) is Ok(_)
}

///|
fn[I, O, T] AsyncCapability::stage(
  self : AsyncCapability[I, O],
  result : Result[T, @diagnostics.FrameworkError],
  scope : InvocationScope,
) -> Result[T, @diagnostics.FrameworkError] {
  match self.semantic.complete_stage(Ok(())) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if scope.cancelled.val {
    Err(
      capability_error(
        @diagnostics.HostStopping,
        self.descriptor().id,
        "invocation cancelled during admission",
      ),
    )
  } else {
    result
  }
}

///|
fn[I, O] AsyncCapability::admit(
  self : AsyncCapability[I, O],
  origin : InvocationOrigin,
  scope : InvocationScope,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.stage(self.semantic.check_exposure(origin), scope) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match self.stage((self.semantic.availability)(), scope) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  self.stage(self.semantic.authorize(origin), scope)
}

///|
fn[O] Invocation::is_cancelled(self : Invocation[O]) -> Bool {
  if !self.consumed.val && self.scope.cancelled.val {
    self.cancelled.val = true
  }
  self.cancelled.val
}
