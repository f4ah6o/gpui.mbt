///|
/// Errors from the transport-free Ubuntu projection registry.
pub(all) enum AccessibilityProjectionError {
  ExportIdentityExhausted
  ForeignOwner
  SourceClosed
  StaleSnapshot
  ProjectionClosed
  SourceError(@accessibility.AccessibilityError)
  ActionRejected(@accessibility.ActionError)
} derive(Eq)

///|
pub extend AccessibilityProjectionError with Eq::{not_equal, equal}

///|
/// Opaque ID for one node in one Ubuntu projection registry. IDs are stable
/// while their full source NodeId remains continuously present, and are never
/// reused by this registry after removal, reset, or re-admission.
pub struct AccessibilityExportId {
  priv registry_owner : @accessibility.NodeId
  priv sequence : UInt64
} derive(Eq)

///|
pub extend AccessibilityExportId with Eq::{not_equal, equal}

///|
pub struct AccessibilityProjectionNode {
  priv id : AccessibilityExportId
  priv parent : AccessibilityExportId?
  priv children : Array[AccessibilityExportId]
  priv role : @accessibility.AccessibilityRole
  priv name : String
  priv bounds : @primitives.Rect
  priv enabled : Bool
  priv loading : Bool
  priv focused : Bool
  priv actions : Array[@accessibility.AccessibilityAction]
}

///|
pub fn AccessibilityProjectionNode::id(
  self : AccessibilityProjectionNode,
) -> AccessibilityExportId {
  self.id
}

///|
pub fn AccessibilityProjectionNode::parent(
  self : AccessibilityProjectionNode,
) -> AccessibilityExportId? {
  self.parent
}

///|
pub fn AccessibilityProjectionNode::children(
  self : AccessibilityProjectionNode,
) -> Array[AccessibilityExportId] {
  copy_export_ids(self.children)
}

///|
pub fn AccessibilityProjectionNode::role(
  self : AccessibilityProjectionNode,
) -> @accessibility.AccessibilityRole {
  self.role
}

///|
pub fn AccessibilityProjectionNode::name(
  self : AccessibilityProjectionNode,
) -> String {
  self.name
}

///|
pub fn AccessibilityProjectionNode::bounds(
  self : AccessibilityProjectionNode,
) -> @primitives.Rect {
  self.bounds
}

///|
pub fn AccessibilityProjectionNode::is_enabled(
  self : AccessibilityProjectionNode,
) -> Bool {
  self.enabled
}

///|
pub fn AccessibilityProjectionNode::is_loading(
  self : AccessibilityProjectionNode,
) -> Bool {
  self.loading
}

///|
pub fn AccessibilityProjectionNode::is_focused(
  self : AccessibilityProjectionNode,
) -> Bool {
  self.focused
}

///|
pub fn AccessibilityProjectionNode::supported_actions(
  self : AccessibilityProjectionNode,
) -> Array[@accessibility.AccessibilityAction] {
  copy_export_actions(self.actions)
}

///|
/// An immutable copied semantic tree for one committed source revision.
pub struct AccessibilityProjectionSnapshot {
  priv revision : UInt64
  priv nodes : Array[AccessibilityProjectionNode]
}

///|
pub fn AccessibilityProjectionSnapshot::revision(
  self : AccessibilityProjectionSnapshot,
) -> UInt64 {
  self.revision
}

///|
pub fn AccessibilityProjectionSnapshot::nodes(
  self : AccessibilityProjectionSnapshot,
) -> Array[AccessibilityProjectionNode] {
  copy_projection_nodes(self.nodes)
}

///|
priv struct AccessibilityExportEntry {
  export_id : AccessibilityExportId
  node_id : @accessibility.NodeId
}

///|
struct AccessibilityProjectionState {
  registry_owner : @accessibility.NodeId
  source_model : @accessibility.AccessibilityModel?
  source_revision : UInt64
  next_sequence : UInt64
  sequence_exhausted : Bool
  closed : Bool
  entries : Array[AccessibilityExportEntry]
  current : AccessibilityProjectionSnapshot
}

///|
/// A small copied-tree projection layer for the Ubuntu UI-owner thread. It
/// owns no native objects, transport, callbacks, or application effects. The
/// source model remains the authority for resolving every action at
/// consumption time; this `Ref`-backed registry is not thread-safe.
pub struct AccessibilityProjection {
  priv state : Ref[AccessibilityProjectionState]
}

///|
const PROJECTION_MAX_UINT64 : UInt64 = 0xffff_ffff_ffff_ffff

///|
fn empty_projection_snapshot(
  revision : UInt64,
) -> AccessibilityProjectionSnapshot {
  { revision, nodes: [], }
}

