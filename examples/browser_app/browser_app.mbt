///|
pub(all) enum BrowserDemoError {
  Stopped
  InvalidViewport
  InvalidTextInput
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
  mut capability_value : Int
  mut scroll_x : Double
  mut scroll_y : Double
  mut processed_events : Int
  mut last_sequence : Int64
  mut last_event : String
  mut last_key : String
  mut last_committed_text : String
  mut text_commit_count : Int
  pressed_buttons : Array[@primitives.MouseButton]
  pressed_keys : Array[@primitives.Key]
  mut pointer_downs : Int
  mut pointer_ups : Int
  mut key_downs : Int
  mut key_ups : Int
  mut key_repeats : Int
  mut unmatched_pointer_ups : Int
  mut unmatched_key_ups : Int
  mut last_modifiers : @primitives.Modifiers
}

///|
priv struct CounterState {
  value : Int
}

///|
pub struct BrowserDemo {
  app : @core.App
  model : @core.Entity[DemoModel]
  counter_command : @capability.TypedCapability[Int, Int]
  counter_query : @capability.TypedCapability[Unit, Int]
  counter_gui_binding : @capability.GuiBinding[Int, Int]
  mcp_adapter : @mcp.Adapter
  ingress : @platform.EventIngress
  mut host_width : Double
  mut host_height : Double
  mut host_scale : Double
  mut queued_focus_id : UInt64?
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
    capability_value: 0,
    scroll_x: 0.0,
    scroll_y: 0.0,
    processed_events: 0,
    last_sequence: 0,
    last_event: "ready",
    last_key: "—",
    last_committed_text: "",
    text_commit_count: 0,
    pressed_buttons: [],
    pressed_keys: [],
    pointer_downs: 0,
    pointer_ups: 0,
    key_downs: 0,
    key_ups: 0,
    key_repeats: 0,
    unmatched_pointer_ups: 0,
    unmatched_key_ups: 0,
    last_modifiers: @primitives.Modifiers::none(),
  }
}

///|
fn capability_error(
  code : @diagnostics.ErrorCode,
  operation : String,
  message : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    code,
    operation,
    subsystem="browser-demo-capability",
    message~,
  )
}

///|
fn counter_availability(
  app : @core.App,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if app.lifecycle() is @core.Running {
    Ok(())
  } else {
    Err(
      capability_error(
        @diagnostics.AppNotRunning,
        "demo.counter",
        "the browser demo app is no longer running",
      ),
    )
  }
}

///|
fn local_counter_policy(
  origin : @capability.InvocationOrigin,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match origin {
    @capability.Gui | @capability.Direct | @capability.RemoteMcp => Ok(())
    _ =>
      Err(
        capability_error(
          @diagnostics.PermissionDenied,
          "demo.counter",
          "this browser fixture accepts GUI, direct, and one in-process MCP adapter invocation",
        ),
      )
  }
}

///|
fn counter_descriptor(
  id : String,
  title : String,
  description : String,
  kind : @capability.OperationKind,
  input : @capability.Schema,
  output : @capability.Schema,
  effect : @capability.EffectClass,
  idempotent : Bool,
  exposure : @capability.Exposure,
  external_name : String?,
) -> Result[@capability.Descriptor, @diagnostics.FrameworkError] {
  @capability.Descriptor::new(
    id, title, description, kind, input, output, effect, idempotent, exposure, external_name,
    1,
  )
}

