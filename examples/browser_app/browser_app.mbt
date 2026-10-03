///|
pub(all) enum BrowserDemoError {
  Stopped
  InvalidViewport
  QueueRejected
  ModelUpdateFailed
  LayoutFailed
  ElementTreeInvalid
  SceneSnapshotFailed
} derive(Eq)

///|
pub extend BrowserDemoError with Eq::{not_equal, equal}

///|
/// A compact, shared MoonBit app model hosted by the browser demo.
struct DemoModel {
  mut width : Double
  mut height : Double
  mut scale : Double
  mut pointer_x : Double?
  mut pointer_y : Double?
  mut hover_id : UInt64?
  mut focus_id : UInt64?
  mut last_target : UInt64?
  mut focused : Bool
  mut visible : Bool
  mut clicks : Int
  mut processed_events : Int
  mut last_sequence : Int64
  mut last_event : String
  mut last_key : String
}

///|
pub struct BrowserDemo {
  app : @core.App
  model : @core.Entity[DemoModel]
  ingress : @platform.EventIngress
  mut host_width : Double
  mut host_height : Double
  mut host_scale : Double
  mut stopped : Bool
}

///|
fn initial_model() -> DemoModel {
  {
    width: 800.0,
    height: 480.0,
    scale: 1.0,
    pointer_x: None,
    pointer_y: None,
    hover_id: None,
    focus_id: None,
    last_target: None,
    focused: false,
    visible: true,
    clicks: 0,
    processed_events: 0,
    last_sequence: 0,
    last_event: "ready",
    last_key: "—",
  }
}

///|
fn current_model(runtime : BrowserDemo) -> Result[DemoModel, BrowserDemoError] {
  match runtime.app.read(runtime.model, model => model) {
    Ok(model) => Ok(model)
    Err(_) => Err(ModelUpdateFailed)
  }
}

///|
fn valid_point(x : Double, y : Double) -> @primitives.Point? {
  match @primitives.Point::new(x, y) {
    Ok(point) => Some(point)
    Err(_) => None
  }
}

///|
fn apply_event(model : DemoModel, event : @platform.Event) -> DemoModel {
  let updated = model
  updated.last_sequence = event.sequence()
  match event.kind() {
    @platform.Created => updated.last_event = "viewport created"
    @platform.Resized(width~, height~) => {
      updated.width = width
      updated.height = height
      updated.last_event = "logical viewport resized"
    }
    @platform.ScaleChanged => {
      updated.scale = event.scale()
      updated.last_event = "device scale changed"
    }
    @platform.FocusChanged(focused) => {
      updated.focused = focused
      updated.last_event = if focused {
        "canvas focused"
      } else {
        "canvas blurred"
      }
    }
    @platform.VisibilityChanged(visible) => {
      updated.visible = visible
      updated.last_event = if visible { "page visible" } else { "page hidden" }
    }
    @platform.Input(input) =>
      match input {
        @primitives.PointerMoved(position~) => {
          updated.pointer_x = Some(position.x())
          updated.pointer_y = Some(position.y())
          updated.hover_id = hit_test(
            updated.width,
            updated.height,
            position.x(),
            position.y(),
          )
          updated.last_event = "pointer move"
        }
        @primitives.PointerButtonPressed(position~, button~, ..) => {
          updated.pointer_x = Some(position.x())
          updated.pointer_y = Some(position.y())
          let target = hit_test(
            updated.width,
            updated.height,
            position.x(),
            position.y(),
          )
          updated.hover_id = target
          updated.last_target = target
          updated.last_event = "pointer down"
          match target {
            None => ()
            Some(id) => {
              updated.clicks += 1
              if is_focusable_id(id) {
                updated.focus_id = Some(id)
              }
              if button is @primitives.Primary {
                updated.focused = true
              }
            }
          }
        }
        @primitives.PointerButtonReleased(..) =>
          updated.last_event = "pointer up"
        @primitives.KeyPressed(key~, modifiers~, ..) => {
          updated.last_key = key_label(key)
          updated.last_event = "key down"
          match key {
            @primitives.Tab =>
              updated.focus_id = Some(
                next_focus(updated.focus_id, modifiers.shift()),
              )
            @primitives.ArrowRight | @primitives.ArrowDown =>
              updated.focus_id = Some(next_focus(updated.focus_id, false))
            @primitives.ArrowLeft | @primitives.ArrowUp =>
              updated.focus_id = Some(next_focus(updated.focus_id, true))
            @primitives.Escape => updated.focus_id = None
            @primitives.Enter | @primitives.Space =>
              match updated.focus_id {
                Some(_) => updated.clicks += 1
                None => ()
              }
            _ =>
              if modifiers.control() || modifiers.meta() {
                updated.last_event = "modified key down"
              }
          }
        }
        @primitives.KeyReleased(key~, ..) => {
          updated.last_key = key_label(key)
          updated.last_event = "key up"
        }
        @primitives.TextInput(..) => updated.last_event = "text input"
        @primitives.Scroll(..) => updated.last_event = "scroll"
      }
    @platform.Wake => ()
    @platform.Moved(..) => updated.last_event = "host moved"
    @platform.CloseRequested => updated.last_event = "close requested"
    @platform.Destroyed => updated.last_event = "viewport destroyed"
    @platform.FrameCompleted => updated.last_event = "frame completed"
    @platform.ExitRequested => updated.last_event = "exit requested"
  }
  match event.kind() {
    @platform.Wake => ()
    _ => updated.processed_events += 1
  }
  updated
}

