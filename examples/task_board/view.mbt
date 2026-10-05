///|
priv struct LaneGeometry {
  lane : Int
  bounds : @primitives.Rect
  viewport : @primitives.Rect
}

///|
priv struct CardGeometry {
  task : Task
  bounds : @primitives.Rect
  visible_bounds : @primitives.Rect
}

///|
fn positive(value : Double) -> Double {
  if value < 0.0 {
    0.0
  } else {
    value
  }
}

///|
fn board_size(width : Double, height : Double) -> @primitives.Size {
  match @primitives.Size::new(positive(width), positive(height)) {
    Ok(value) => value
    Err(_) => abort("board sizes are finite after bounded ingress")
  }
}

///|
fn board_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, positive(width), positive(height)) {
    Ok(value) => value
    Err(_) => abort("board rectangles are finite after bounded ingress")
  }
}

///|
fn lane_name(lane : Int) -> String {
  match lane {
    0 => "Backlog"
    1 => "In progress"
    _ => "Done"
  }
}

///|
fn points(value : Double) -> @layout.Dimension {
  match @layout.Dimension::points(value) {
    Ok(value) => value
    Err(_) => abort("the board uses finite layout dimensions")
  }
}

///|
fn full_dimension() -> @layout.Dimension {
  match @layout.Dimension::percent(1.0) {
    Ok(value) => value
    Err(_) => abort("the board uses a valid full dimension")
  }
}

///|
/// Shared flex layout decides the lane geometry. Mobile lays out only the
/// selected lane; the browser merely projects the resulting DTO.
fn board_lanes(model : BoardModel) -> Result[Array[LaneGeometry], BoardError] {
  let padding = match @layout.Insets::all(12.0) {
    Ok(value) => value
    Err(_) => return Err(LayoutFailure)
  }
  let container = @layout.FlexContainer::new(
      @layout.FlowDirection::row(),
      board_size(model.width, model.height),
    )
    .with_insets(padding, @layout.Insets::zero())
    .with_align(@layout.AlignItems::stretch())
  let container = match container.with_gap(14.0) {
    Ok(value) => value
    Err(_) => return Err(LayoutFailure)
  }
  let items : Array[@layout.FlexItem] = []
  for lane in 0..<3 {
    if model.width >= 700.0 || lane == model.active_lane {
      let item = @layout.FlexItem::new(
        (100 + lane).to_uint64(),
        points(0.0),
        full_dimension(),
        board_size(0.0, 0.0),
      )
      match item.with_flex(1.0, 1.0) {
        Ok(value) => items.push(value)
        Err(_) => return Err(LayoutFailure)
      }
    }
  }
  let layout = match @layout.layout_flex(container, items) {
    Ok(value) => value
    Err(_) => return Err(LayoutFailure)
  }
  let lanes : Array[LaneGeometry] = []
  for item in layout.items() {
    let bounds = item.bounds()
    lanes.push({
      lane: item.id().to_int() - 100,
      bounds,
      viewport: board_rect(
        bounds.left() + 10.0,
        bounds.top() + 50.0,
        bounds.size().width() - 20.0,
        bounds.size().height() - 60.0,
      ),
    })
  }
  Ok(lanes)
}

///|
fn content_height(count : Int) -> Double {
  if count == 0 {
    0.0
  } else {
    count.to_double() * 102.0 - 10.0
  }
}

///|
fn refresh_scrolls(model : BoardModel) -> Unit {
  match board_lanes(model) {
    Err(_) => ()
    Ok(lanes) => {
      if lanes.length() == 0 {
        return
      }
      // Every lane uses the same allocation. Hidden mobile lanes retain their
      // own offset while their bounds clamp to the next visible allocation.
      let size = lanes[0].viewport.size()
      for lane in 0..<3 {
        let count = lane_tasks(model, lane).length()
        model.scrolls[lane] = model.scrolls[lane].with_sizes(
          size,
          board_size(size.width(), content_height(count)),
        )
      }
    }
  }
}

