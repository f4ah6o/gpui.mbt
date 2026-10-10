///|
/// Errors from the Ubuntu button's app-owned accessibility adapter session.
/// This layer is transport-free: it owns neither D-Bus nor AT-SPI objects.
pub(all) enum UbuntuButtonAccessibilityError {
  SessionClosed
  StaleAdapterToken
  AdapterTokenExhausted
  ProjectionInvariant
  HostError(@diagnostics.FrameworkError)
  ProjectionError(@native.AccessibilityProjectionError)
  FixtureError(@fixture.ButtonDemoError)
  ActionError(@accessibility.ActionError)
} derive(Eq)

///|
pub extend UbuntuButtonAccessibilityError with Eq::{not_equal, equal}

///|
/// Opaque callback handle for one continuously exported projection node.
/// `scope` is an opaque projection identity; neither part flattens NodeId.
pub struct UbuntuButtonAdapterToken {
  priv scope : @native.AccessibilityExportId
  priv sequence : UInt64
} derive(Eq)

///|
pub extend UbuntuButtonAdapterToken with Eq::{not_equal, equal}

///|
pub struct UbuntuButtonAccessibilityNode {
  priv token : UbuntuButtonAdapterToken
  priv parent : UbuntuButtonAdapterToken?
  priv children : Array[UbuntuButtonAdapterToken]
  priv role : @accessibility.AccessibilityRole
  priv name : String
  priv bounds : @primitives.Rect
  priv enabled : Bool
  priv loading : Bool
  priv focused : Bool
  priv actions : Array[@accessibility.AccessibilityAction]
}

///|
pub fn UbuntuButtonAccessibilityNode::token(
  self : UbuntuButtonAccessibilityNode,
) -> UbuntuButtonAdapterToken {
  self.token
}

///|
pub fn UbuntuButtonAccessibilityNode::parent(
  self : UbuntuButtonAccessibilityNode,
) -> UbuntuButtonAdapterToken? {
  self.parent
}

///|
pub fn UbuntuButtonAccessibilityNode::children(
  self : UbuntuButtonAccessibilityNode,
) -> Array[UbuntuButtonAdapterToken] {
  let result : Array[UbuntuButtonAdapterToken] = []
  for token in self.children {
    result.push(token)
  }
  result
}

///|
pub fn UbuntuButtonAccessibilityNode::role(
  self : UbuntuButtonAccessibilityNode,
) -> @accessibility.AccessibilityRole {
  self.role
}

///|
pub fn UbuntuButtonAccessibilityNode::name(
  self : UbuntuButtonAccessibilityNode,
) -> String {
  self.name
}

///|
pub fn UbuntuButtonAccessibilityNode::bounds(
  self : UbuntuButtonAccessibilityNode,
) -> @primitives.Rect {
  self.bounds
}

///|
pub fn UbuntuButtonAccessibilityNode::is_enabled(
  self : UbuntuButtonAccessibilityNode,
) -> Bool {
  self.enabled
}

///|
pub fn UbuntuButtonAccessibilityNode::is_loading(
  self : UbuntuButtonAccessibilityNode,
) -> Bool {
  self.loading
}

///|
pub fn UbuntuButtonAccessibilityNode::is_focused(
  self : UbuntuButtonAccessibilityNode,
) -> Bool {
  self.focused
}

///|
pub fn UbuntuButtonAccessibilityNode::supported_actions(
  self : UbuntuButtonAccessibilityNode,
) -> Array[@accessibility.AccessibilityAction] {
  let result : Array[@accessibility.AccessibilityAction] = []
  for action in self.actions {
    result.push(action)
  }
  result
}

///|
/// Immutable, copied callback-facing view. Parent/child handles are adapter
/// tokens, never raw projection or model IDs.
pub struct UbuntuButtonAccessibilitySnapshot {
  priv revision : UInt64
  priv nodes : Array[UbuntuButtonAccessibilityNode]
}

///|
pub fn UbuntuButtonAccessibilitySnapshot::revision(
  self : UbuntuButtonAccessibilitySnapshot,
) -> UInt64 {
  self.revision
}

