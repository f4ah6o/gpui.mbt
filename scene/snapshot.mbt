///|
/// Schema version for the first platform-neutral scene snapshot envelope.
pub const SCENE_SNAPSHOT_SCHEMA_VERSION : Int = 1

///|
/// Snapshot construction errors that are specific to the versioned envelope.
pub enum SnapshotError {
  InvalidScale
  InvalidOpacity
  NonFiniteTransform
  UnknownClipChain
  DuplicateClipChain
} derive(Eq)

///|
pub extend SnapshotError with Eq::{not_equal, equal}

///|
/// Finite 2D affine transform represented in logical coordinates.
pub struct AffineTransform {
  a : Double
  b : Double
  c : Double
  d : Double
  tx : Double
  ty : Double
}

///|
pub fn AffineTransform::identity() -> AffineTransform {
  { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0, }
}

///|
pub fn AffineTransform::new(
  a : Double,
  b : Double,
  c : Double,
  d : Double,
  tx : Double,
  ty : Double,
) -> Result[AffineTransform, SnapshotError] {
  if !snapshot_finite(a) ||
    !snapshot_finite(b) ||
    !snapshot_finite(c) ||
    !snapshot_finite(d) ||
    !snapshot_finite(tx) ||
    !snapshot_finite(ty) {
    Err(NonFiniteTransform)
  } else {
    Ok({ a, b, c, d, tx, ty, })
  }
}

///|
pub fn AffineTransform::a(self : AffineTransform) -> Double {
  self.a
}

///|
pub fn AffineTransform::b(self : AffineTransform) -> Double {
  self.b
}

///|
pub fn AffineTransform::c(self : AffineTransform) -> Double {
  self.c
}

///|
pub fn AffineTransform::d(self : AffineTransform) -> Double {
  self.d
}

///|
pub fn AffineTransform::tx(self : AffineTransform) -> Double {
  self.tx
}

///|
pub fn AffineTransform::ty(self : AffineTransform) -> Double {
  self.ty
}

///|
/// Logical resource-table entry. R0 currently emits no resources because the
/// implemented paint surface is quad-only; the table is present so image/text
/// resources can be added without changing the snapshot envelope.
pub struct SceneResource {
  id : UInt64
}

///|
pub fn SceneResource::new(id : UInt64) -> SceneResource {
  { id, }
}

///|
pub fn SceneResource::id(self : SceneResource) -> UInt64 {
  self.id
}

///|
/// One ordered rectangle-only clip chain in the current R0 subset.
pub struct ClipChain {
  id : Int
  rects : Array[@primitives.Rect]
}

///|
pub fn ClipChain::new(id : Int, rects : Array[@primitives.Rect]) -> ClipChain {
  { id, rects: copy_snapshot_rects(rects), }
}

///|
pub fn ClipChain::id(self : ClipChain) -> Int {
  self.id
}

///|
pub fn ClipChain::rects(self : ClipChain) -> Array[@primitives.Rect] {
  copy_snapshot_rects(self.rects)
}

///|
/// Flat ordered scene item. The first v1 subset contains quads only; future
/// path/image/text variants extend this enum while preserving the envelope.
pub(all) enum SceneItem {
  QuadItem(
    id~ : UInt64,
    bounds~ : @primitives.Rect,
    color~ : @primitives.Color,
    transform~ : AffineTransform,
    opacity~ : Double,
    clip_chain_id~ : Int?
  )
}

///|
pub fn SceneItem::quad(
  id : UInt64,
  bounds : @primitives.Rect,
  color : @primitives.Color,
  transform : AffineTransform,
  opacity : Double,
  clip_chain_id : Int?,
) -> Result[SceneItem, SnapshotError] {
  if !snapshot_finite(opacity) || opacity < 0.0 || opacity > 1.0 {
    Err(InvalidOpacity)
  } else {
    Ok(QuadItem(id~, bounds~, color~, transform~, opacity~, clip_chain_id~))
  }
}