///|
/// Allocate a registry identity from the shared owner allocator. The anchor
/// model is closed immediately; its opaque node ID remains a unique token.
fn projection_registry_owner() -> Result[
  @accessibility.NodeId,
  AccessibilityProjectionError,
] {
  let anchor_model = match @accessibility.AccessibilityModel::new() {
    Ok(value) => value
    Err(error) => return Err(SourceError(error))
  }
  let bounds = @primitives.Rect::new(0.0, 0.0, 0.0, 0.0).unwrap()
  let anchor = match
    anchor_model.publish([
      @accessibility.NodeSpec::new(
        1UL,
        None,
        @accessibility.Window,
        "Ubuntu projection registry",
        bounds,
      ),
    ]) {
    Ok(snapshot) => snapshot.nodes()[0].id()
    Err(error) => {
      anchor_model.close()
      return Err(SourceError(error))
    }
  }
  anchor_model.close()
  Ok(anchor)
}

///|
/// Create a fresh registry with a unique opaque identity scope.
pub fn AccessibilityProjection::new() -> Result[
  AccessibilityProjection,
  AccessibilityProjectionError,
] {
  let registry_owner = match projection_registry_owner() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    state: Ref({
      registry_owner,
      source_model: None,
      source_revision: 0UL,
      next_sequence: 1UL,
      sequence_exhausted: false,
      closed: false,
      entries: [],
      current: empty_projection_snapshot(0UL),
    }),
  })
}

///|
fn find_export_entry_by_node_id(
  entries : Array[AccessibilityExportEntry],
  node_id : @accessibility.NodeId,
) -> Int {
  let mut index = 0
  while index < entries.length() {
    if entries[index].node_id == node_id {
      return index
    }
    index += 1
  }
  -1
}