///|
pub fn UbuntuButtonAccessibilitySnapshot::nodes(
  self : UbuntuButtonAccessibilitySnapshot,
) -> Array[UbuntuButtonAccessibilityNode] {
  let result : Array[UbuntuButtonAccessibilityNode] = []
  for node in self.nodes {
    let children : Array[UbuntuButtonAdapterToken] = []
    for token in node.children {
      children.push(token)
    }
    let actions : Array[@accessibility.AccessibilityAction] = []
    for action in node.actions {
      actions.push(action)
    }
    result.push({ ..node, children, actions, })
  }
  result
}

///|
fn button_adapter_copy_snapshot(
  snapshot : UbuntuButtonAccessibilitySnapshot,
) -> UbuntuButtonAccessibilitySnapshot {
  let nodes : Array[UbuntuButtonAccessibilityNode] = []
  for node in snapshot.nodes {
    let children : Array[UbuntuButtonAdapterToken] = []
    for token in node.children {
      children.push(token)
    }
    let actions : Array[@accessibility.AccessibilityAction] = []
    for action in node.actions {
      actions.push(action)
    }
    nodes.push({ ..node, children, actions, })
  }
  { revision: snapshot.revision, nodes, }
}

///|
priv struct UbuntuButtonAdapterEntry {
  token : UbuntuButtonAdapterToken
  export_id : @native.AccessibilityExportId
}

///|
priv struct UbuntuButtonAccessibilityState {
  demo : @fixture.ButtonDemo
  source_model : @accessibility.AccessibilityModel
  scope : @native.AccessibilityExportId?
  next_sequence : UInt64
  sequence_exhausted : Bool
  closed : Bool
  entries : Array[UbuntuButtonAdapterEntry]
  current : UbuntuButtonAccessibilitySnapshot
}

///|
/// Owns the live fixture value and its native projection on the Wayland UI
/// owner thread. Callback handles map through a private side table to complete
/// opaque export IDs. The caller must feed physical fixture transitions back
/// through `publish`; `invoke` itself stores the fresh ButtonDemo it returns
/// from the app-owned action path.
pub struct UbuntuButtonAccessibilitySession {
  priv host : @native.Host
  priv projection : @native.AccessibilityProjection
  priv state : Ref[UbuntuButtonAccessibilityState]
}

///|
const BUTTON_ADAPTER_MAX_SEQUENCE : UInt64 = 0xffff_ffff_ffff_ffff

///|
fn button_adapter_empty_snapshot(
  revision : UInt64,
) -> UbuntuButtonAccessibilitySnapshot {
  { revision, nodes: [], }
}

///|
fn button_adapter_find_export(
  entries : Array[UbuntuButtonAdapterEntry],
  export_id : @native.AccessibilityExportId,
) -> Int {
  let mut index = 0
  while index < entries.length() {
    if entries[index].export_id == export_id {
      return index
    }
    index += 1
  }
  -1
}

///|
fn button_adapter_find_token(
  entries : Array[UbuntuButtonAdapterEntry],
  token : UbuntuButtonAdapterToken,
) -> Int {
  let mut index = 0
  while index < entries.length() {
    if entries[index].token == token {
      return index
    }
    index += 1
  }
  -1
}

///|
fn button_adapter_require_owner(
  host : @native.Host,
) -> Result[Unit, UbuntuButtonAccessibilityError] {
  match host.assert_owner_thread() {
    Ok(_) => Ok(())
    Err(error) => Err(HostError(error))
  }
}

///|
fn button_adapter_snapshot(
  projected : @native.AccessibilityProjectionSnapshot,
  entries : Array[UbuntuButtonAdapterEntry],
) -> Result[UbuntuButtonAccessibilitySnapshot, UbuntuButtonAccessibilityError] {
  let projected_nodes = projected.nodes()
  let nodes : Array[UbuntuButtonAccessibilityNode] = []
  let mut index = 0
  while index < projected_nodes.length() {
    let source = projected_nodes[index]
    let id_index = button_adapter_find_export(entries, source.id())
    if id_index < 0 {
      return Err(ProjectionInvariant)
    }
    let parent = match source.parent() {
      None => None
      Some(export_id) => {
        let parent_index = button_adapter_find_export(entries, export_id)
        if parent_index < 0 {
          return Err(ProjectionInvariant)
        }
        Some(entries[parent_index].token)
      }
    }
    let children : Array[UbuntuButtonAdapterToken] = []
    for export_id in source.children() {
      let child_index = button_adapter_find_export(entries, export_id)
      if child_index < 0 {
        return Err(ProjectionInvariant)
      }
      children.push(entries[child_index].token)
    }
    nodes.push({
      token: entries[id_index].token,
      parent,
      children,
      role: source.role(),
      name: source.name(),
      bounds: source.bounds(),
      enabled: source.is_enabled(),
      loading: source.is_loading(),
      focused: source.is_focused(),
      actions: source.supported_actions(),
    })
    index += 1
  }
  Ok({ revision: projected.revision(), nodes, })
}