///|
pub fn SceneItem::id(self : SceneItem) -> UInt64 {
  match self {
    QuadItem(id~, ..) => id
  }
}

///|
pub fn SceneItem::clip_chain_id(self : SceneItem) -> Int? {
  match self {
    QuadItem(clip_chain_id~, ..) => clip_chain_id
  }
}

///|
/// Versioned, platform-neutral scene snapshot. Arrays are copied on ingress and
/// egress so snapshots remain immutable-by-contract.
pub struct SceneSnapshot {
  schema_version : Int
  viewport : @primitives.Rect
  scale : Double
  resources : Array[SceneResource]
  clip_chains : Array[ClipChain]
  items : Array[SceneItem]
}

///|
pub fn SceneSnapshot::new(
  viewport : @primitives.Rect,
  scale : Double,
  resources : Array[SceneResource],
  clip_chains : Array[ClipChain],
  items : Array[SceneItem],
) -> Result[SceneSnapshot, SnapshotError] {
  if !snapshot_finite(scale) || scale <= 0.0 {
    Err(InvalidScale)
  } else if snapshot_has_duplicate_clip_ids(clip_chains) {
    Err(DuplicateClipChain)
  } else {
    match snapshot_validate_items(items, clip_chains) {
      Err(error) => Err(error)
      Ok(_) =>
        Ok({
          schema_version: SCENE_SNAPSHOT_SCHEMA_VERSION,
          viewport,
          scale,
          resources: copy_snapshot_resources(resources),
          clip_chains: copy_snapshot_clip_chains(clip_chains),
          items: copy_snapshot_items(items),
        })
    }
  }
}

///|
fn snapshot_validate_items(
  items : Array[SceneItem],
  chains : Array[ClipChain],
) -> Result[Unit, SnapshotError] {
  let mut failure : SnapshotError? = None
  let mut item_index = 0
  while item_index < items.length() && failure is None {
    match items[item_index] {
      QuadItem(transform~, opacity~, clip_chain_id~, ..) => {
        if !snapshot_finite(opacity) || opacity < 0.0 || opacity > 1.0 {
          failure = Some(InvalidOpacity)
        } else if !snapshot_transform_finite(transform) {
          failure = Some(NonFiniteTransform)
        } else {
          match clip_chain_id {
            None => ()
            Some(id) =>
              if !snapshot_has_clip_chain(id, chains) {
                failure = Some(UnknownClipChain)
              }
          }
        }
      }
    }
    item_index += 1
  }
  match failure {
    Some(error) => Err(error)
    None => Ok(())
  }
}

///|
fn snapshot_transform_finite(transform : AffineTransform) -> Bool {
  snapshot_finite(transform.a()) &&
  snapshot_finite(transform.b()) &&
  snapshot_finite(transform.c()) &&
  snapshot_finite(transform.d()) &&
  snapshot_finite(transform.tx()) &&
  snapshot_finite(transform.ty())
}

///|
fn snapshot_has_clip_chain(id : Int, chains : Array[ClipChain]) -> Bool {
  let mut found = false
  let mut chain_index = 0
  while chain_index < chains.length() && !found {
    if chains[chain_index].id() == id {
      found = true
    }
    chain_index += 1
  }
  found
}

///|
    Ok({
      schema_version: SCENE_SNAPSHOT_SCHEMA_VERSION,
      viewport,
      scale,
      resources: copy_snapshot_resources(resources),
      clip_chains: copy_snapshot_clip_chains(clip_chains),
      items: copy_snapshot_items(items),
    })
  }
}

///|
pub fn SceneSnapshot::schema_version(self : SceneSnapshot) -> Int {
  self.schema_version
}

///|
pub fn SceneSnapshot::viewport(self : SceneSnapshot) -> @primitives.Rect {
  self.viewport
}

///|
pub fn SceneSnapshot::scale(self : SceneSnapshot) -> Double {
  self.scale
}

