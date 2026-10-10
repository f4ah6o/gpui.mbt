///|
/// Stable semantic roles shared by platform accessibility projections.
/// Native mappings remain the responsibility of each platform adapter.
pub(all) enum AccessibilityRole {
  Window
  Group
  Button
  Link
  CheckBox
  RadioButton
  TextField
  StaticText
  List
  ListItem
  Slider
  ProgressIndicator
} derive(Eq)

///|
pub extend AccessibilityRole with Eq::{not_equal, equal}

///|
/// The first shared action slice. A platform adapter can request an Invoke;
/// the model validates it and returns an effect value without running code.
pub(all) enum AccessibilityAction {
  Invoke
} derive(Eq)

///|
pub extend AccessibilityAction with Eq::{not_equal, equal}

///|
/// Errors from a failed semantic-tree commit or model lifecycle operation.
pub(all) enum AccessibilityError {
  OwnerIdentityExhausted
  IdentityExhausted
  RevisionExhausted
  ModelClosed
  InvalidNodeKey
  DuplicateNodeKey
  RootRequired
  MultipleRoots
  MissingParent
  InvalidPreorder
  TreeTooDeep
  TooManyNodes
  NameTooLong
  SnapshotTextTooLong
  DuplicateAction
  TooManyActions
  MultipleFocusedNodes
  FocusedNodeDisabled
} derive(Eq)

///|
pub extend AccessibilityError with Eq::{not_equal, equal}

///|
/// A typed reason why a requested accessibility action was not accepted.
pub(all) enum ActionError {
  ForeignOwner
  StaleNode
  UnsupportedAction
  Disabled
  Loading
  ModelClosed
} derive(Eq)

///|
pub extend ActionError with Eq::{not_equal, equal}

///|
/// Opaque identity for one continuously-live semantic node.
///
/// `key` values supplied in `NodeSpec` are caller-owned lookup keys, not
/// generations. The model assigns a monotonically increasing generation to
/// every newly admitted node. IDs are scoped to one model owner and are never
/// reused after removal, reset, or re-admission.
pub struct NodeId {
  priv owner : UInt64
  priv key : UInt64
  priv generation : UInt64
} derive(Eq)

///|
pub extend NodeId with Eq::{not_equal, equal}

///|
/// Return the caller-supplied continuity key for mapping this semantic node to
/// an existing control. This value is not a generation and cannot be used to
/// resolve an action without the full opaque `NodeId`.
pub fn NodeId::key(self : NodeId) -> UInt64 {
  self.key
}

///|
/// A portable node description using a caller-owned key for continuity across
/// adjacent commits. Parent keys refer to an earlier ancestor in pre-order.
pub struct NodeSpec {
  priv key : UInt64
  priv parent_key : UInt64?
  priv role : AccessibilityRole
  priv name : String
  priv bounds : @primitives.Rect
  priv enabled : Bool
  priv loading : Bool
  priv focused : Bool
  priv actions : Array[AccessibilityAction]
}

///|
pub fn NodeSpec::new(
  key : UInt64,
  parent_key : UInt64?,
  role : AccessibilityRole,
  name : String,
  bounds : @primitives.Rect,
) -> NodeSpec {
  {
    key,
    parent_key,
    role,
    name,
    bounds,
    enabled: true,
    loading: false,
    focused: false,
    actions: [],
  }
}

///|
/// Whether the node is enabled for user actions. Disabling a focused node is
/// rejected when its containing snapshot is committed.
pub fn NodeSpec::with_enabled(self : NodeSpec, enabled : Bool) -> NodeSpec {
  { ..self, enabled, }
}

///|
/// Whether the control is processing work. Loading blocks Invoke while focus
/// may remain on the control.
pub fn NodeSpec::with_loading(self : NodeSpec, loading : Bool) -> NodeSpec {
  { ..self, loading, }
}

///|
/// Whether this node owns semantic focus in the committed snapshot.
pub fn NodeSpec::with_focused(self : NodeSpec, focused : Bool) -> NodeSpec {
  { ..self, focused, }
}