///|
fn is_focusable_id(id : UInt64) -> Bool {
  id >= 4 && id <= 7
}

///|
fn next_focus(current : UInt64?, backwards : Bool) -> UInt64 {
  match current {
    None => if backwards { 7 } else { 4 }
    Some(id) =>
      if backwards {
        if id <= 4 {
          7
        } else {
          id - 1
        }
      } else if id >= 7 {
        4
      } else {
        id + 1
      }
  }
}

///|
fn key_label(key : @primitives.Key) -> String {
  match key {
    @primitives.Character(_) => "Character"
    @primitives.Enter => "Enter"
    @primitives.Escape => "Escape"
    @primitives.Backspace => "Backspace"
    @primitives.Delete => "Delete"
    @primitives.Tab => "Tab"
    @primitives.Space => "Space"
    @primitives.ArrowLeft => "ArrowLeft"
    @primitives.ArrowRight => "ArrowRight"
    @primitives.ArrowUp => "ArrowUp"
    @primitives.ArrowDown => "ArrowDown"
    @primitives.Home => "Home"
    @primitives.End => "End"
    @primitives.PageUp => "PageUp"
    @primitives.PageDown => "PageDown"
  }
}

///|
fn logical_size(width : Double, height : Double) -> @primitives.Size {
  let safe_width = if width < 1.0 { 1.0 } else { width }
  let safe_height = if height < 1.0 { 1.0 } else { height }
  match @primitives.Size::new(safe_width, safe_height) {
    Ok(value) => value
    Err(_) => abort("finite logical viewport rejected")
  }
}

///|
fn dimension_points(value : Double) -> @layout.Dimension {
  match @layout.Dimension::points(value) {
    Ok(dimension) => dimension
    Err(_) => abort("valid point dimension rejected")
  }
}

///|
fn dimension_percent(value : Double) -> @layout.Dimension {
  match @layout.Dimension::percent(value) {
    Ok(dimension) => dimension
    Err(_) => abort("valid percent dimension rejected")
  }
}

///|
fn fixed_item(id : UInt64, width : Double, height : Double) -> @layout.FlexItem {
  @layout.FlexItem::new(
    id,
    dimension_points(height),
    dimension_percent(1.0),
    logical_size(width, height),
  )
}

///|
fn color(red : Int, green : Int, blue : Int) -> @primitives.Color {
  match @primitives.Color::rgba(red, green, blue, 255) {
    Ok(value) => value
    Err(_) => abort("valid browser demo color rejected")
  }
}

///|
fn rect(width : Double, height : Double) -> @primitives.Rect {
  match @primitives.Rect::new(0.0, 0.0, width, height) {
    Ok(value) => value
    Err(_) => abort("valid browser viewport rectangle rejected")
  }
}

///|
fn column_style() -> @layout.FlexTreeStyle {
  let padding = match @layout.Insets::all(20.0) {
    Ok(value) => value
    Err(_) => abort("valid root padding rejected")
  }
  let base = @layout.FlexTreeStyle::new(@layout.FlowDirection::column())
    .with_insets(padding, @layout.Insets::zero())
    .with_align(@layout.AlignItems::stretch())
  match base.with_gap(14.0) {
    Ok(value) => value
    Err(_) => abort("valid root gap rejected")
  }
}

///|
fn row_style() -> @layout.FlexTreeStyle {
  let padding = match @layout.Insets::all(12.0) {
    Ok(value) => value
    Err(_) => abort("valid card padding rejected")
  }
  let base = @layout.FlexTreeStyle::new(@layout.FlowDirection::row())
    .with_insets(padding, @layout.Insets::zero())
    .with_align(@layout.AlignItems::stretch())
  match base.with_gap(12.0) {
    Ok(value) => value
    Err(_) => abort("valid card gap rejected")
  }
}