///|
/// Start a projection session for the current ButtonDemo. The Host must be
/// live and this call must run on its UI-owner thread.
pub fn UbuntuButtonAccessibilitySession::new(
  host : @native.Host,
  demo : @fixture.ButtonDemo,
) -> Result[UbuntuButtonAccessibilitySession, UbuntuButtonAccessibilityError] {
  match button_adapter_require_owner(host) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let (source_model, _) = match demo.accessibility_source() {
    Ok(value) => value
    Err(error) => return Err(FixtureError(error))
  }
  let projection = match @native.AccessibilityProjection::new() {
    Ok(value) => value
    Err(error) => return Err(ProjectionError(error))
  }
  let session = {
    host,
    projection,
    state: Ref({
      demo,
      source_model,
      scope: None,
      next_sequence: 1UL,
      sequence_exhausted: false,
      closed: false,
      entries: [],
      current: button_adapter_empty_snapshot(0UL),
    }),
  }
  match session.publish(demo) {
    Ok(_) => Ok(session)
    Err(error) => {
      projection.close()
      Err(error)
    }
  }
}

///|
/// Publish the latest application-owned fixture state and atomically replace
/// the live callback table. IDs which leave the committed tree are removed;
/// adapter sequences are monotonic and never reused.
pub fn UbuntuButtonAccessibilitySession::publish(
  self : UbuntuButtonAccessibilitySession,
  demo : @fixture.ButtonDemo,
) -> Result[UbuntuButtonAccessibilitySnapshot, UbuntuButtonAccessibilityError] {
  match button_adapter_require_owner(self.host) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state = self.state.val
  if state.closed {
    return Err(SessionClosed)
  }
  let (model, source_snapshot) = match demo.accessibility_source() {
    Ok(value) => value
    Err(error) => return Err(FixtureError(error))
  }
  if !state.source_model.same_owner(model) {
    return Err(ProjectionError(@native.ForeignOwner))
  }
  let projected = match self.projection.publish(model, source_snapshot) {
    Ok(value) => value
    Err(error) => {
      // Once the adapter has validated a same-owner latest demo, any native
      // projection failure makes the callback table unusable. Revoke both
      // sides and retain/close that latest fixture value for correct teardown.
      demo.close()
      state.source_model.close()
      self.projection.close()
      self.state.val = {
        ..state,
        demo,
        closed: true,
        entries: [],
        current: button_adapter_empty_snapshot(state.current.revision),
      }
      return Err(ProjectionError(error))
    }
  }
  let projected_nodes = projected.nodes()
  let mut scope = state.scope
  if scope is None && projected_nodes.length() > 0 {
    scope = Some(projected_nodes[0].id())
  }
  let session_scope = match scope {
    Some(value) => value
    None if projected_nodes.length() == 0 => {
      let empty = button_adapter_empty_snapshot(projected.revision())
      self.state.val = { ..state, demo, scope, entries: [], current: empty, }
      return Ok(empty)
    }
    None => {
      demo.close()
      state.source_model.close()
      self.projection.close()
      self.state.val = {
        ..state,
        demo,
        closed: true,
        entries: [],
        current: button_adapter_empty_snapshot(projected.revision()),
      }
      return Err(ProjectionInvariant)
    }
  }
  let next_sequence = Ref(state.next_sequence)
  let exhausted = Ref(state.sequence_exhausted)
  let next_entries : Array[UbuntuButtonAdapterEntry] = []
  for node in projected_nodes {
    let previous = button_adapter_find_export(state.entries, node.id())
    if previous >= 0 {
      next_entries.push(state.entries[previous])
    } else if exhausted.val {
      demo.close()
      state.source_model.close()
      self.projection.close()
      self.state.val = {
        ..state,
        demo,
        closed: true,
        entries: [],
        current: button_adapter_empty_snapshot(projected.revision()),
      }
      return Err(AdapterTokenExhausted)
    } else {
      let sequence = next_sequence.val
      if sequence == BUTTON_ADAPTER_MAX_SEQUENCE {
        exhausted.val = true
      } else {
        next_sequence.val = sequence + 1UL
      }
      let token = { scope: session_scope, sequence, }
      next_entries.push({ token, export_id: node.id(), })
    }
  }
  let current = match button_adapter_snapshot(projected, next_entries) {
    Ok(value) => value
    Err(error) => {
      demo.close()
      state.source_model.close()
      self.projection.close()
      self.state.val = {
        ..state,
        demo,
        closed: true,
        entries: [],
        current: button_adapter_empty_snapshot(projected.revision()),
      }
      return Err(error)
    }
  }
  self.state.val = {
    ..state,
    demo,
    scope,
    next_sequence: next_sequence.val,
    sequence_exhausted: exhausted.val,
    entries: next_entries,
    current,
  }
  Ok(current)
}