///|
/// Declare the actions this node supports. The current slice has one action,
/// so duplicate Invoke declarations are rejected and more than one entry is
/// outside this package's bounded contract.
pub fn NodeSpec::with_actions(
  self : NodeSpec,
  actions : Array[AccessibilityAction],
) -> Result[NodeSpec, AccessibilityError] {
  if actions.length() > max_actions_per_node {
    return Err(TooManyActions)
  }
  let copied = copy_actions(actions)
  let mut index = 0
  while index < copied.length() {
    let mut prior = 0
    while prior < index {
      if copied[prior] == copied[index] {
        return Err(DuplicateAction)
      }
      prior += 1
    }
    index += 1
  }
  Ok({ ..self, actions: copied, })
}

///|
/// One immutable semantic node in a committed snapshot.
pub struct SemanticNode {
  priv id : NodeId
  priv parent : NodeId?
  priv children : Array[NodeId]
  priv role : AccessibilityRole
  priv name : String
  priv bounds : @primitives.Rect
  priv enabled : Bool
  priv loading : Bool
  priv focused : Bool
  priv actions : Array[AccessibilityAction]
}

///|
pub fn SemanticNode::id(self : SemanticNode) -> NodeId {
  self.id
}

///|
pub fn SemanticNode::parent(self : SemanticNode) -> NodeId? {
  self.parent
}

///|
/// Return children in committed pre-order.
pub fn SemanticNode::children(self : SemanticNode) -> Array[NodeId] {
  copy_node_ids(self.children)
}

///|
pub fn SemanticNode::role(self : SemanticNode) -> AccessibilityRole {
  self.role
}

///|
pub fn SemanticNode::name(self : SemanticNode) -> String {
  self.name
}

///|
/// Bounds are in logical points and are copied from the caller's geometry.
pub fn SemanticNode::bounds(self : SemanticNode) -> @primitives.Rect {
  self.bounds
}

///|
pub fn SemanticNode::is_enabled(self : SemanticNode) -> Bool {
  self.enabled
}

///|
pub fn SemanticNode::is_loading(self : SemanticNode) -> Bool {
  self.loading
}

///|
pub fn SemanticNode::is_focused(self : SemanticNode) -> Bool {
  self.focused
}

///|
pub fn SemanticNode::supported_actions(
  self : SemanticNode,
) -> Array[AccessibilityAction] {
  copy_actions(self.actions)
}

///|
/// Immutable, copied semantic tree committed for one model revision.
pub struct AccessibilitySnapshot {
  priv owner : UInt64
  priv revision : UInt64
  priv nodes : Array[SemanticNode]
}

///|
pub fn AccessibilitySnapshot::revision(self : AccessibilitySnapshot) -> UInt64 {
  self.revision
}

///|
pub fn AccessibilitySnapshot::nodes(
  self : AccessibilitySnapshot,
) -> Array[SemanticNode] {
  copy_semantic_nodes(self.nodes)
}

///|
pub fn AccessibilitySnapshot::node(
  self : AccessibilitySnapshot,
  id : NodeId,
) -> SemanticNode? {
  if id.owner != self.owner {
    return None
  }
  let index = find_node_index_by_id(self.nodes, id)
  if index < 0 {
    None
  } else {
    Some(copy_semantic_node(self.nodes[index]))
  }
}

///|
/// A queued request is data only. Resolve it against the current model when it
/// is consumed; queuing a previously accepted `ActionIntent` is unsafe.
pub struct ActionRequest {
  priv node_id : NodeId
  priv action : AccessibilityAction
}

///|
pub fn ActionRequest::new(
  node_id : NodeId,
  action : AccessibilityAction,
) -> ActionRequest {
  { node_id, action, }
}

///|
/// A validated Invoke effect for immediate application-owner dispatch.
/// This value is not a one-shot token and does not execute user code.
pub struct ActionIntent {
  priv node_id : NodeId
  priv action : AccessibilityAction
  priv revision : UInt64
}

///|
pub fn ActionIntent::node_id(self : ActionIntent) -> NodeId {
  self.node_id
}

///|
pub fn ActionIntent::action(self : ActionIntent) -> AccessibilityAction {
  self.action
}

///|
pub fn ActionIntent::revision(self : ActionIntent) -> UInt64 {
  self.revision
}

///|
priv struct AccessibilityState {
  owner : UInt64
  revision : UInt64
  revision_exhausted : Bool
  next_generation : UInt64
  generation_exhausted : Bool
  closed : Bool
  current : AccessibilitySnapshot
}

///|
/// The live, single-owner semantic model. Copies of this handle share the same
/// revocable state. All methods are synchronous and intended for the UI-owner
/// thread; no native object or callback is stored here.
pub struct AccessibilityModel {
  priv state : Ref[AccessibilityState]
}

