///|
/// Structural failures for the recursive flex-tree layer. Existing flex-line
/// numeric errors are preserved in the `Flex` variant.
pub(all) enum TreeLayoutError {
  DuplicateId
  MissingParent
  InvalidPreorder
  MissingContainer
  Flex(LayoutError)
  GeometryFailure
} derive(Eq)

///|
pub extend TreeLayoutError with Eq::{not_equal, equal}

///|
/// Container-only style for a recursive flex node. Its definite size is supplied
/// by the parent allocation, so descendants never carry an independent viewport.
pub struct FlexTreeStyle {
  direction : FlowDirection
  gap : Double
  padding : Insets
  border : Insets
  justify : JustifyContent
  align : AlignItems
}

///|
pub fn FlexTreeStyle::new(direction : FlowDirection) -> FlexTreeStyle {
  {
    direction,
    gap: 0.0,
    padding: Insets::zero(),
    border: Insets::zero(),
    justify: JustifyContent::start(),
    align: AlignItems::start(),
  }
}

///|
pub fn FlexTreeStyle::with_gap(
  self : FlexTreeStyle,
  gap : Double,
) -> Result[FlexTreeStyle, LayoutError] {
  let probe_size = match @primitives.Size::new(0.0, 0.0) {
    Ok(value) => value
    Err(_) => abort("zero size must remain valid")
  }
  match FlexContainer::new(self.direction, probe_size).with_gap(gap) {
    Err(error) => Err(error)
    Ok(_) =>
      Ok({
        direction: self.direction,
        gap,
        padding: self.padding,
        border: self.border,
        justify: self.justify,
        align: self.align,
      })
  }
}

///|
pub fn FlexTreeStyle::with_insets(
  self : FlexTreeStyle,
  padding : Insets,
  border : Insets,
) -> FlexTreeStyle {
  {
    direction: self.direction,
    gap: self.gap,
    padding,
    border,
    justify: self.justify,
    align: self.align,
  }
}

///|
pub fn FlexTreeStyle::with_justify(
  self : FlexTreeStyle,
  justify : JustifyContent,
) -> FlexTreeStyle {
  {
    direction: self.direction,
    gap: self.gap,
    padding: self.padding,
    border: self.border,
    justify,
    align: self.align,
  }
}

///|
pub fn FlexTreeStyle::with_align(
  self : FlexTreeStyle,
  align : AlignItems,
) -> FlexTreeStyle {
  {
    direction: self.direction,
    gap: self.gap,
    padding: self.padding,
    border: self.border,
    justify: self.justify,
    align,
  }
}

///|
/// One non-root node in a flat pre-order recursive layout tree. `item`
/// describes this node inside its parent; `children_style` describes the
/// container used for this node's direct children when present.
pub struct FlexTreeNode {
  item : FlexItem
  parent : UInt64
  children_style : FlexTreeStyle?
}

///|
pub fn FlexTreeNode::new(item : FlexItem, parent : UInt64) -> FlexTreeNode {
  { item, parent, children_style: None, }
}

///|
pub fn FlexTreeNode::with_children(
  self : FlexTreeNode,
  style : FlexTreeStyle,
) -> FlexTreeNode {
  { item: self.item, parent: self.parent, children_style: Some(style), }
}

///|
pub fn FlexTreeNode::id(self : FlexTreeNode) -> UInt64 {
  self.item.id()
}

///|
pub fn FlexTreeNode::parent(self : FlexTreeNode) -> UInt64 {
  self.parent
}

///|
/// Absolute result for one non-root node. Results are stored in stable pre-order.
pub struct TreeLayoutBox {
  id : UInt64
  bounds : @primitives.Rect
  overflow : Bool
}

///|
pub fn TreeLayoutBox::id(self : TreeLayoutBox) -> UInt64 {
  self.id
}

///|
pub fn TreeLayoutBox::bounds(self : TreeLayoutBox) -> @primitives.Rect {
  self.bounds
}

///|
pub fn TreeLayoutBox::overflow(self : TreeLayoutBox) -> Bool {
  self.overflow
}

///|
/// Recursive layout result. The root owns the definite viewport; `items`
/// contains every descendant in stable pre-order with absolute coordinates.
pub struct FlexTreeLayout {
  root_id : UInt64
  root_bounds : @primitives.Rect
  items : Array[TreeLayoutBox]
  overflow : Bool
}

///|
pub fn FlexTreeLayout::root_id(self : FlexTreeLayout) -> UInt64 {
  self.root_id
}

///|
pub fn FlexTreeLayout::root_bounds(self : FlexTreeLayout) -> @primitives.Rect {
  self.root_bounds
}

///|
pub fn FlexTreeLayout::items(self : FlexTreeLayout) -> Array[TreeLayoutBox] {
  copy_tree_boxes(self.items)
}

///|
pub fn FlexTreeLayout::overflow(self : FlexTreeLayout) -> Bool {
  self.overflow
}

