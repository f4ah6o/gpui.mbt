///|
/// Errors from the platform-neutral element tree foundation.
pub enum ElementError {
  DuplicateId
  MissingParent
  InvalidPreorder
  UnknownElement
  NotFocusable
  RootRequired
  InvalidChildRoot
  MissingLayoutItem
  TreeTooDeep
  LayoutFailure(@layout.TreeLayoutError)
  GeometryFailure
} derive(Eq)

///|
pub extend ElementError with Eq::{not_equal, equal}

///|
/// One flat pre-order element record. Parent subtrees must remain contiguous:
/// children may only attach to an ancestor in the currently open traversal path.
/// This makes the tree acyclic by construction and keeps traversal stable.
pub struct ElementNode {
  id : UInt64
  parent : UInt64?
  bounds : @primitives.Rect
  focusable : Bool
  pointer_events : Bool
  background : @primitives.Color?
}

///|
pub fn ElementNode::new(
  id : UInt64,
  parent : UInt64?,
  bounds : @primitives.Rect,
) -> ElementNode {
  {
    id,
    parent,
    bounds,
    focusable: false,
    pointer_events: true,
    background: None,
  }
}

///|
/// Bridge the current M2 flex-line output into the element tree without
/// exposing layout internals above this package boundary.
pub fn ElementNode::from_layout_box(
  item : @layout.LayoutBox,
  parent : UInt64?,
) -> ElementNode {
  ElementNode::new(item.id(), parent, item.bounds())
}

///|
pub fn ElementNode::id(self : ElementNode) -> UInt64 {
  self.id
}

///|
pub fn ElementNode::parent(self : ElementNode) -> UInt64? {
  self.parent
}

///|
pub fn ElementNode::bounds(self : ElementNode) -> @primitives.Rect {
  self.bounds
}

///|
pub fn ElementNode::is_focusable(self : ElementNode) -> Bool {
  self.focusable
}

///|
pub fn ElementNode::accepts_pointer_events(self : ElementNode) -> Bool {
  self.pointer_events
}

///|
pub fn ElementNode::background(self : ElementNode) -> @primitives.Color? {
  self.background
}

///|
pub fn ElementNode::with_focusable(
  self : ElementNode,
  focusable : Bool,
) -> ElementNode {
  {
    id: self.id,
    parent: self.parent,
    bounds: self.bounds,
    focusable,
    pointer_events: self.pointer_events,
    background: self.background,
  }
}

///|
pub fn ElementNode::with_pointer_events(
  self : ElementNode,
  enabled : Bool,
) -> ElementNode {
  {
    id: self.id,
    parent: self.parent,
    bounds: self.bounds,
    focusable: self.focusable,
    pointer_events: enabled,
    background: self.background,
  }
}

///|
pub fn ElementNode::with_background(
  self : ElementNode,
  color : @primitives.Color?,
) -> ElementNode {
  {
    id: self.id,
    parent: self.parent,
    bounds: self.bounds,
    focusable: self.focusable,
    pointer_events: self.pointer_events,
    background: color,
  }
}

///|
/// A deterministic event route. Capture is root-to-target; bubble is
/// target-to-root. The target is absent when hit testing finds no live node.
pub struct DispatchPlan {
  target : UInt64?
  capture : Array[UInt64]
  bubble : Array[UInt64]
}

///|
pub fn DispatchPlan::target(self : DispatchPlan) -> UInt64? {
  self.target
}

///|
pub fn DispatchPlan::capture(self : DispatchPlan) -> Array[UInt64] {
  copy_ids(self.capture)
}

///|
pub fn DispatchPlan::bubble(self : DispatchPlan) -> Array[UInt64] {
  copy_ids(self.bubble)
}

///|
/// Event phase for deterministic element-tree dispatch.
pub(all) enum EventPhase {
  Capture
  Bubble
} derive(Eq)

///|
pub extend EventPhase with Eq::{not_equal, equal}

///|
/// Per-callback dispatch context. The stopped flag is shared across the
/// complete dispatch so a capture callback can prevent later callbacks.
pub struct DispatchContext {
  target : UInt64
  current_target : UInt64
  phase : EventPhase
  stopped : Ref[Bool]
}