///|
pub fn SceneSnapshot::resources(self : SceneSnapshot) -> Array[SceneResource] {
  copy_snapshot_resources(self.resources)
}

///|
pub fn SceneSnapshot::clip_chains(self : SceneSnapshot) -> Array[ClipChain] {
  copy_snapshot_clip_chains(self.clip_chains)
}

///|
pub fn SceneSnapshot::items(self : SceneSnapshot) -> Array[SceneItem] {
  copy_snapshot_items(self.items)
}

///|
/// Canonical JSON for semantic scene fixtures. Field order is fixed, arrays
/// preserve semantic order, and negative zero is normalized to zero.
pub fn SceneSnapshot::canonical_json(self : SceneSnapshot) -> String {
  let mut resources_json = ""
  let mut index = 0
  while index < self.resources.length() {
    if index > 0 {
      resources_json = resources_json + ","
    }
    resources_json = resources_json + "{\"id\":\{self.resources[index].id()}}"
    index += 1
  }
  let mut clips_json = ""
  index = 0
  while index < self.clip_chains.length() {
    if index > 0 {
      clips_json = clips_json + ","
    }
    clips_json = clips_json + snapshot_clip_chain_json(self.clip_chains[index])
    index += 1
  }
  let mut items_json = ""
  index = 0
  while index < self.items.length() {
    if index > 0 {
      items_json = items_json + ","
    }
    items_json = items_json + snapshot_item_json(self.items[index])
    index += 1
  }
  "{\"schema_version\":\{self.schema_version},\"viewport\":\{snapshot_rect_json(self.viewport)},\"scale\":\{snapshot_double(self.scale)},\"resources\":[\{resources_json}],\"clip_chains\":[\{clips_json}],\"items\":[\{items_json}]}"
}

///|
/// Convert the currently supported command stream into the versioned R0
/// envelope. Every painted quad receives a deterministic clip-chain entry for
/// the active rectangle stack. The current command surface has no resources.
pub fn Scene::snapshot_v1(
  self : Scene,
  viewport : @primitives.Rect,
  scale : Double,
) -> Result[SceneSnapshot, SceneError] {
  if scale.is_nan() || scale.is_inf() || scale <= 0.0 {
    Err(SceneError::InvalidScale)
  } else {
    match self.validate() {
      Err(error) => Err(error)
      Ok(_) => {
        let clip_stack : Array[@primitives.Rect] = []
        let clip_chains : Array[ClipChain] = []
        let items : Array[SceneItem] = []
        let mut index = 0
        while index < self.commands.length() {
          match self.commands[index] {
            ClipPushCommand(bounds~, ..) => clip_stack.push(bounds)
            ClipPopCommand(..) => ignore(clip_stack.pop())
            QuadCommand(id~, bounds~, color~) => {
              let clip_chain_id = snapshot_clip_chain_id(
                clip_chains, clip_stack,
              )
              let transform = AffineTransform::identity()
              let opacity = 1.0
              items.push(
                QuadItem(
                  id~,
                  bounds~,
                  color~,
                  transform~,
                  opacity~,
                  clip_chain_id~,
                ),
              )
            }
          }
          index += 1
        }
        Ok({
          schema_version: SCENE_SNAPSHOT_SCHEMA_VERSION,
          viewport,
          scale,
          resources: [],
          clip_chains,
          items,
        })
      }
    }
  }
}

///|
fn snapshot_clip_chain_id(
  chains : Array[ClipChain],
  rects : Array[@primitives.Rect],
) -> Int? {
  if rects.length() == 0 {
    None
  } else {
    let mut found : Int? = None
    let mut index = 0
    while index < chains.length() && found is None {
      if snapshot_rect_arrays_equal(chains[index].rects(), rects) {
        found = Some(chains[index].id())
      }
      index += 1
    }
    match found {
      Some(id) => Some(id)
      None => {
        let id = chains.length()
        chains.push(ClipChain::new(id, rects))
        Some(id)
      }
    }
  }
}