///|
/// Recursively lay out a flat pre-order tree. The root viewport is definite;
/// descendants may use auto dimensions through their intrinsic sizes, and any
/// node with children must opt into a `FlexTreeStyle`.
pub fn layout_flex_tree(
  root_id : UInt64,
  root_size : @primitives.Size,
  root_style : FlexTreeStyle,
  nodes : Array[FlexTreeNode],
) -> Result[FlexTreeLayout, TreeLayoutError] {
  match validate_tree_preorder(root_id, nodes) {
    Err(error) => Err(error)
    Ok(_) =>
      match
        @primitives.Rect::new(0.0, 0.0, root_size.width(), root_size.height()) {
        Err(_) => Err(GeometryFailure)
        Ok(root_bounds) => {
          let output : Array[TreeLayoutBox] = []
          let overflow = Ref(false)
          match
            layout_tree_children(
              root_id, root_bounds, root_style, nodes, output, overflow,
            ) {
            Err(error) => Err(error)
            Ok(_) =>
              Ok({
                root_id,
                root_bounds,
                items: output,
                overflow: overflow.val,
              })
          }
        }
      }
  }
}

///|
fn layout_tree_children(
  parent_id : UInt64,
  parent_bounds : @primitives.Rect,
  style : FlexTreeStyle,
  nodes : Array[FlexTreeNode],
  output : Array[TreeLayoutBox],
  overflow : Ref[Bool],
) -> Result[Unit, TreeLayoutError] {
  let direct_nodes : Array[FlexTreeNode] = []
  let direct_items : Array[FlexItem] = []
  for node in nodes {
    if node.parent == parent_id {
      direct_nodes.push(node)
      direct_items.push(node.item)
    }
  }
  if direct_nodes.length() == 0 {
    Ok(())
  } else {
    let base = FlexContainer::new(style.direction, parent_bounds.size())
      .with_insets(style.padding, style.border)
      .with_justify(style.justify)
      .with_align(style.align)
    match base.with_gap(style.gap) {
      Err(error) => Err(Flex(error))
      Ok(container) =>
        match layout_flex(container, direct_items) {
          Err(error) => Err(Flex(error))
          Ok(line) => {
            if line.overflow() {
              overflow.val = true
            }
            let local_boxes = line.items()
            let mut failure : TreeLayoutError? = None
            let mut index = 0
            while index < direct_nodes.length() && failure is None {
              let node = direct_nodes[index]
              let local = local_boxes[index]
              let local_bounds = local.bounds()
              match
                @primitives.Rect::new(
                  parent_bounds.left() + local_bounds.left(),
                  parent_bounds.top() + local_bounds.top(),
                  local_bounds.size().width(),
                  local_bounds.size().height(),
                ) {
                Err(_) => failure = Some(GeometryFailure)
                Ok(bounds) => {
                  if local.overflow() {
                    overflow.val = true
                  }
                  output.push({
                    id: node.id(),
                    bounds,
                    overflow: local.overflow(),
                  })
                  let has_children = tree_has_direct_children(node.id(), nodes)
                  if has_children {
                    match node.children_style {
                      None => failure = Some(MissingContainer)
                      Some(child_style) =>
                        match
                          layout_tree_children(
                            node.id(),
                            bounds,
                            child_style,
                            nodes,
                            output,
                            overflow,
                          ) {
                          Err(error) => failure = Some(error)
                          Ok(_) => ()
                        }
                    }
                  }
                }
              }
              index += 1
            }
            match failure {
              Some(error) => Err(error)
              None => Ok(())
            }
          }
        }
    }
  }
}

///|
fn validate_tree_preorder(
  root_id : UInt64,
  nodes : Array[FlexTreeNode],
) -> Result[Unit, TreeLayoutError] {
  let seen : Array[UInt64] = [root_id]
  let mut ancestors : Array[UInt64] = [root_id]
  let mut failure : TreeLayoutError? = None
  let mut index = 0
  while index < nodes.length() && failure is None {
    let node = nodes[index]
    let id = node.id()
    let mut duplicate = false
    let mut seen_index = 0
    while seen_index < seen.length() && !duplicate {
      if seen[seen_index] == id {
        duplicate = true
      }
      seen_index += 1
    }
    if duplicate {
      failure = Some(DuplicateId)
    } else {
      let mut parent_depth = -1
      let mut ancestor_index = ancestors.length()
      while ancestor_index > 0 && parent_depth < 0 {
        ancestor_index -= 1
        if ancestors[ancestor_index] == node.parent {
          parent_depth = ancestor_index
        }
      }
      if parent_depth < 0 {
        let mut parent_seen = false
        seen_index = 0
        while seen_index < seen.length() && !parent_seen {
          if seen[seen_index] == node.parent {
            parent_seen = true
          }
          seen_index += 1
        }
        failure = if parent_seen {
          Some(InvalidPreorder)
        } else {
          Some(MissingParent)
        }
      } else {
        let next : Array[UInt64] = []
        let mut depth = 0
        while depth <= parent_depth {
          next.push(ancestors[depth])
          depth += 1
        }
        next.push(id)
        ancestors = next
        seen.push(id)
      }
    }
    index += 1
  }
  match failure {
    Some(error) => Err(error)
    None => Ok(())
  }
}

///|
fn tree_has_direct_children(id : UInt64, nodes : Array[FlexTreeNode]) -> Bool {
  let mut found = false
  let mut index = 0
  while index < nodes.length() && !found {
    if nodes[index].parent == id {
      found = true
    }
    index += 1
  }
  found
}

///|
fn copy_tree_boxes(values : Array[TreeLayoutBox]) -> Array[TreeLayoutBox] {
  let copy : Array[TreeLayoutBox] = []
  for value in values {
    copy.push(value)
  }
  copy
}