///|
pub fn DispatchContext::target(self : DispatchContext) -> UInt64 {
  self.target
}

///|
pub fn DispatchContext::current_target(self : DispatchContext) -> UInt64 {
  self.current_target
}

///|
pub fn DispatchContext::phase(self : DispatchContext) -> EventPhase {
  self.phase
}

///|
pub fn DispatchContext::stop_propagation(self : DispatchContext) -> Unit {
  self.stopped.val = true
}

///|
pub fn DispatchContext::is_propagation_stopped(self : DispatchContext) -> Bool {
  self.stopped.val
}

///|
/// Observable result of callback dispatch. The visited arrays contain only
/// callbacks that actually ran.
pub struct DispatchOutcome {
  target : UInt64?
  capture_visited : Array[UInt64]
  bubble_visited : Array[UInt64]
  stopped : Bool
}

///|
pub fn DispatchOutcome::target(self : DispatchOutcome) -> UInt64? {
  self.target
}

///|
pub fn DispatchOutcome::capture_visited(
  self : DispatchOutcome,
) -> Array[UInt64] {
  copy_ids(self.capture_visited)
}

///|
pub fn DispatchOutcome::bubble_visited(self : DispatchOutcome) -> Array[UInt64] {
  copy_ids(self.bubble_visited)
}

///|
pub fn DispatchOutcome::was_stopped(self : DispatchOutcome) -> Bool {
  self.stopped
}

///|
/// Headless element tree. Nodes are stored in stable pre-order and later nodes
/// are considered visually above earlier nodes during hit testing.
pub struct ElementTree {
  priv nodes : Array[ElementNode]
  focused : UInt64?
}

///|
pub fn ElementTree::new(
  nodes : Array[ElementNode],
) -> Result[ElementTree, ElementError] {
  let owned = copy_nodes(nodes)
  let mut failure : ElementError? = None
  let mut ancestors : Array[UInt64] = []
  let mut index = 0
  while index < owned.length() && failure is None {
    let node = owned[index]
    let mut prior = 0
    let mut duplicate = false
    while prior < index && !duplicate {
      if owned[prior].id == node.id {
        duplicate = true
      }
      prior += 1
    }
    if duplicate {
      failure = Some(DuplicateId)
    } else {
      match node.parent {
        None => ancestors = [node.id]
        Some(parent_id) => {
          let mut ancestor_index = ancestors.length()
          let mut parent_depth = -1
          while ancestor_index > 0 && parent_depth < 0 {
            ancestor_index -= 1
            if ancestors[ancestor_index] == parent_id {
              parent_depth = ancestor_index
            }
          }
          if parent_depth < 0 {
            let mut parent_seen = false
            let mut prior = 0
            while prior < index && !parent_seen {
              if owned[prior].id == parent_id {
                parent_seen = true
              }
              prior += 1
            }
            if parent_seen {
              failure = Some(InvalidPreorder)
            } else {
              failure = Some(MissingParent)
            }
          } else {
            let next_ancestors : Array[UInt64] = []
            let mut depth = 0
            while depth <= parent_depth {
              next_ancestors.push(ancestors[depth])
              depth += 1
            }
            next_ancestors.push(node.id)
            ancestors = next_ancestors
          }
        }
      }
    }
    index += 1
  }
  match failure {
    Some(error) => Err(error)
    None => Ok({ nodes: owned, focused: None, })
  }
}

///|
pub fn ElementTree::nodes(self : ElementTree) -> Array[ElementNode] {
  copy_nodes(self.nodes)
}

///|
pub fn ElementTree::focused(self : ElementTree) -> UInt64? {
  self.focused
}

///|
pub fn ElementTree::node(self : ElementTree, id : UInt64) -> ElementNode? {
  let mut found : ElementNode? = None
  let mut index = 0
  while index < self.nodes.length() && found is None {
    if self.nodes[index].id == id {
      found = Some(self.nodes[index])
    }
    index += 1
  }
  found
}

///|
/// Hit test in reverse paint/pre-order. This is deterministic and intentionally
/// independent of platform pointer-event types.
pub fn ElementTree::hit_test(
  self : ElementTree,
  position : @primitives.Point,
) -> UInt64? {
  let mut hit : UInt64? = None
  let mut index = self.nodes.length()
  while index > 0 && hit is None {
    index -= 1
    let node = self.nodes[index]
    if node.pointer_events && node.bounds.contains(position) {
      hit = Some(node.id)
    }
  }
  hit
}