///|
fn demo_layout(
  width : Double,
  height : Double,
) -> Result[@layout.FlexTreeLayout, BrowserDemoError] {
  let tile_a = match fixed_item(4, 148.0, 148.0).with_flex(1.0, 1.0) {
    Ok(value) => value
    Err(_) => abort("valid first tile flex rejected")
  }
  let tile_b = match fixed_item(5, 148.0, 148.0).with_flex(1.0, 1.0) {
    Ok(value) => value
    Err(_) => abort("valid second tile flex rejected")
  }
  let tile_c = match fixed_item(6, 148.0, 148.0).with_flex(1.0, 1.0) {
    Ok(value) => value
    Err(_) => abort("valid third tile flex rejected")
  }
  let tile_d = match fixed_item(7, 148.0, 148.0).with_flex(1.0, 1.0) {
    Ok(value) => value
    Err(_) => abort("valid fourth tile flex rejected")
  }
  let header = @layout.FlexTreeNode::new(fixed_item(2, 160.0, 112.0), 1)
  let cards = @layout.FlexTreeNode::new(fixed_item(3, 160.0, 184.0), 1).with_children(
    row_style(),
  )
  let footer = @layout.FlexTreeNode::new(fixed_item(8, 160.0, 52.0), 1)
  let card_a = @layout.FlexTreeNode::new(tile_a, 3)
  let card_b = @layout.FlexTreeNode::new(tile_b, 3)
  let card_c = @layout.FlexTreeNode::new(tile_c, 3)
  let card_d = @layout.FlexTreeNode::new(tile_d, 3)
  match
    @layout.layout_flex_tree(1, logical_size(width, height), column_style(), [
      header, cards, card_a, card_b, card_c, card_d, footer,
    ]) {
    Ok(layout) => Ok(layout)
    Err(_) => Err(LayoutFailed)
  }
}

///|
fn background_for(id : UInt64, model : DemoModel) -> @primitives.Color? {
  if id == 1 {
    Some(color(11, 17, 28))
  } else if id == 2 {
    Some(color(21, 36, 53))
  } else if id == 3 {
    Some(color(17, 26, 40))
  } else if id == 4 {
    Some(
      if model.focus_id == Some(id) {
        color(49, 177, 165)
      } else {
        color(31, 119, 112)
      },
    )
  } else if id == 5 {
    Some(
      if model.focus_id == Some(id) {
        color(82, 146, 219)
      } else {
        color(47, 93, 153)
      },
    )
  } else if id == 6 {
    Some(
      if model.focus_id == Some(id) {
        color(196, 133, 77)
      } else {
        color(139, 83, 44)
      },
    )
  } else if id == 7 {
    Some(
      if model.focus_id == Some(id) {
        color(157, 126, 209)
      } else {
        color(91, 66, 136)
      },
    )
  } else if id == 8 {
    Some(color(20, 31, 45))
  } else {
    None
  }
}

///|
fn parent_for(id : UInt64) -> UInt64? {
  if id == 1 {
    None
  } else if id >= 4 && id <= 7 {
    Some(3)
  } else {
    Some(1)
  }
}

///|
fn element_tree(
  model : DemoModel,
) -> Result[@element.ElementTree, BrowserDemoError] {
  match demo_layout(model.width, model.height) {
    Err(error) => Err(error)
    Ok(layout) => {
      let nodes : Array[@element.ElementNode] = []
      let root = @element.ElementNode::new(1, None, layout.root_bounds()).with_background(
        background_for(1, model),
      )
      nodes.push(root)
      for item in layout.items() {
        let id = item.id()
        let node = @element.ElementNode::new(id, parent_for(id), item.bounds())
          .with_focusable(is_focusable_id(id))
          .with_background(background_for(id, model))
        nodes.push(node)
      }
      match @element.ElementTree::new(nodes) {
        Err(_) => Err(ElementTreeInvalid)
        Ok(tree) => Ok(tree)
      }
    }
  }
}

///|
fn hit_test(width : Double, height : Double, x : Double, y : Double) -> UInt64? {
  match (valid_point(x, y), demo_layout(width, height)) {
    (Some(point), Ok(layout)) => {
      let nodes : Array[@element.ElementNode] = []
      nodes.push(@element.ElementNode::new(1, None, layout.root_bounds()))
      for item in layout.items() {
        nodes.push(
          @element.ElementNode::new(
            item.id(),
            parent_for(item.id()),
            item.bounds(),
          ),
        )
      }
      match @element.ElementTree::new(nodes) {
        Ok(tree) => tree.hit_test(point)
        Err(_) => None
      }
    }
    _ => None
  }
}