///|
fn ensure_selection_visible(model : BoardModel) -> Unit {
  match model.selected {
    None => ()
    Some(id) =>
      for lane in 0..<3 {
        for index, task in lane_tasks(model, lane) {
          if task.id == id {
            model.scrolls[lane] = model.scrolls[lane].ensure_visible(
              board_rect(0.0, index.to_double() * 102.0, 1.0, 92.0),
            )
            return
          }
        }
      }
  }
}

///|
fn board_cards(model : BoardModel, lane : LaneGeometry) -> Array[CardGeometry] {
  let cards : Array[CardGeometry] = []
  let root = board_rect(0.0, 0.0, model.width, model.height)
  let offset = model.scrolls[lane.lane].offset().y()
  for index, task in lane_tasks(model, lane.lane) {
    let bounds = board_rect(
      lane.viewport.left(),
      lane.viewport.top() + index.to_double() * 102.0 - offset,
      lane.viewport.size().width(),
      92.0,
    )
    let visible = match bounds.intersection(lane.viewport) {
      Some(value) => value.intersection(root)
      None => None
    }
    match visible {
      Some(visible_bounds) =>
        if visible_bounds.size().width() > 0.0 &&
          visible_bounds.size().height() > 0.0 {
          cards.push({ task, bounds, visible_bounds, })
        }
      None => ()
    }
  }
  cards
}

///|
fn board_tree(model : BoardModel) -> Result[@element.ElementTree, BoardError] {
  let lanes = match board_lanes(model) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let nodes : Array[@element.ElementNode] = [
    @element.ElementNode::new(
      1,
      None,
      board_rect(0.0, 0.0, model.width, model.height),
    ).with_pointer_events(false),
  ]
  for lane in lanes {
    let lane_id = (100 + lane.lane).to_uint64()
    nodes.push(
      @element.ElementNode::new(lane_id, Some(1), lane.bounds).with_pointer_events(
        false,
      ),
    )
    // The shared ElementTree accepts clipped visual bounds. Offscreen and
    // zero-area cards are absent, including when they overlap another lane.
    for card in board_cards(model, lane) {
      nodes.push(
        @element.ElementNode::new(
          (1000 + card.task.id).to_uint64(),
          Some(lane_id),
          card.visible_bounds,
        ).with_focusable(true),
      )
    }
  }
  match @element.ElementTree::new(nodes) {
    Ok(value) => Ok(value)
    Err(_) => Err(LayoutFailure)
  }
}

///|
fn hit_card(model : BoardModel, position : @primitives.Point) -> Int? {
  match board_tree(model) {
    Err(_) => None
    Ok(tree) =>
      match tree.hit_test(position) {
        Some(id) => Some(id.to_int() - 1000)
        None => None
      }
  }
}

///|
fn lane_at(model : BoardModel, position : @primitives.Point) -> Int? {
  if !board_rect(0.0, 0.0, model.width, model.height).contains(position) {
    return None
  }
  match board_lanes(model) {
    Err(_) => None
    Ok(lanes) => {
      for lane in lanes {
        if lane.bounds.contains(position) {
          return Some(lane.lane)
        }
      }
      None
    }
  }
}

///|
fn color(red : Int, green : Int, blue : Int) -> @primitives.Color {
  match @primitives.Color::rgba(red, green, blue, 255) {
    Ok(value) => value
    Err(_) => abort("valid board color")
  }
}

///|
fn lane_color(lane : Int) -> @primitives.Color {
  match lane {
    0 => color(143, 151, 127)
    1 => color(184, 127, 79)
    _ => color(116, 147, 104)
  }
}

///|
fn add_quad(
  items : Array[@scene.SceneItem],
  id : UInt64,
  bounds : @primitives.Rect,
  fill : @primitives.Color,
  clip : Int,
  opacity : Double,
) -> Unit {
  match
    @scene.SceneItem::quad(
      id,
      bounds,
      fill,
      @scene.AffineTransform::identity(),
      opacity,
      Some(clip),
    ) {
    Ok(value) => items.push(value)
    Err(_) => abort("the board constructs finite clipped quads")
  }
}

