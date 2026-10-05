///|
/// In-process cooperative results. No request IDs, wire cancellation protocol,
/// retained result replay, or transport scheduling are implied by this API.
pub(all) enum CooperativeOutcome {
  Pending
  Ready(@capability.Value)
  Failed(AdapterError)
  Cancelled
  Busy
  Consumed
}

///|
priv struct CooperativeSlot {
  scope : @capability.InvocationScope
  active : Ref[Bool]
  job : Ref[@capability.Invocation[@capability.Value]?]
}

///|
pub struct CooperativeCall {
  priv adapter : Adapter
  priv slot : CooperativeSlot
  priv invocation : @capability.Invocation[@capability.Value]
}

///|
fn Adapter::cancel_cooperative(self : Adapter) -> Unit {
  for slot in self.state.val.cooperative {
    slot.active.val = false
    slot.scope.cancel()
    match slot.job.val {
      Some(job) => ignore(job.cancel())
      None => ()
    }
    slot.job.val = None
  }
  self.state.val.cooperative.clear()
}

///|
fn Adapter::release_cooperative(self : Adapter, slot : CooperativeSlot) -> Unit {
  slot.active.val = false
  slot.job.val = None
  let mut index = self.state.val.cooperative.length() - 1
  while index >= 0 {
    if !self.state.val.cooperative[index].active.val {
      self.state.val.cooperative.remove(index) |> ignore
    }
    index -= 1
  }
}

///|
/// Cooperative discovery derives from the same registry descriptors, but is
/// separate from the synchronous inventory exposed by ProtocolServer.
pub fn Adapter::cooperative_inventory(
  self : Adapter,
) -> Result[Inventory, AdapterError] {
  match self.check_live() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let tools : Array[Tool] = []
  let resources : Array[Resource] = []
  for descriptor in self.registry.external_descriptors() {
    if self.registry.is_async(descriptor.id()) {
      if descriptor.kind() is @capability.Query &&
        descriptor.input_schema().is_unit() {
        resources.push(resource_from_descriptor(descriptor))
      } else {
        tools.push(tool_from_descriptor(descriptor))
      }
    }
  }
  Ok({ tools, resources, })
}

///|
fn Adapter::begin_cooperative(
  self : Adapter,
  id : String,
  input : @capability.Value,
) -> Result[CooperativeCall, AdapterError] {
  match self.check_live() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if self.state.val.cooperative.length() >= MAX_IN_FLIGHT_REQUESTS {
    return Err({
      code: Unavailable,
      message: "cooperative invocation limit reached",
    })
  }
  // Reserve before any application callback so reentrant admissions count.
  let slot : CooperativeSlot = {
    scope: @capability.InvocationScope::new(),
    active: Ref(true),
    job: Ref(None),
  }
  self.state.val.cooperative.push(slot)
  let started = self.registry.begin(
    id,
    @capability.RemoteMcp,
    input,
    scope=slot.scope,
  )
  match self.check_live() {
    Err(error) => {
      match started {
        Ok(job) => ignore(job.cancel())
        Err(_) => ()
      }
      self.release_cooperative(slot)
      return Err(error)
    }
    Ok(_) => ()
  }
  match started {
    Err(error) => {
      self.release_cooperative(slot)
      Err(map_error(error))
    }
    Ok(invocation) => {
      slot.job.val = Some(invocation)
      Ok({ adapter: self, slot, invocation, })
    }
  }
}

///|
pub fn Adapter::begin_tool(
  self : Adapter,
  name : String,
  input : @capability.Value,
) -> Result[CooperativeCall, AdapterError] {
  let inventory = match self.cooperative_inventory() {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  for tool in inventory.tools {
    if tool.name == name {
      return self.begin_cooperative(tool.semantic_id, input)
    }
  }
  Err({ code: UnknownOperation, message: "unknown cooperative tool: \{name}", })
}

///|
pub fn Adapter::begin_resource(
  self : Adapter,
  uri : String,
) -> Result[CooperativeCall, AdapterError] {
  let inventory = match self.cooperative_inventory() {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  for resource in inventory.resources {
    if resource.uri == uri {
      return self.begin_cooperative(
        resource.semantic_id,
        @capability.Value::unit(),
      )
    }
  }
  Err({
    code: UnknownOperation,
    message: "unknown cooperative resource: \{uri}",
  })
}

///|
pub fn CooperativeCall::cancel(
  self : CooperativeCall,
) -> @capability.Cancellation {
  let result = self.invocation.cancel()
  self.adapter.release_cooperative(self.slot)
  result
}

///|
pub fn CooperativeCall::poll(self : CooperativeCall) -> CooperativeOutcome {
  match self.adapter.check_live() {
    Err(error) => {
      ignore(self.cancel())
      return Failed(error)
    }
    Ok(_) => ()
  }
  let result = self.invocation.poll()
  match self.adapter.check_live() {
    Err(error) => {
      ignore(self.cancel())
      return Failed(error)
    }
    Ok(_) => ()
  }
  match result {
    Pending => Pending
    Busy => Busy
    Ready(value) => {
      self.adapter.release_cooperative(self.slot)
      Ready(value)
    }
    Failed(error) => {
      self.adapter.release_cooperative(self.slot)
      Failed(map_error(error))
    }
    Cancelled => {
      self.adapter.release_cooperative(self.slot)
      Cancelled
    }
    Consumed => {
      self.adapter.release_cooperative(self.slot)
      Consumed
    }
  }
}