///|
pub fn ElementTree::path_to_root(
  self : ElementTree,
  id : UInt64,
) -> Result[Array[UInt64], ElementError] {
  if self.node(id) is None {
    Err(UnknownElement)
  } else {
    let reversed : Array[UInt64] = []
    let mut current : UInt64? = Some(id)
    let mut failure : ElementError? = None
    while current is Some(_) && failure is None {
      match current {
        None => ()
        Some(current_id) =>
          match self.node(current_id) {
            None => failure = Some(UnknownElement)
            Some(node) => {
              reversed.push(current_id)
              current = node.parent
            }
          }
      }
    }
    match failure {
      Some(error) => Err(error)
      None => {
        let path : Array[UInt64] = []
        let mut index = reversed.length()
        while index > 0 {
          index -= 1
          path.push(reversed[index])
        }
        Ok(path)
      }
    }
  }
}

///|
/// Produce capture/bubble metadata for a pointer position. Dispatch callbacks
/// and stop-propagation state sit above this deterministic routing primitive.
pub fn ElementTree::dispatch_pointer(
  self : ElementTree,
  position : @primitives.Point,
) -> DispatchPlan {
  match self.hit_test(position) {
    None => empty_dispatch_plan()
    Some(target) => self.dispatch_target(target)
  }
}

///|
/// Dispatch pointer callbacks in capture order followed by bubble order.
/// Returning an error aborts dispatch. Stopping propagation prevents every
/// later callback in both phases.
pub fn ElementTree::dispatch_pointer_with(
  self : ElementTree,
  position : @primitives.Point,
  callback : (DispatchContext) -> Result[Unit, ElementError],
) -> Result[DispatchOutcome, ElementError] {
  let plan = self.dispatch_pointer(position)
  execute_dispatch_plan(plan, callback)
}

///|
/// Route pointer input by position and keyboard/text input to the currently
/// focused focusable node. This selects a route only; it does not acquire or
/// move focus, synthesize text, or interpret key semantics.
pub fn ElementTree::dispatch_input(
  self : ElementTree,
  event : @primitives.InputEvent,
) -> DispatchPlan {
  match event {
    @primitives.PointerMoved(position~) => self.dispatch_pointer(position)
    @primitives.PointerButtonPressed(position~, ..) =>
      self.dispatch_pointer(position)
    @primitives.PointerButtonReleased(position~, ..) =>
      self.dispatch_pointer(position)
    @primitives.Scroll(position~, ..) => self.dispatch_pointer(position)
    @primitives.KeyPressed(..) => self.dispatch_focused()
    @primitives.KeyReleased(..) => self.dispatch_focused()
    @primitives.TextInput(..) => self.dispatch_focused()
  }
}

///|
/// Dispatch any input event with its original value alongside each callback
/// context. The route and event are fixed before callbacks begin.
pub fn ElementTree::dispatch_input_with(
  self : ElementTree,
  event : @primitives.InputEvent,
  callback : (DispatchContext, @primitives.InputEvent) -> Result[
    Unit,
    ElementError,
  ],
) -> Result[DispatchOutcome, ElementError] {
  let plan = self.dispatch_input(event)
  execute_dispatch_plan(plan, context => callback(context, event))
}

///|
fn ElementTree::dispatch_focused(self : ElementTree) -> DispatchPlan {
  match self.focused {
    None => empty_dispatch_plan()
    Some(target) => self.dispatch_target(target)
  }
}

///|
fn ElementTree::dispatch_target(
  self : ElementTree,
  target : UInt64,
) -> DispatchPlan {
  match self.path_to_root(target) {
    Err(_) => empty_dispatch_plan()
    Ok(capture) => {
      let bubble : Array[UInt64] = []
      let mut index = capture.length()
      while index > 0 {
        index -= 1
        bubble.push(capture[index])
      }
      { target: Some(target), capture, bubble, }
    }
  }
}

///|
fn empty_dispatch_plan() -> DispatchPlan {
  { target: None, capture: [], bubble: [], }
}