///|
fn add_text(
  items : Array[@scene.SceneItem],
  id : UInt64,
  bounds : @primitives.Rect,
  text : String,
  font_size : Double,
  fill : @primitives.Color,
  clip : Int,
) -> Unit {
  if bounds.size().width() <= 0.0 || bounds.size().height() <= 0.0 {
    return
  }
  match
    @scene.SceneItem::text(
      id,
      bounds,
      text,
      font_size,
      fill,
      @scene.AffineTransform::identity(),
      1.0,
      Some(clip),
    ) {
    Ok(value) => items.push(value)
    Err(_) => abort("the board constructs bounded plain text")
  }
}

///|
fn paint_card(
  items : Array[@scene.SceneItem],
  task : Task,
  bounds : @primitives.Rect,
  selected : Bool,
  hovered : Bool,
  clip : Int,
  base : UInt64,
) -> Unit {
  let x = bounds.left()
  let y = bounds.top()
  let width = bounds.size().width()
  let border = if selected {
    color(140, 161, 110)
  } else if hovered {
    color(178, 190, 158)
  } else {
    color(221, 226, 211)
  }
  add_quad(items, base, bounds, border, clip, 1.0)
  add_quad(
    items,
    base + 1,
    board_rect(x + 1.0, y + 1.0, width - 2.0, 90.0),
    if selected {
      color(245, 248, 235)
    } else {
      color(255, 255, 251)
    },
    clip,
    1.0,
  )
  let priority_color = match task.priority {
    "high" => color(174, 120, 72)
    "low" => color(110, 139, 102)
    _ => color(137, 145, 116)
  }
  add_text(
    items,
    base + 2,
    board_rect(x + 12.0, y + 9.0, width - 70.0, 14.0),
    task.priority.to_upper(),
    10.0,
    priority_color,
    clip,
  )
  add_text(
    items,
    base + 3,
    board_rect(x + 12.0, y + 29.0, width - 24.0, 22.0),
    task.title,
    14.0,
    color(52, 58, 45),
    clip,
  )
  add_text(
    items,
    base + 4,
    board_rect(x + 12.0, y + 63.0, width - 24.0, 17.0),
    task.detail,
    11.0,
    color(143, 153, 125),
    clip,
  )
  add_text(
    items,
    base + 5,
    board_rect(x + positive(width - 49.0), y + 9.0, 37.0, 14.0),
    "#\{task.id}",
    10.0,
    color(155, 166, 137),
    clip,
  )
}

