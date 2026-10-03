///|
/// Errors from the platform-neutral element tree foundation.
pub enum ElementError {
  DuplicateId
  MissingParent
  InvalidPreorder
  UnknownElement
  NotFocusable
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
/// Headless element tree. Nodes are stored in stable pre-order and later nodes
/// are considered visually above earlier nodes during hit testing.
pub struct ElementTree {
  nodes : Array[ElementNode]
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
    None => { target: None, capture: [], bubble: [], }
    Some(target) =>
      match self.path_to_root(target) {
        Err(_) => { target: None, capture: [], bubble: [], }
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