///|
fn make_counter_command(
  app : @core.App,
  state : @core.Entity[CounterState],
  projection : Ref[Int],
) -> Result[@capability.TypedCapability[Int, Int], @diagnostics.FrameworkError] {
  match
    counter_descriptor(
      "demo.counter.increment",
      "Increment the browser demo counter",
      "Change one app-owned value and notify the observing browser view.",
      @capability.Command,
      @capability.Schema::int(),
      @capability.Schema::int(),
      @capability.StateChange,
      false,
      @capability.External,
      Some("demo_counter_increment"),
    ) {
    Err(error) => Err(error)
    Ok(descriptor) => {
      let counter_app = app
      let counter_state = state
      let counter_projection = projection
      Ok(
        @capability.TypedCapability::new(
          descriptor,
          value => value.as_int(),
          value => Ok(@capability.IntValue(value)),
          delta => {
            if delta < 1 || delta > 10 {
              return Err(
                capability_error(
                  @diagnostics.InvalidInput,
                  "demo.counter.increment",
                  "increment must be between one and ten",
                ),
              )
            }
            let current_value = match
              counter_app.read(counter_state, current => current.value) {
              Err(error) => return Err(error)
              Ok(value) => value
            }
            if current_value > 1_000_000 - delta {
              return Err(
                capability_error(
                  @diagnostics.ResourceExhausted,
                  "demo.counter.increment",
                  "the browser demo counter reached its fixture limit",
                ),
              )
            }
            let next_value = current_value + delta
            match
              counter_app.update(counter_state, context => {
                match context.set({ value: next_value, }) {
                  Err(error) => Err(error)
                  Ok(_) => context.notify()
                }
              }) {
              Err(error) => Err(error)
              Ok(_) => {
                counter_projection.val = next_value
                Ok(next_value)
              }
            }
          },
          () => counter_availability(app),
          origin => local_counter_policy(origin),
        ),
      )
    }
  }
}

///|
fn make_counter_query(
  app : @core.App,
  state : @core.Entity[CounterState],
) -> Result[@capability.TypedCapability[Unit, Int], @diagnostics.FrameworkError] {
  match
    counter_descriptor(
      "demo.counter.read",
      "Read the browser demo counter",
      "Read the same app-owned value shown by the observing browser view.",
      @capability.Query,
      @capability.Schema::unit(),
      @capability.Schema::int(),
      @capability.ReadOnly,
      true,
      @capability.Local,
      None,
    ) {
    Err(error) => Err(error)
    Ok(descriptor) => {
      let counter_state = state
      Ok(
        @capability.TypedCapability::new(
          descriptor,
          _ => Ok(()),
          value => Ok(@capability.IntValue(value)),
          _ => app.read(counter_state, current => current.value),
          () => counter_availability(app),
          origin => local_counter_policy(origin),
        ),
      )
    }
  }
}