///|
fn board_scene(model : BoardModel) -> Result[@scene.SceneSnapshot, BoardError] {
  let root = board_rect(0.0, 0.0, model.width, model.height)
  let lanes = match board_lanes(model) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let clips : Array[@scene.ClipChain] = [@scene.ClipChain::new(0, [root])]
  let items : Array[@scene.SceneItem] = []
  add_quad(items, 1, root, color(255, 255, 251), 0, 1.0)
  for lane in lanes {
    let id = lane.lane
    let bounds = lane.bounds
    let x = bounds.left()
    let y = bounds.top()
    let width = bounds.size().width()
    let count = lane_tasks(model, id).length()
    let clip = id + 1
    clips.push(@scene.ClipChain::new(clip, [root, lane.viewport]))
    add_quad(
      items,
      (100 + id).to_uint64(),
      bounds,
      color(241, 244, 235),
      0,
      1.0,
    )
    if model.drop_lane == Some(id) {
      add_quad(
        items,
        (200 + id).to_uint64(),
        bounds,
        color(223, 232, 255),
        0,
        1.0,
      )
    }
    add_quad(
      items,
      (250 + id).to_uint64(),
      board_rect(x + 14.0, y + 22.0, 7.0, 7.0),
      lane_color(id),
      0,
      1.0,
    )
    add_text(
      items,
      (300 + id).to_uint64(),
      board_rect(x + 29.0, y + 13.0, width - 79.0, 25.0),
      lane_name(id),
      14.0,
      color(40, 52, 77),
      0,
    )
    add_text(
      items,
      (400 + id).to_uint64(),
      board_rect(x + positive(width - 37.0), y + 15.0, 28.0, 22.0),
      "\{count}",
      13.0,
      color(111, 125, 146),
      0,
    )
    for card in board_cards(model, lane) {
      paint_card(
        items,
        card.task,
        card.bounds,
        model.selected == Some(card.task.id),
        model.hover == Some(card.task.id),
        clip,
        (1000 + card.task.id * 10).to_uint64(),
      )
    }
    if count == 0 {
      add_text(
        items,
        (600 + id).to_uint64(),
        board_rect(
          lane.viewport.left() + 12.0,
          lane.viewport.top() + 28.0,
          lane.viewport.size().width() - 24.0,
          24.0,
        ),
        if model.query == "" {
          "Drop a task here"
        } else {
          "No matching tasks"
        },
        13.0,
        color(133, 145, 164),
        clip,
      )
    }
    let maximum = model.scrolls[id].max_offset().y()
    if maximum > 0.0 && lane.viewport.size().height() > 0.0 {
      let track_height = lane.viewport.size().height()
      let thumb_height = track_height * track_height / (track_height + maximum)
      let thumb_y = lane.viewport.top() +
        (track_height - thumb_height) * model.scrolls[id].offset().y() / maximum
      add_quad(
        items,
        (700 + id).to_uint64(),
        board_rect(bounds.right() - 6.0, lane.viewport.top(), 3.0, track_height),
        color(228, 234, 243),
        0,
        1.0,
      )
      add_quad(
        items,
        (800 + id).to_uint64(),
        board_rect(bounds.right() - 6.0, thumb_y, 3.0, thumb_height),
        color(173, 187, 149),
        0,
        1.0,
      )
    }
  }
  if model.drag.is_dragging() {
    match (model.drag.source(), model.drag.position()) {
      (Some(id), Some(position)) =>
        match find_task(model, id.to_int()) {
          Some(task) => {
            let width = if model.width < 300.0 {
              positive(model.width - 24.0)
            } else {
              264.0
            }
            let x = position.x() + 14.0
            let y = position.y() + 12.0
            add_quad(
              items,
              100_000_000,
              board_rect(x + 4.0, y + 6.0, width, 92.0),
              color(61, 74, 42),
              0,
              0.12,
            )
            paint_card(
              items,
              task,
              board_rect(x, y, width, 92.0),
              true,
              false,
              0,
              100_000_010,
            )
          }
          None => ()
        }
      _ => ()
    }
  }
  match @scene.SceneSnapshot::new(root, model.scale, [], clips, items) {
    Ok(value) => Ok(value)
    Err(_) => Err(SceneFailure)
  }
}

///|
fn bounds_json(bounds : @primitives.Rect) -> String {
  "{\"x\":\{bounds.left()},\"y\":\{bounds.top()},\"width\":\{bounds.size().width()},\"height\":\{bounds.size().height()}}"
}

///|
fn optional_id_json(value : Int?) -> String {
  match value {
    Some(id) => "\{id}"
    None => "null"
  }
}

///|
fn task_json(task : Task) -> String {
  "{\"id\":\{task.id},\"title\":\{json_quote(task.title)},\"lane\":\{task.lane},\"priority\":\{json_quote(task.priority)},\"detail\":\{json_quote(task.detail)}}"
}