///|
/// Limits are part of the portable contract so adapters can size their own
/// bounded native maps without changing core semantics.
pub let max_node_count : Int = 4096

///|
pub let max_tree_depth : Int = 256

///|
pub let max_name_units : Int = 4096

///|
pub let max_snapshot_name_units : Int = 1_048_576

///|
pub let max_actions_per_node : Int = 1

///|
const MAX_UINT64 : UInt64 = 0xffff_ffff_ffff_ffff

///|
fn empty_snapshot(owner : UInt64, revision : UInt64) -> AccessibilitySnapshot {
  { owner, revision, nodes: [], }
}

///|
/// Owner identities are unique only within this target's allocator scope:
/// one linked native module image, or one non-native runtime instance. Do not
/// exchange IDs across worker or module instances, whose counters may overlap.
pub fn AccessibilityModel::new() -> Result[
  AccessibilityModel,
  AccessibilityError,
] {
  match next_owner_id() {
    None => Err(OwnerIdentityExhausted)
    Some(owner) => {
      let current = empty_snapshot(owner, 0UL)
      Ok({
        state: Ref({
          owner,
          revision: 0UL,
          revision_exhausted: false,
          next_generation: 1UL,
          generation_exhausted: false,
          closed: false,
          current,
        }),
      })
    }
  }
}

///|
/// Return the latest committed immutable snapshot. Reading an old snapshot
/// never grants authority to invoke actions on it.
pub fn AccessibilityModel::snapshot(
  self : AccessibilityModel,
) -> AccessibilitySnapshot {
  self.state.val.current
}

///|
/// Whether two model handles share one owner identity within the same target
/// allocator/runtime scope. This distinguishes a copied handle from another
/// live model even while both committed trees are empty, without exposing the
/// owner token itself. Do not compare handles crossing worker or module-instance
/// boundaries that do not share this allocator scope.
pub fn AccessibilityModel::same_owner(
  self : AccessibilityModel,
  other : AccessibilityModel,
) -> Bool {
  self.state.val.owner == other.state.val.owner
}

///|
/// Whether this model has been terminally closed. UI-owner-thread confined.
pub fn AccessibilityModel::is_closed(self : AccessibilityModel) -> Bool {
  self.state.val.closed
}

///|
/// Whether a copied snapshot belongs to this model and is still its latest
/// committed snapshot. Closed models return false even if the revision counter
/// is saturated.
pub fn AccessibilityModel::is_current_snapshot(
  self : AccessibilityModel,
  snapshot : AccessibilitySnapshot,
) -> Bool {
  let state = self.state.val
  !state.closed &&
  snapshot.owner == state.owner &&
  snapshot.revision == state.current.revision
}

///|
/// Validate and atomically publish a new complete tree. The model commits the
/// snapshot before returning it; an adapter may notify the operating system
/// only after this call returns. On error, the current snapshot and all
/// identity counters remain unchanged.
pub fn AccessibilityModel::publish(
  self : AccessibilityModel,
  specs : Array[NodeSpec],
) -> Result[AccessibilitySnapshot, AccessibilityError] {
  let state = self.state.val
  if state.closed {
    return Err(ModelClosed)
  }
  if specs.length() > max_node_count {
    return Err(TooManyNodes)
  }
  if state.revision_exhausted {
    return Err(RevisionExhausted)
  }
  let next_revision = state.revision + 1UL
  let revision_exhausted = next_revision == MAX_UINT64
  let copied_specs = copy_node_specs(specs)
  match validate_specs(copied_specs) {
    Err(error) => Err(error)
    Ok(_) => {
      let next_generation = Ref(state.next_generation)
      let generation_exhausted = Ref(state.generation_exhausted)
      let nodes : Array[SemanticNode] = []
      let mut failed : AccessibilityError? = None
      let mut index = 0
      while index < copied_specs.length() && failed is None {
        let spec = copied_specs[index]
        let current_index = find_node_index_by_key(
          state.current.nodes,
          spec.key,
        )
        let id = if current_index >= 0 {
          state.current.nodes[current_index].id
        } else {
          match allocate_generation(next_generation, generation_exhausted) {
            Some(generation) =>
              { owner: state.owner, key: spec.key, generation, }
            None => {
              failed = Some(IdentityExhausted)
              { owner: state.owner, key: spec.key, generation: 0UL, }
            }
          }
        }
        let parent = match spec.parent_key {
          None => None
          Some(parent_key) => {
            let parent_index = find_node_index_by_key(nodes, parent_key)
            if parent_index < 0 {
              failed = Some(InvalidPreorder)
              None
            } else {
              Some(nodes[parent_index].id)
            }
          }
        }
        if failed is None {
          nodes.push({
            id,
            parent,
            children: [],
            role: spec.role,
            name: spec.name,
            bounds: spec.bounds,
            enabled: spec.enabled,
            loading: spec.loading,
            focused: spec.focused,
            actions: copy_actions(spec.actions),
          })
        }
        index += 1
      }
      match failed {
        Some(error) => Err(error)
        None => {
          add_children_in_preorder(nodes)
          let snapshot = { owner: state.owner, revision: next_revision, nodes, }
          self.state.val = {
            ..state,
            revision: next_revision,
            revision_exhausted,
            next_generation: next_generation.val,
            generation_exhausted: generation_exhausted.val,
            current: snapshot,
          }
          Ok(snapshot)
        }
      }
    }
  }
}