///|
/// Return a detached callback-facing copy of the current committed tree.
pub fn UbuntuButtonAccessibilitySession::snapshot(
  self : UbuntuButtonAccessibilitySession,
) -> Result[UbuntuButtonAccessibilitySnapshot, UbuntuButtonAccessibilityError] {
  match button_adapter_require_owner(self.host) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state = self.state.val
  if state.closed {
    return Err(SessionClosed)
  }
  Ok(button_adapter_copy_snapshot(state.current))
}

///|
/// Invoke one current adapter token. Resolve its full opaque export ID against
/// the live projection, immediately build a fresh ActionRequest from that
/// receipt, dispatch through ButtonDemo, and retain the returned latest demo.
/// Repeated Invoke on the latest value remains allowed by contract.
pub fn UbuntuButtonAccessibilitySession::invoke(
  self : UbuntuButtonAccessibilitySession,
  token : UbuntuButtonAdapterToken,
) -> Result[UbuntuButtonAccessibilitySnapshot, UbuntuButtonAccessibilityError] {
  match button_adapter_require_owner(self.host) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state = self.state.val
  if state.closed {
    return Err(SessionClosed)
  }
  let entry_index = button_adapter_find_token(state.entries, token)
  if entry_index < 0 {
    return Err(StaleAdapterToken)
  }
  let intent = match
    self.projection.resolve_action(
      state.entries[entry_index].export_id,
      @accessibility.Invoke,
    ) {
    Ok(value) => value
    Err(error) => return Err(ProjectionError(error))
  }
  let request = @accessibility.ActionRequest::new(
    intent.node_id(),
    intent.action(),
  )
  let updated_demo = match state.demo.dispatch_accessibility_request(request) {
    Ok(value) => value
    Err(error) => return Err(ActionError(error))
  }
  // The previous immutable fixture copy is now stale. Retain the fresh value
  // before republishing so even a projection failure cannot lose its owner.
  self.state.val = { ..state, demo: updated_demo, }
  self.publish(updated_demo)
}

///|
/// Read the latest application-owned fixture after physical input or Invoke.
pub fn UbuntuButtonAccessibilitySession::current_demo(
  self : UbuntuButtonAccessibilitySession,
) -> Result[@fixture.ButtonDemo, UbuntuButtonAccessibilityError] {
  match button_adapter_require_owner(self.host) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state = self.state.val
  if state.closed {
    Err(SessionClosed)
  } else {
    Ok(state.demo)
  }
}

///|
/// Revoke callback tokens and close the application semantic model before the
/// host window is torn down. Repeated close is harmless.
pub fn UbuntuButtonAccessibilitySession::close(
  self : UbuntuButtonAccessibilitySession,
) -> Result[Unit, UbuntuButtonAccessibilityError] {
  match button_adapter_require_owner(self.host) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state = self.state.val
  if state.closed {
    return Ok(())
  }
  state.demo.close()
  state.source_model.close()
  self.projection.close()
  self.state.val = {
    ..state,
    closed: true,
    entries: [],
    current: button_adapter_empty_snapshot(state.current.revision),
  }
  Ok(())
}