///|
fn scene_snapshot(
  model : DemoModel,
) -> Result[@scene.SceneSnapshot, BrowserDemoError] {
  match (element_tree(model), valid_point(model.width, model.height)) {
    (Err(error), _) => Err(error)
    (_, None) => Err(InvalidViewport)
    (Ok(tree), Some(_)) => {
      let viewport = rect(model.width, model.height)
      match tree.to_scene().snapshot_v1(viewport, model.scale) {
        Err(_) => Err(SceneSnapshotFailed)
        Ok(base) => {
          let items : Array[@scene.SceneItem] = []
          for item in base.items() {
            match item {
              @scene.QuadItem(id~, bounds~, color~, transform~, opacity~, ..) => {
                let hover_transform = if model.hover_id == Some(id) {
                  match
                    @scene.AffineTransform::new(1.0, 0.0, 0.0, 1.0, 2.0, -2.0) {
                    Ok(value) => value
                    Err(_) => @scene.AffineTransform::identity()
                  }
                } else {
                  transform
                }
                match
                  @scene.SceneItem::quad(
                    id,
                    bounds,
                    color,
                    hover_transform,
                    opacity,
                    Some(0),
                  ) {
                  Ok(value) => items.push(value)
                  Err(_) => return Err(SceneSnapshotFailed)
                }
              }
            }
          }
          match (model.pointer_x, model.pointer_y) {
            (Some(x), Some(y)) => {
              let marker_bounds = rect(12.0, 12.0)
              let marker_transform = match
                @scene.AffineTransform::new(
                  1.0,
                  0.0,
                  0.0,
                  1.0,
                  x - 6.0,
                  y - 6.0,
                ) {
                Ok(value) => value
                Err(_) => return Err(SceneSnapshotFailed)
              }
              match
                @scene.SceneItem::quad(
                  90,
                  marker_bounds,
                  color(112, 231, 219),
                  marker_transform,
                  0.92,
                  Some(0),
                ) {
                Ok(value) => items.push(value)
                Err(_) => return Err(SceneSnapshotFailed)
              }
              let halo_transform = match
                @scene.AffineTransform::new(
                  1.0,
                  0.0,
                  0.0,
                  1.0,
                  x - 18.0,
                  y - 18.0,
                ) {
                Ok(value) => value
                Err(_) => return Err(SceneSnapshotFailed)
              }
              match
                @scene.SceneItem::quad(
                  91,
                  rect(36.0, 36.0),
                  color(112, 231, 219),
                  halo_transform,
                  0.12,
                  Some(0),
                ) {
                Ok(value) => items.push(value)
                Err(_) => return Err(SceneSnapshotFailed)
              }
            }
            _ => ()
          }
          let clip = @scene.ClipChain::new(0, [viewport])
          match
            @scene.SceneSnapshot::new(viewport, model.scale, [], [clip], items) {
            Ok(snapshot) => Ok(snapshot)
            Err(_) => Err(SceneSnapshotFailed)
          }
        }
      }
    }
  }
}

///|
fn enqueue(
  runtime : BrowserDemo,
  kind : @platform.EventKind,
  scale : Double,
) -> Result[Unit, BrowserDemoError] {
  if runtime.stopped {
    Err(Stopped)
  } else {
    match runtime.ingress.enqueue(kind, scale) {
      Err(_) => Err(QueueRejected)
      Ok(_) =>
        match runtime.ingress.enqueue_wake(scale) {
          Err(_) => Err(QueueRejected)
          Ok(_) => Ok(())
        }
    }
  }
}

///|
/// Start one portable demo app instance. The app owns its model entity and the
/// common event ingress; no browser references enter this package.
pub fn BrowserDemo::new() -> Result[BrowserDemo, @diagnostics.FrameworkError] {
  match @core.App::new() {
    Err(error) => Err(error)
    Ok(app) =>
      match app.start() {
        Err(error) => Err(error)
        Ok(_) =>
          match app.create_entity(initial_model()) {
            Err(error) => Err(error)
            Ok(model) => {
              let demo : BrowserDemo = {
                app,
                model,
                ingress: @platform.EventIngress::new(@platform.WindowId::new(1)),
                host_width: 800.0,
                host_height: 480.0,
                host_scale: 1.0,
                stopped: false,
              }
              ignore(enqueue(demo, @platform.Created, 1.0))
              Ok(demo)
            }
          }
      }
  }
}