///|
/// Empty the live tree while preserving the monotonic identity sequence.
/// Previously-issued IDs are stale even if the same caller keys are later
/// admitted again. Each reset advances the snapshot revision when possible.
pub fn AccessibilityModel::reset(
  self : AccessibilityModel,
) -> Result[AccessibilitySnapshot, AccessibilityError] {
  let state = self.state.val
  if state.closed {
    return Err(ModelClosed)
  }
  if state.revision_exhausted {
    return Err(RevisionExhausted)
  }
  let revision = state.revision + 1UL
  let revision_exhausted = revision == MAX_UINT64
  let current = empty_snapshot(state.owner, revision)
  self.state.val = { ..state, revision, revision_exhausted, current, }
  Ok(current)
}

///|
/// Revoke all copied model handles and clear their live tree. Closing is
/// idempotent. A closed model can never be revived or publish a new tree.
pub fn AccessibilityModel::close(self : AccessibilityModel) -> Unit {
  let state = self.state.val
  if !state.closed {
    let revision = if state.revision_exhausted {
      state.revision
    } else {
      state.revision + 1UL
    }
    let revision_exhausted = state.revision_exhausted || revision == MAX_UINT64
    let current = empty_snapshot(state.owner, revision)
    self.state.val = {
      ..state,
      revision,
      revision_exhausted,
      closed: true,
      current,
    }
  }
}

///|
/// Validate one request against the live current snapshot and return an
/// immediate effect value. For deferred/queued work, keep the `ActionRequest`
/// and call this method only when consuming it. The caller remains responsible
/// for routing the effect to its application-owned handler; no callback or
/// capability registry is duplicated here.
pub fn AccessibilityModel::resolve_action(
  self : AccessibilityModel,
  request : ActionRequest,
) -> Result[ActionIntent, ActionError] {
  let state = self.state.val
  if state.closed {
    return Err(ModelClosed)
  }
  if request.node_id.owner != state.owner {
    return Err(ForeignOwner)
  }
  let index = find_node_index_by_id(state.current.nodes, request.node_id)
  if index < 0 {
    return Err(StaleNode)
  }
  let node = state.current.nodes[index]
  let mut supported = false
  for action in node.actions {
    if action == request.action {
      supported = true
    }
  }
  if !supported {
    return Err(UnsupportedAction)
  }
  if !node.enabled {
    return Err(Disabled)
  }
  if node.loading {
    return Err(Loading)
  }
  Ok({
    node_id: request.node_id,
    action: request.action,
    revision: state.revision,
  })
}

///|
fn allocate_generation(
  next_generation : Ref[UInt64],
  generation_exhausted : Ref[Bool],
) -> UInt64? {
  if generation_exhausted.val {
    return None
  }
  let generation = next_generation.val
  if generation == MAX_UINT64 {
    generation_exhausted.val = true
  } else {
    next_generation.val = generation + 1UL
  }
  Some(generation)
}