///|
fn execute_dispatch_plan(
  plan : DispatchPlan,
  callback : (DispatchContext) -> Result[Unit, ElementError],
) -> Result[DispatchOutcome, ElementError] {
  match plan.target() {
    None =>
      Ok({
        target: None,
        capture_visited: [],
        bubble_visited: [],
        stopped: false,
      })
    Some(target) => {
      let stopped = Ref(false)
      let capture_visited : Array[UInt64] = []
      let bubble_visited : Array[UInt64] = []
      let capture = plan.capture()
      let bubble = plan.bubble()
      let mut failure : ElementError? = None
      let mut index = 0
      while index < capture.length() && failure is None && !stopped.val {
        let current_target = capture[index]
        capture_visited.push(current_target)
        let context : DispatchContext = {
          target,
          current_target,
          phase: Capture,
          stopped,
        }
        match callback(context) {
          Ok(_) => ()
          Err(error) => failure = Some(error)
        }
        index += 1
      }
      index = 0
      while index < bubble.length() && failure is None && !stopped.val {
        let current_target = bubble[index]
        bubble_visited.push(current_target)
        let context : DispatchContext = {
          target,
          current_target,
          phase: Bubble,
          stopped,
        }
        match callback(context) {
          Ok(_) => ()
          Err(error) => failure = Some(error)
        }
        index += 1
      }
      match failure {
        Some(error) => Err(error)
        None =>
          Ok({
            target: Some(target),
            capture_visited,
            bubble_visited,
            stopped: stopped.val,
          })
      }
    }
  }
}

///|
pub fn ElementTree::with_focus(
  self : ElementTree,
  id : UInt64,
) -> Result[ElementTree, ElementError] {
  match self.node(id) {
    None => Err(UnknownElement)
    Some(node) =>
      if !node.focusable {
        Err(NotFocusable)
      } else {
        Ok({ nodes: self.nodes, focused: Some(id), })
      }
  }
}

///|
/// Remove one live node and its complete contiguous subtree. Focus is cleared
/// when the focused node is removed; focus outside the removed subtree is
/// preserved. The returned tree owns a new node array and preserves preorder.
pub fn ElementTree::without_subtree(
  self : ElementTree,
  id : UInt64,
) -> Result[ElementTree, ElementError] {
  if self.node(id) is None {
    Err(UnknownElement)
  } else {
    let removed : Array[UInt64] = []
    let kept : Array[ElementNode] = []
    for node in self.nodes {
      let mut remove = node.id == id
      match node.parent {
        None => ()
        Some(parent_id) => {
          let mut index = 0
          while index < removed.length() && !remove {
            if removed[index] == parent_id {
              remove = true
            }
            index += 1
          }
        }
      }
      if remove {
        removed.push(node.id)
      } else {
        kept.push(node)
      }
    }
    let mut focused = self.focused
    match focused {
      None => ()
      Some(focused_id) => {
        let mut index = 0
        while index < removed.length() && focused is Some(_) {
          if removed[index] == focused_id {
            focused = None
          }
          index += 1
        }
      }
    }
    Ok({ nodes: kept, focused, })
  }
}

///|
pub fn ElementTree::clear_focus(self : ElementTree) -> ElementTree {
  { nodes: self.nodes, focused: None, }
}

///|
/// Emit the deterministic headless scene for the currently supported element
/// paint surface. Only background quads are emitted in this first slice.
pub fn ElementTree::to_scene(self : ElementTree) -> @scene.Scene {
  let commands : Array[@scene.PaintCommand] = []
  for node in self.nodes {
    match node.background {
      None => ()
      Some(color) =>
        commands.push(@scene.PaintCommand::quad(node.id, node.bounds, color))
    }
  }
  @scene.Scene::new(commands)
}

///|
fn copy_nodes(nodes : Array[ElementNode]) -> Array[ElementNode] {
  let owned : Array[ElementNode] = []
  for node in nodes {
    owned.push(node)
  }
  owned
}

///|
fn copy_ids(ids : Array[UInt64]) -> Array[UInt64] {
  let owned : Array[UInt64] = []
  for id in ids {
    owned.push(id)
  }
  owned
}