///|
fn install_counter_observer(
  app : @core.App,
  model : @core.Entity[DemoModel],
  source : @core.Entity[CounterState],
  projection : Ref[Int],
) -> Result[Unit, @diagnostics.FrameworkError] {
  let observed_projection = projection
  app.update(model, context => {
    match
      context.observe(source, observer => {
        match observer.get() {
          Err(error) => Err(error)
          Ok(current) => {
            current.capability_value = observed_projection.val
            match observer.set(current) {
              Err(error) => Err(error)
              Ok(_) => observer.notify()
            }
          }
        }
      }) {
      Err(error) => Err(error)
      Ok(_) => Ok(())
    }
  })
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
/// Keep one entry per accepted down: distinct physical keys can have the same
/// logical key, so each release removes only one matching held entry.
fn[T : Eq] release_pressed(pressed : Array[T], value : T) -> Bool {
  for index in 0..<pressed.length() {
    if pressed[index] == value {
      ignore(pressed.remove(index))
      return true
    }
  }
  false
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
      match (updated.pointer_x, updated.pointer_y) {
        (Some(x), Some(y)) =>
          updated.hover_id = hit_test(updated.width, updated.height, x, y)
        _ => ()
      }
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
        @primitives.PointerButtonPressed(position~, button~, modifiers~) => {
          updated.last_modifiers = modifiers
          updated.pressed_buttons.push(button)
          updated.pointer_downs += 1
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
        @primitives.PointerButtonReleased(button~, modifiers~, ..) => {
          updated.last_modifiers = modifiers
          updated.pointer_ups += 1
          if !release_pressed(updated.pressed_buttons, button) {
            updated.unmatched_pointer_ups += 1
          }
          updated.last_event = "pointer up"
        }
        @primitives.KeyPressed(key~, modifiers~, repeat~) => {
          updated.last_modifiers = modifiers
          if repeat {
            updated.key_repeats += 1
          } else {
            updated.pressed_keys.push(key)
            updated.key_downs += 1
          }
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
        @primitives.KeyReleased(key~, modifiers~) => {
          updated.last_modifiers = modifiers
          updated.key_ups += 1
          if !release_pressed(updated.pressed_keys, key) {
            updated.unmatched_key_ups += 1
          }
          updated.last_key = key_label(key)
          updated.last_event = "key up"
        }
        @primitives.TextInput(text~) => {
          updated.last_committed_text = text
          updated.text_commit_count += 1
          updated.last_event = "text input"
        }
        @primitives.Scroll(position~, delta~, ..) => {
          updated.pointer_x = Some(position.x())
          updated.pointer_y = Some(position.y())
          updated.scroll_x += delta.x()
          updated.scroll_y += delta.y()
          updated.last_event = "scroll"
        }
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
fn semantic_name(id : UInt64) -> String {
  match id {
    4 => "Alpine cyan action"
    5 => "Ocean blue action"
    6 => "Copper amber action"
    7 => "Violet dusk action"
    _ => "Unknown action"
  }
}

///|
fn cursor_for_hover(hover : UInt64?) -> @platform.Cursor {
  match hover {
    None => @platform.Arrow
    Some(id) =>
      if is_focusable_id(id) {
        @platform.PointingHand
      } else {
        @platform.Arrow
      }
  }
}

///|
fn cursor_label(cursor : @platform.Cursor) -> String {
  match cursor {
    @platform.Arrow => "arrow"
    @platform.PointingHand => "pointing-hand"
    @platform.Text => "text"
  }
}

///|
fn event_activates_counter(
  event : @platform.Event,
  focused : UInt64?,
  width : Double,
  height : Double,
) -> Bool {
  match event.kind() {
    @platform.Input(input) =>
      match input {
        @primitives.PointerButtonPressed(position~, button~, ..) =>
          button is @primitives.Primary &&
          hit_test(width, height, position.x(), position.y()) == Some(4)
        @primitives.KeyPressed(key~, ..) =>
          focused == Some(4) &&
          (key is @primitives.Enter || key is @primitives.Space)
        _ => false
      }
    _ => false
  }
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
fn input_state_json(model : DemoModel) -> String {
  let builder = StringBuilder()
  builder.write_string("{\"pressedButtons\":[")
  for index, button in model.pressed_buttons {
    if index > 0 {
      builder.write_string(",")
    }
    let browser_button = match button {
      @primitives.Primary => 0
      @primitives.Middle => 1
      @primitives.Secondary => 2
      @primitives.Back => 3
      @primitives.Forward => 4
    }
    builder.write_string("\{browser_button}")
  }
  builder.write_string("],\"pressedKeys\":[")
  for index, key in model.pressed_keys {
    if index > 0 {
      builder.write_string(",")
    }
    let logical_key = match key {
      @primitives.Character(value) => value
      @primitives.Space => " "
      _ => key_label(key)
    }
    builder.write_string(json_quote(logical_key))
  }
  builder.write_string(
    "],\"pointerDowns\":\{model.pointer_downs},\"pointerUps\":\{model.pointer_ups},\"keyDowns\":\{model.key_downs},\"keyUps\":\{model.key_ups},\"keyRepeats\":\{model.key_repeats},\"unmatchedPointerUps\":\{model.unmatched_pointer_ups},\"unmatchedKeyUps\":\{model.unmatched_key_ups}",
  )
  let modifiers = model.last_modifiers
  builder.write_string(
    ",\"lastModifiers\":{\"shift\":\{modifiers.shift()},\"control\":\{modifiers.control()},\"alt\":\{modifiers.alt()},\"meta\":\{modifiers.meta()}}}",
  )
  builder.to_string()
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
          let counter_steps = if model.capability_value > 48 {
            48
          } else {
            model.capability_value
          }
          let counter_width = 8.0 + counter_steps.to_double() * 4.0
          let counter_transform = match
            @scene.AffineTransform::new(1.0, 0.0, 0.0, 1.0, 30.0, 112.0) {
            Ok(value) => value
            Err(_) => return Err(SceneSnapshotFailed)
          }
          match
            @scene.SceneItem::quad(
              92,
              rect(counter_width, 6.0),
              color(112, 231, 219),
              counter_transform,
              1.0,
              Some(0),
            ) {
            Ok(value) => items.push(value)
            Err(_) => return Err(SceneSnapshotFailed)
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
/// Semantic host actions are discrete keyboard taps, with both halves queued
/// so they cannot leave a framework-owned key held after activation or focus.
fn enqueue_key_tap(
  runtime : BrowserDemo,
  key : @primitives.Key,
  modifiers : @primitives.Modifiers,
) -> Result[Unit, BrowserDemoError] {
  match
    enqueue(
      runtime,
      @platform.Input(@primitives.KeyPressed(key~, modifiers~, repeat=false)),
      runtime.host_scale,
    ) {
    Err(error) => Err(error)
    Ok(_) =>
      enqueue(
        runtime,
        @platform.Input(@primitives.KeyReleased(key~, modifiers~)),
        runtime.host_scale,
      )
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
            Ok(model) =>
              match app.create_entity({ value: 0, }) {
                Err(error) => Err(error)
                Ok(counter_state) => {
                  let projection = Ref(0)
                  match
                    (
                      make_counter_command(app, counter_state, projection),
                      make_counter_query(app, counter_state),
                    ) {
                    (Err(error), _) => Err(error)
                    (_, Err(error)) => Err(error)
                    (Ok(counter_command), Ok(counter_query)) =>
                      match
                        install_counter_observer(
                          app, model, counter_state, projection,
                        ) {
                        Err(error) => Err(error)
                        Ok(_) => {
                          let registry = @capability.Registry::new()
                          match registry.register(counter_command) {
                            Err(error) => Err(error)
                            Ok(_) => {
                              let demo : BrowserDemo = {
                                app,
                                model,
                                counter_gui_binding: counter_command.gui_binding(),
                                counter_command,
                                counter_query,
                                mcp_adapter: @mcp.Adapter::new(registry),
                                ingress: @platform.EventIngress::new(
                                  @platform.WindowId::new(1),
                                ),
                                host_width: 800.0,
                                host_height: 480.0,
                                host_scale: 1.0,
                                queued_focus_id: None,
                                stopped: false,
                              }
                              ignore(enqueue(demo, @platform.Created, 1.0))
                              Ok(demo)
                            }
                          }
                        }
                      }
                  }
                }
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
/// Queue a bounded committed insert through the same deterministic ingress as
/// pointer and key callbacks. No provisional composition text enters the model.
pub fn BrowserDemo::enqueue_text_input(
  self : BrowserDemo,
  text : String,
) -> Result[Unit, BrowserDemoError] {
  if self.stopped {
    Err(Stopped)
  } else if text.length() == 0 || text.length() > 65_536 {
    Err(InvalidTextInput)
  } else {
    enqueue(
      self,
      @platform.Input(@primitives.TextInput(text~)),
      self.host_scale,
    )
  }
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
      match current_model(self) {
        Err(error) => return Err(error)
        Ok(model) =>
          if event_activates_counter(
              event,
              model.focus_id,
              self.host_width,
              self.host_height,
            ) {
            match self.counter_gui_binding.trigger(1) {
              Err(_) => return Err(ModelUpdateFailed)
              Ok(_) =>
                match self.app.run_ready(64) {
                  Err(_) => return Err(ModelUpdateFailed)
                  Ok(_) => ()
                }
            }
          }
      }
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
      Err(error) => return Err(error)
      Ok(model) => self.queued_focus_id = model.focus_id
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
      let cursor = json_quote(cursor_label(cursor_for_hover(model.hover_id)))
      let focus = id_json(model.focus_id)
      let target = id_json(model.last_target)
      "{\"active\":\{!self.stopped},\"logicalWidth\":\{model.width},\"logicalHeight\":\{model.height},\"dpr\":\{model.scale},\"hover\":\{hover},\"cursor\":\{cursor},\"focus\":\{focus},\"target\":\{target},\"clicks\":\{model.clicks},\"capabilityValue\":\{model.capability_value},\"scrollX\":\{model.scroll_x},\"scrollY\":\{model.scroll_y},\"events\":\{model.processed_events},\"lastSequence\":\{model.last_sequence},\"lastEvent\":\{json_quote(model.last_event)},\"lastKey\":\{json_quote(model.last_key)},\"lastCommittedText\":\{json_quote(model.last_committed_text)},\"textCommitCount\":\{model.text_commit_count},\"focused\":\{model.focused},\"visible\":\{model.visible},\"inputState\":\{input_state_json(model)}}"
    }
  }
}

///|
/// End the logical demo app and release all queued events. Repeated disposal
/// has no additional effect.
pub fn BrowserDemo::dispose(self : BrowserDemo) -> Unit {
  if !self.stopped {
    self.stopped = true
    self.mcp_adapter.close()
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
/// Invoke the same local semantic command used by the fixture's GUI binding.
/// The observer notification updates the render model before the next frame.
pub fn BrowserDemo::invoke_counter_direct(
  self : BrowserDemo,
  delta : Int,
) -> Result[Int, @diagnostics.FrameworkError] {
  match self.counter_command.invoke(@capability.Direct, delta) {
    Err(error) => Err(error)
    Ok(value) =>
      match self.app.run_ready(64) {
        Err(error) => Err(error)
        Ok(_) => Ok(value)
      }
  }
}

///|
/// Route the fixture's single externally exposed write through the portable
/// MCP adapter. This is an in-process adapter call used to prove shared
/// capability semantics; it does not create a network transport.
pub fn BrowserDemo::invoke_counter_mcp(
  self : BrowserDemo,
  delta : Int,
) -> Result[Int, @diagnostics.FrameworkError] {
  let output = match
    self.mcp_adapter.call_tool(
      "demo_counter_increment",
      @capability.Value::int(delta),
    ) {
    Err(error) =>
      return Err(
        capability_error(
          match error.code() {
            @mcp.InvalidInput => @diagnostics.InvalidInput
            @mcp.PermissionDenied => @diagnostics.PermissionDenied
            @mcp.Stale => @diagnostics.StaleHandle
            @mcp.Unavailable => @diagnostics.Busy
            _ => @diagnostics.CallbackFailure
          },
          "demo.counter.mcp",
          error.message(),
        ),
      )
    Ok(value) => value
  }
  let value = match output {
    @capability.IntValue(value) => value
    _ =>
      return Err(
        capability_error(
          @diagnostics.ConversionFailed,
          "demo.counter.mcp",
          "the counter adapter returned a non-integer output",
        ),
      )
  }
  match self.app.run_ready(64) {
    Err(error) => Err(error)
    Ok(_) => Ok(value)
  }
}

///|
/// Query the command's source entity through its Local semantic query.
pub fn BrowserDemo::query_counter(
  self : BrowserDemo,
) -> Result[Int, @diagnostics.FrameworkError] {
  self.counter_query.invoke(@capability.Direct, ())
}

///|
/// Synchronize a browser accessibility proxy with the fixture's normal tab
/// order. The resulting key events enter the same deterministic event queue.
pub fn BrowserDemo::focus_semantic_node(
  self : BrowserDemo,
  id : Int,
  backwards : Bool,
) -> Result[Unit, BrowserDemoError] {
  if self.stopped {
    Err(Stopped)
  } else if id < 4 || id > 7 {
    Err(ElementTreeInvalid)
  } else {
    match current_model(self) {
      Err(error) => Err(error)
      Ok(model) => {
        let current_focus = match self.queued_focus_id {
          Some(value) => Some(value)
          None => model.focus_id
        }
        let current_index = match current_focus {
          None => -1
          Some(4) => 0
          Some(5) => 1
          Some(6) => 2
          Some(7) => 3
          Some(_) => -1
        }
        let target_index = id - 4
        let steps = if backwards {
          if current_index < 0 {
            4 - target_index
          } else if target_index < current_index {
            current_index - target_index
          } else if target_index > current_index {
            current_index + 4 - target_index
          } else {
            0
          }
        } else if current_index < 0 {
          target_index + 1
        } else if target_index > current_index {
          target_index - current_index
        } else if target_index < current_index {
          4 - current_index + target_index
        } else {
          0
        }
        let modifiers = @primitives.Modifiers::new(
          shift=backwards,
          control=false,
          alt=false,
          meta=false,
        )
        for _ in 0..<steps {
          match enqueue_key_tap(self, @primitives.Tab, modifiers) {
            Err(error) => return Err(error)
            Ok(_) => ()
          }
        }
        let target_id : UInt64 = match id {
          4 => 4
          5 => 5
          6 => 6
          _ => 7
        }
        self.queued_focus_id = Some(target_id)
        Ok(())
      }
    }
  }
}

///|
pub fn BrowserDemo::activate_semantic_node(
  self : BrowserDemo,
  id : Int,
) -> Result[Unit, BrowserDemoError] {
  match self.focus_semantic_node(id, false) {
    Err(error) => Err(error)
    Ok(_) => {
      let modifiers = @primitives.Modifiers::none()
      enqueue_key_tap(self, @primitives.Enter, modifiers)
    }
  }
}

///|
/// Host-layout DTO from the portable demo's flex layout and element fixture.
/// Semantic nodes are test-fixture data, not a general accessibility API.
pub fn BrowserDemo::host_layout_json(self : BrowserDemo) -> String {
  match current_model(self) {
    Err(_) => "{\"version\":1,\"nodes\":[],\"regions\":[]}"
    Ok(model) =>
      match demo_layout(model.width, model.height) {
        Err(_) => "{\"version\":1,\"nodes\":[],\"regions\":[]}"
        Ok(layout) => {
          let builder = StringBuilder()
          builder.write_string("{\"version\":1,\"nodes\":[")
          let mut emitted = 0
          for item in layout.items() {
            let id = item.id()
            if id >= 4 && id <= 7 {
              if emitted > 0 {
                builder.write_string(",")
              }
              let name = semantic_name(id)
              let bounds = item.bounds()
              builder.write_string(
                "{\"id\":\{id},\"role\":\"button\",\"name\":\{json_quote(name)},\"value\":null,\"disabled\":false,\"focused\":\{model.focus_id == Some(id)},\"bounds\":{\"x\":\{bounds.left()},\"y\":\{bounds.top()},\"width\":\{bounds.size().width()},\"height\":\{bounds.size().height()}}}",
              )
              emitted += 1
            }
          }
          builder.write_string("],\"regions\":[")
          let mut has_region = false
          for item in layout.items() {
            if item.id() == 8 {
              let bounds = item.bounds()
              builder.write_string(
                "{\"id\":8,\"kind\":\"legacy-island\",\"name\":\"Legacy web notes\",\"bounds\":{\"x\":\{bounds.left()},\"y\":\{bounds.top()},\"width\":\{bounds.size().width()},\"height\":\{bounds.size().height()}}}",
              )
              has_region = true
            }
          }
          if !has_region {
            builder.write_string(
              "{\"id\":8,\"kind\":\"legacy-island\",\"name\":\"Legacy web notes\",\"bounds\":{\"x\":0,\"y\":0,\"width\":0,\"height\":0}}",
            )
          }
          builder.write_string("]}")
          builder.to_string()
        }
      }
  }
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
  "\"\{@capability.json_escape(value)}\""
}