///|
fn snapshot_rect_arrays_equal(
  left : Array[@primitives.Rect],
  right : Array[@primitives.Rect],
) -> Bool {
  if left.length() != right.length() {
    false
  } else {
    let mut equal = true
    let mut index = 0
    while index < left.length() && equal {
      equal = left[index] == right[index]
      index += 1
    }
    equal
  }
}

///|
fn snapshot_finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn snapshot_double(value : Double) -> String {
  let normalized = if value == 0.0 { 0.0 } else { value }
  "\{normalized}"
}

///|
fn snapshot_rect_json(rect : @primitives.Rect) -> String {
  let size = rect.size()
  "{\"x\":\{snapshot_double(rect.left())},\"y\":\{snapshot_double(rect.top())},\"width\":\{snapshot_double(size.width())},\"height\":\{snapshot_double(size.height())}}"
}

///|
fn snapshot_color_json(color : @primitives.Color) -> String {
  "{\"red\":\{color.red()},\"green\":\{color.green()},\"blue\":\{color.blue()},\"alpha\":\{color.alpha()}}"
}

///|
fn snapshot_transform_json(transform : AffineTransform) -> String {
  "{\"a\":\{snapshot_double(transform.a())},\"b\":\{snapshot_double(transform.b())},\"c\":\{snapshot_double(transform.c())},\"d\":\{snapshot_double(transform.d())},\"tx\":\{snapshot_double(transform.tx())},\"ty\":\{snapshot_double(transform.ty())}}"
}

///|
fn snapshot_clip_chain_json(chain : ClipChain) -> String {
  let rects = chain.rects()
  let mut rects_json = ""
  let mut index = 0
  while index < rects.length() {
    if index > 0 {
      rects_json = rects_json + ","
    }
    rects_json = rects_json + snapshot_rect_json(rects[index])
    index += 1
  }
  "{\"id\":\{chain.id()},\"rects\":[\{rects_json}]}"
}

///|
fn snapshot_item_json(item : SceneItem) -> String {
  match item {
    QuadItem(id~, bounds~, color~, transform~, opacity~, clip_chain_id~) => {
      let clip_json = match clip_chain_id {
        None => "null"
        Some(value) => "\{value}"
      }
      "{\"kind\":\"quad\",\"id\":\{id},\"bounds\":\{snapshot_rect_json(bounds)},\"color\":\{snapshot_color_json(color)},\"transform\":\{snapshot_transform_json(transform)},\"opacity\":\{snapshot_double(opacity)},\"clip_chain_id\":\{clip_json}}"
    }
  }
}

///|
fn snapshot_has_duplicate_clip_ids(chains : Array[ClipChain]) -> Bool {
  let mut outer = 0
  let mut duplicate = false
  while outer < chains.length() && !duplicate {
    let mut inner = outer + 1
    while inner < chains.length() && !duplicate {
      if chains[outer].id() == chains[inner].id() {
        duplicate = true
      }
      inner += 1
    }
    outer += 1
  }
  duplicate
}

///|
///|
fn copy_snapshot_rects(
  values : Array[@primitives.Rect],
) -> Array[@primitives.Rect] {
  let copy : Array[@primitives.Rect] = []
  for value in values {
    copy.push(value)
  }
  copy
}

///|
fn copy_snapshot_resources(
  values : Array[SceneResource],
) -> Array[SceneResource] {
  let copy : Array[SceneResource] = []
  for value in values {
    copy.push(value)
  }
  copy
}

///|
fn copy_snapshot_clip_chains(values : Array[ClipChain]) -> Array[ClipChain] {
  let copy : Array[ClipChain] = []
  for value in values {
    copy.push(ClipChain::new(value.id(), value.rects()))
  }
  copy
}

///|
fn copy_snapshot_items(values : Array[SceneItem]) -> Array[SceneItem] {
  let copy : Array[SceneItem] = []
  for value in values {
    copy.push(value)
  }
  copy
}