///|
/// Queue a browser callback value and one coalesced wake. The callback never
/// dispatches into the app; `render_frame` drains accepted work later.
pub fn BrowserDemo::enqueue_event(
  self : BrowserDemo,
  event : @platform.EventKind,
) -> Result[Unit, BrowserDemoError] {
  enqueue(self, event, self.host_scale)
}

///|
/// Queue a host measurement. Scale changes are accepted before resize and all
/// later inputs, so frame rendering and hit testing observe the new DPR.
pub fn BrowserDemo::set_viewport(
  self : BrowserDemo,
  width : Double,
  height : Double,
  scale : Double,
) -> Result[Unit, BrowserDemoError] {
  if self.stopped {
    Err(Stopped)
  } else if width.is_nan() ||
    width.is_inf() ||
    height.is_nan() ||
    height.is_inf() ||
    scale.is_nan() ||
    scale.is_inf() ||
    width < 1.0 ||
    height < 1.0 ||
    scale <= 0.0 {
    Err(InvalidViewport)
  } else {
    if scale != self.host_scale {
      match enqueue(self, @platform.ScaleChanged, scale) {
        Err(error) => return Err(error)
        Ok(_) => self.host_scale = scale
      }
    }
    if width != self.host_width || height != self.host_height {
      match enqueue(self, @platform.Resized(width~, height~), scale) {
        Err(error) => return Err(error)
        Ok(_) => {
          self.host_width = width
          self.host_height = height
        }
      }
    }
    Ok(())
  }
}

///|
/// Drain callback values in acceptance order, update the shared app entity,
/// and build its portable SceneSnapshot frame.
pub fn BrowserDemo::render_frame(
  self : BrowserDemo,
) -> Result[@scene.SceneSnapshot, BrowserDemoError] {
  if self.stopped {
    Err(Stopped)
  } else {
    for event in self.ingress.drain() {
      match
        self.app.update(self.model, context => {
          match context.get() {
            Err(_) =>
              Err(
                @diagnostics.FrameworkError::new(
                  @diagnostics.CallbackFailure,
                  "BrowserDemo::render_frame",
                  subsystem="browser-demo",
                  message="failed to read the portable app model",
                ),
              )
            Ok(model) => context.set(apply_event(model, event))
          }
        }) {
        Err(_) => return Err(ModelUpdateFailed)
        Ok(_) =>
          match self.app.run_ready(64) {
            Err(_) => return Err(ModelUpdateFailed)
            Ok(_) => ()
          }
      }
    }
    match current_model(self) {
      Err(error) => Err(error)
      Ok(model) => scene_snapshot(model)
    }
  }
}

///|
/// Framework-owned status encoded as valid JSON for the browser host panel.
pub fn BrowserDemo::status_json(self : BrowserDemo) -> String {
  match current_model(self) {
    Err(_) => "{\"active\":false,\"error\":\"model_unavailable\"}"
    Ok(model) => {
      let hover = id_json(model.hover_id)
      let focus = id_json(model.focus_id)
      let target = id_json(model.last_target)
      "{\"active\":\{!self.stopped},\"logicalWidth\":\{model.width},\"logicalHeight\":\{model.height},\"dpr\":\{model.scale},\"hover\":\{hover},\"focus\":\{focus},\"target\":\{target},\"clicks\":\{model.clicks},\"events\":\{model.processed_events},\"lastSequence\":\{model.last_sequence},\"lastEvent\":\{json_quote(model.last_event)},\"lastKey\":\{json_quote(model.last_key)},\"focused\":\{model.focused},\"visible\":\{model.visible}}"
    }
  }
}

///|
/// End the logical demo app and release all queued events. Repeated disposal
/// has no additional effect.
pub fn BrowserDemo::dispose(self : BrowserDemo) -> Unit {
  if !self.stopped {
    self.stopped = true
    self.ingress.close()
    ignore(self.app.request_stop())
    ignore(self.app.run_ready(64))
  }
}

///|
pub fn BrowserDemo::is_stopped(self : BrowserDemo) -> Bool {
  self.stopped
}

///|
fn id_json(id : UInt64?) -> String {
  match id {
    None => "null"
    Some(value) => "\{value}"
  }
}

///|
/// JSON string encoding used for browser-visible status and diagnostics.
pub fn json_quote(value : String) -> String {
  let output = StringBuilder()
  output.write_char('"')
  for character in value {
    match character {
      '"' => output.write_string("\\\"")
      '\\' => output.write_string("\\\\")
      '\n' => output.write_string("\\n")
      '\r' => output.write_string("\\r")
      '\t' => output.write_string("\\t")
      _ => output.write_char(character)
    }
  }
  output.write_char('"')
  output.to_string()
}