///|
fn find_export_entry_by_export_id(
  entries : Array[AccessibilityExportEntry],
  export_id : AccessibilityExportId,
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
fn export_parent_id(
  entries : Array[AccessibilityExportEntry],
  parent : @accessibility.NodeId?,
) -> AccessibilityExportId? {
  match parent {
    None => None
    Some(node_id) => {
      let index = find_export_entry_by_node_id(entries, node_id)
      if index < 0 {
        None
      } else {
        Some(entries[index].export_id)
      }
    }
  }
}

///|
fn export_child_ids(
  entries : Array[AccessibilityExportEntry],
  children : Array[@accessibility.NodeId],
) -> Array[AccessibilityExportId] {
  let result : Array[AccessibilityExportId] = []
  for node_id in children {
    let index = find_export_entry_by_node_id(entries, node_id)
    if index >= 0 {
      result.push(entries[index].export_id)
    }
  }
  result
}

///|
fn copy_export_ids(
  ids : Array[AccessibilityExportId],
) -> Array[AccessibilityExportId] {
  let result : Array[AccessibilityExportId] = []
  for id in ids {
    result.push(id)
  }
  result
}

///|
fn copy_export_actions(
  actions : Array[@accessibility.AccessibilityAction],
) -> Array[@accessibility.AccessibilityAction] {
  let result : Array[@accessibility.AccessibilityAction] = []
  for action in actions {
    result.push(action)
  }
  result
}

///|
fn copy_projection_node(
  node : AccessibilityProjectionNode,
) -> AccessibilityProjectionNode {
  {
    ..node,
    children: copy_export_ids(node.children),
    actions: copy_export_actions(node.actions),
  }
}

///|
fn copy_projection_nodes(
  nodes : Array[AccessibilityProjectionNode],
) -> Array[AccessibilityProjectionNode] {
  let result : Array[AccessibilityProjectionNode] = []
  for node in nodes {
    result.push(copy_projection_node(node))
  }
  result
}

///|
fn projection_nodes_match_source(
  exported_entries : Array[AccessibilityExportEntry],
  source_nodes : Array[@accessibility.SemanticNode],
) -> Bool {
  if exported_entries.length() != source_nodes.length() {
    return false
  }
  let mut index = 0
  while index < source_nodes.length() {
    if exported_entries[index].node_id != source_nodes[index].id() {
      return false
    }
    index += 1
  }
  true
}

///|

///|
/// Copy a committed source tree into this registry. The supplied snapshot must
/// still be the live model snapshot. Existing export IDs are retained only
/// when the same full opaque source NodeId remains continuously present.
pub fn AccessibilityProjection::publish(
  self : AccessibilityProjection,
  model : @accessibility.AccessibilityModel,
  snapshot : @accessibility.AccessibilitySnapshot,
) -> Result[AccessibilityProjectionSnapshot, AccessibilityProjectionError] {
  let state = self.state.val
  if state.closed {
    return Err(ProjectionClosed)
  }
  if projection_invalidate_if_source_closed(self, state) {
    return Err(ProjectionClosed)
  }
  match state.source_model {
    Some(source_model) if !source_model.same_owner(model) =>
      return Err(ForeignOwner)
    _ => ()
  }
  if model.is_closed() {
    return Err(SourceClosed)
  }
  if !model.is_current_snapshot(snapshot) {
    return Err(StaleSnapshot)
  }

  let source_nodes = snapshot.nodes()
  let next_sequence = Ref(state.next_sequence)
  let sequence_exhausted = Ref(state.sequence_exhausted)
  let next_entries : Array[AccessibilityExportEntry] = []
  let mut failed = false
  let mut index = 0
  while index < source_nodes.length() && !failed {
    let source_node = source_nodes[index]
    let previous_index = find_export_entry_by_node_id(
      state.entries,
      source_node.id(),
    )
    let export_id = if previous_index >= 0 {
      state.entries[previous_index].export_id
    } else if sequence_exhausted.val {
      failed = true
      { registry_owner: state.registry_owner, sequence: 0UL, }
    } else {
      let sequence = next_sequence.val
      if sequence == PROJECTION_MAX_UINT64 {
        sequence_exhausted.val = true
      } else {
        next_sequence.val = sequence + 1UL
      }
      { registry_owner: state.registry_owner, sequence, }
    }
    if !failed {
      next_entries.push({ export_id, node_id: source_node.id(), })
    }
    index += 1
  }
  if failed {
    return Err(ExportIdentityExhausted)
  }

  let projected_nodes : Array[AccessibilityProjectionNode] = []
  index = 0
  while index < source_nodes.length() {
    let source_node = source_nodes[index]
    let entry_index = find_export_entry_by_node_id(
      next_entries,
      source_node.id(),
    )
    let entry = next_entries[entry_index]
    projected_nodes.push({
      id: entry.export_id,
      parent: export_parent_id(next_entries, source_node.parent()),
      children: export_child_ids(next_entries, source_node.children()),
      role: source_node.role(),
      name: source_node.name(),
      bounds: source_node.bounds(),
      enabled: source_node.is_enabled(),
      loading: source_node.is_loading(),
      focused: source_node.is_focused(),
      actions: source_node.supported_actions(),
    })
    index += 1
  }
  let current = { revision: snapshot.revision(), nodes: projected_nodes, }
  self.state.val = {
    ..state,
    source_model: Some(model),
    source_revision: snapshot.revision(),
    next_sequence: next_sequence.val,
    sequence_exhausted: sequence_exhausted.val,
    entries: next_entries,
    current,
  }
  Ok(current)
}

///|
fn projection_invalidate_if_source_closed(
  projection : AccessibilityProjection,
  state : AccessibilityProjectionState,
) -> Bool {
  match state.source_model {
    None => false
    Some(model) =>
      if model.is_closed() {
        projection.state.val = {
          ..state,
          source_model: None,
          closed: true,
          entries: [],
          current: empty_projection_snapshot(state.source_revision),
        }
        true
      } else {
        false
      }
  }
}

///|
fn projection_source_is_current(
  state : AccessibilityProjectionState,
  model : @accessibility.AccessibilityModel,
) -> Bool {
  let live = model.snapshot()
  live.revision() == state.source_revision &&
  projection_nodes_match_source(state.entries, live.nodes())
}

///|
/// Return the copied latest projection only while its source revision remains
/// current. Call `publish` after every successful source-model commit.
pub fn AccessibilityProjection::snapshot(
  self : AccessibilityProjection,
) -> Result[AccessibilityProjectionSnapshot, AccessibilityProjectionError] {
  let state = self.state.val
  if state.closed {
    return Err(ProjectionClosed)
  }
  match state.source_model {
    None => Ok(state.current)
    Some(model) =>
      if projection_invalidate_if_source_closed(self, state) {
        Err(ProjectionClosed)
      } else if projection_source_is_current(state, model) {
        Ok(state.current)
      } else {
        Err(StaleSnapshot)
      }
  }
}

///|
/// Resolve a copied export ID through the full source NodeId and the live
/// accessibility model. This returns an intent only; the app owner still
/// performs the corresponding domain effect.
pub fn AccessibilityProjection::resolve_action(
  self : AccessibilityProjection,
  export_id : AccessibilityExportId,
  action : @accessibility.AccessibilityAction,
) -> Result[@accessibility.ActionIntent, AccessibilityProjectionError] {
  let state = self.state.val
  if state.closed {
    return Err(ProjectionClosed)
  }
  let model = match state.source_model {
    None => return Err(StaleSnapshot)
    Some(value) => value
  }
  if projection_invalidate_if_source_closed(self, state) {
    return Err(ProjectionClosed)
  }
  if !projection_source_is_current(state, model) {
    return Err(StaleSnapshot)
  }
  let index = find_export_entry_by_export_id(state.entries, export_id)
  if index < 0 {
    return Err(ActionRejected(@accessibility.StaleNode))
  }
  let request = @accessibility.ActionRequest::new(
    state.entries[index].node_id,
    action,
  )
  match model.resolve_action(request) {
    Ok(intent) =>
      if intent.revision() == state.source_revision {
        Ok(intent)
      } else {
        Err(StaleSnapshot)
      }
    Err(@accessibility.ModelClosed) => {
      self.state.val = {
        ..state,
        source_model: None,
        closed: true,
        entries: [],
        current: empty_projection_snapshot(state.source_revision),
      }
      Err(ProjectionClosed)
    }
    Err(error) => Err(ActionRejected(error))
  }
}

///|
/// Revoke the export table. The application owner still closes the source
/// `AccessibilityModel` separately when its lifecycle ends.
pub fn AccessibilityProjection::close(self : AccessibilityProjection) -> Unit {
  let state = self.state.val
  if !state.closed {
    self.state.val = {
      ..state,
      source_model: None,
      closed: true,
      entries: [],
      current: empty_projection_snapshot(state.source_revision),
    }
  }
}