///|
fn validate_specs(specs : Array[NodeSpec]) -> Result[Unit, AccessibilityError] {
  if specs.length() == 0 {
    return Err(RootRequired)
  }
  let mut roots = 0
  let mut focused = 0
  let mut total_name_units = 0
  let mut ancestors : Array[UInt64] = []
  let mut index = 0
  while index < specs.length() {
    let spec = specs[index]
    if spec.key == 0UL {
      return Err(InvalidNodeKey)
    }
    let mut prior = 0
    while prior < index {
      if specs[prior].key == spec.key {
        return Err(DuplicateNodeKey)
      }
      prior += 1
    }
    let name_units = spec.name.length()
    if name_units > max_name_units {
      return Err(NameTooLong)
    }
    total_name_units += name_units
    if total_name_units > max_snapshot_name_units {
      return Err(SnapshotTextTooLong)
    }
    if spec.focused {
      focused += 1
      if !spec.enabled {
        return Err(FocusedNodeDisabled)
      }
    }
    match spec.parent_key {
      None => {
        roots += 1
        if roots > 1 {
          return Err(MultipleRoots)
        }
        ancestors = [spec.key]
      }
      Some(parent_key) => {
        let mut parent_depth = -1
        let mut depth = 0
        while depth < ancestors.length() && parent_depth < 0 {
          if ancestors[depth] == parent_key {
            parent_depth = depth
          }
          depth += 1
        }
        if parent_depth < 0 {
          let mut parent_seen = false
          let mut prior = 0
          while prior < specs.length() && !parent_seen {
            if specs[prior].key == parent_key {
              parent_seen = true
            }
            prior += 1
          }
          if parent_seen {
            return Err(InvalidPreorder)
          }
          return Err(MissingParent)
        }
        if parent_depth + 2 > max_tree_depth {
          return Err(TreeTooDeep)
        }
        let next_ancestors : Array[UInt64] = []
        let mut depth = 0
        while depth <= parent_depth {
          next_ancestors.push(ancestors[depth])
          depth += 1
        }
        next_ancestors.push(spec.key)
        ancestors = next_ancestors
      }
    }
    index += 1
  }
  if roots == 0 {
    return Err(RootRequired)
  }
  if focused > 1 {
    return Err(MultipleFocusedNodes)
  }
  Ok(())
}

///|
fn add_children_in_preorder(nodes : Array[SemanticNode]) -> Unit {
  let mut index = 0
  while index < nodes.length() {
    match nodes[index].parent {
      None => ()
      Some(parent_id) => {
        let parent_index = find_node_index_by_id(nodes, parent_id)
        if parent_index >= 0 {
          let parent = nodes[parent_index]
          let children = copy_node_ids(parent.children)
          children.push(nodes[index].id)
          nodes[parent_index] = { ..parent, children, }
        }
      }
    }
    index += 1
  }
}

///|
fn find_node_index_by_key(nodes : Array[SemanticNode], key : UInt64) -> Int {
  let mut index = 0
  while index < nodes.length() {
    if nodes[index].id.key == key {
      return index
    }
    index += 1
  }
  -1
}

///|
fn find_node_index_by_id(nodes : Array[SemanticNode], id : NodeId) -> Int {
  let mut index = 0
  while index < nodes.length() {
    if nodes[index].id == id {
      return index
    }
    index += 1
  }
  -1
}

///|
fn copy_actions(
  actions : Array[AccessibilityAction],
) -> Array[AccessibilityAction] {
  let result : Array[AccessibilityAction] = []
  for action in actions {
    result.push(action)
  }
  result
}

///|
fn copy_node_ids(ids : Array[NodeId]) -> Array[NodeId] {
  let result : Array[NodeId] = []
  for id in ids {
    result.push(id)
  }
  result
}

///|
fn copy_semantic_node(node : SemanticNode) -> SemanticNode {
  {
    ..node,
    children: copy_node_ids(node.children),
    actions: copy_actions(node.actions),
  }
}

///|
fn copy_semantic_nodes(nodes : Array[SemanticNode]) -> Array[SemanticNode] {
  let result : Array[SemanticNode] = []
  for node in nodes {
    result.push(copy_semantic_node(node))
  }
  result
}

///|
fn copy_node_spec(spec : NodeSpec) -> NodeSpec {
  { ..spec, actions: copy_actions(spec.actions), }
}

///|
fn copy_node_specs(specs : Array[NodeSpec]) -> Array[NodeSpec] {
  let result : Array[NodeSpec] = []
  for spec in specs {
    result.push(copy_node_spec(spec))
  }
  result
}