///|
pub fn BoardDemo::status_json(self : BoardDemo) -> String {
  if self.stopped {
    return "{\"active\":false}"
  }
  match self.current_board() {
    Err(_) => "{\"active\":false,\"error\":\"model_unavailable\"}"
    Ok(model) => {
      let builder = StringBuilder()
      let done = model.tasks.filter(task => task.lane == 2).length()
      let source = match model.drag.source() {
        Some(id) => "\{id}"
        None => "null"
      }
      let cursor = if model.hover is Some(_) {
        "pointing-hand"
      } else {
        "arrow"
      }
      builder.write_string(
        "{\"active\":true,\"logicalWidth\":\{model.width},\"logicalHeight\":\{model.height},\"scale\":\{model.scale},\"query\":\{json_quote(model.query)},\"selectedId\":\{optional_id_json(model.selected)},\"canUndo\":\{model.history.length() > 0},\"activeLane\":\{model.active_lane},\"total\":\{model.tasks.length()},\"done\":\{done},\"message\":\{json_quote(model.message)},\"dragging\":\{model.drag.is_dragging()},\"dragPending\":\{model.drag.is_pending()},\"dragSource\":\{source},\"dropLane\":\{optional_id_json(model.drop_lane)},\"hoverId\":\{optional_id_json(model.hover)},\"cursor\":\{json_quote(cursor)},\"focused\":\{model.focused},\"visible\":\{model.visible},\"events\":\{model.events},\"lastSequence\":\{model.last_sequence},\"tasks\":[",
      )
      for index, task in model.tasks {
        if index > 0 {
          builder.write_string(",")
        }
        builder.write_string(task_json(task))
      }
      builder.write_string("],\"filteredIds\":[")
      for index, task in filtered_tasks(model) {
        if index > 0 {
          builder.write_string(",")
        }
        builder.write_string("\{task.id}")
      }
      builder.write_string("]}")
      builder.to_string()
    }
  }
}

///|
/// Stable semantic IDs and already-clipped bounds for the browser's focus
/// proxies. Hidden mobile lanes still carry count/scroll metadata, with
/// visible=false and zero bounds; only visible card intersections are nodes.
pub fn BoardDemo::host_layout_json(self : BoardDemo) -> String {
  if self.stopped {
    return "{\"version\":1,\"mobile\":false,\"lanes\":[],\"nodes\":[]}"
  }
  let model = match self.current_board() {
    Ok(value) => value
    Err(_) => return "{\"version\":1,\"lanes\":[],\"nodes\":[]}"
  }
  let lanes = match board_lanes(model) {
    Ok(value) => value
    Err(_) => return "{\"version\":1,\"lanes\":[],\"nodes\":[]}"
  }
  let builder = StringBuilder()
  builder.write_string(
    "{\"version\":1,\"mobile\":\{model.width < 700.0},\"lanes\":[",
  )
  for id in 0..<3 {
    if id > 0 {
      builder.write_string(",")
    }
    let mut bounds = board_rect(0.0, 0.0, 0.0, 0.0)
    let mut viewport = bounds
    let mut visible = false
    for lane in lanes {
      if lane.lane == id {
        bounds = lane.bounds
        viewport = lane.viewport
        visible = true
      }
    }
    let count = lane_tasks(model, id).length()
    let total = model.tasks.filter(task => task.lane == id).length()
    builder.write_string(
      "{\"id\":\{id},\"name\":\{json_quote(lane_name(id))},\"count\":\{count},\"total\":\{total},\"visible\":\{visible},\"bounds\":\{bounds_json(bounds)},\"viewport\":\{bounds_json(viewport)},\"scrollY\":\{model.scrolls[id].offset().y()},\"maxScrollY\":\{model.scrolls[id].max_offset().y()}}",
    )
  }
  builder.write_string("],\"nodes\":[")
  let mut count = 0
  for lane in lanes {
    for card in board_cards(model, lane) {
      if count > 0 {
        builder.write_string(",")
      }
      let task = card.task
      builder.write_string(
        "{\"id\":\{task.id},\"role\":\"button\",\"name\":\{json_quote(task.title)},\"selected\":\{model.selected == Some(task.id)},\"lane\":\{task.lane},\"bounds\":\{bounds_json(card.visible_bounds)}}",
      )
      count += 1
    }
  }
  builder.write_string("]}")
  builder.to_string()
}
