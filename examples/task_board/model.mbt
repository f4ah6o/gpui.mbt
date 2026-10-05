///|
/// Errors at the portable demo boundary. Host callbacks only validate and
/// enqueue values; the application changes during `render_frame`.
pub(all) enum BoardError {
  Stopped
  InvalidViewport
  InvalidInput
  InvalidCommand
  QueueFull
  AppFailure
  LayoutFailure
  SceneFailure
} derive(Eq)

///|
pub extend BoardError with Eq::{equal, not_equal}

///|
pub fn BoardError::code(self : BoardError) -> String {
  match self {
    Stopped => "stopped"
    InvalidViewport => "invalid_viewport"
    InvalidInput => "invalid_input"
    InvalidCommand => "invalid_command"
    QueueFull => "queue_full"
    AppFailure => "app_failure"
    LayoutFailure => "layout_failure"
    SceneFailure => "scene_failure"
  }
}

///|
pub fn BoardError::message(self : BoardError) -> String {
  match self {
    Stopped => "The task board has been disposed."
    InvalidViewport =>
      "Use a finite viewport from 1 to 8192 and scale greater than zero up to 8."
    InvalidInput =>
      "Use bounded input: title 1–80 trimmed characters, search up to 80, and finite coordinates."
    InvalidCommand =>
      "Unknown board command or invalid task or lane identifier."
    QueueFull =>
      "The board input queue is full; render a frame before adding more input."
    AppFailure => "The portable application could not update its model."
    LayoutFailure => "The portable board layout could not be constructed."
    SceneFailure => "The portable board scene could not be constructed."
  }
}

///|
priv struct Task {
  id : Int
  title : String
  lane : Int
  priority : String
  detail : String
}

///|
priv enum UndoAction {
  Added(Int, Int?)
  Moved(Int, Int, Int?)
}

///|
priv enum BoardCommand {
  Select(Int)
  Move(Int, Int)
  Add(String)
  Query(String)
  Undo
  Lane(Int)
  Cancel
}

///|
struct QueuedCommand {
  sequence : Int64
  command : BoardCommand
}

///|
struct BoardModel {
  tasks : Array[Task]
  history : Array[UndoAction]
  scrolls : Array[@element.ScrollState]
  mut next_id : Int
  mut selected : Int?
  mut query : String
  mut active_lane : Int
  mut width : Double
  mut height : Double
  mut scale : Double
  mut focused : Bool
  mut visible : Bool
  mut pointer : @primitives.Point?
  mut hover : Int?
  mut drag : @element.DragGesture
  mut drop_lane : Int?
  mut message : String
  mut events : Int
  mut last_sequence : Int64
}

///|
/// A portable task-board application. All domain state, history, scrolling,
/// layout, hit testing, and drag behavior stay in its shared App entity.
pub struct BoardDemo {
  app : @core.App
  model : @core.Entity[BoardModel]
  ingress : @platform.EventIngress
  commands : Array[QueuedCommand]
  mut host_width : Double
  mut host_height : Double
  mut host_scale : Double
  mut stopped : Bool
}

///|
fn seed_tasks() -> Array[Task] {
  [
    {
      id: 1,
      title: "Write the launch announcement",
      lane: 0,
      priority: "high",
      detail: "Content · Maya",
    },
    {
      id: 2,
      title: "Check the signup flow",
      lane: 0,
      priority: "high",
      detail: "Quality · Alex",
    },
    {
      id: 3,
      title: "日本語の案内を確認する",
      lane: 0,
      priority: "medium",
      detail: "Localization · Yuki",
    },
    {
      id: 4,
      title: "Capture product screenshots",
      lane: 0,
      priority: "medium",
      detail: "Design · Sam",
    },
    {
      id: 5,
      title: "Review the keyboard shortcuts",
      lane: 0,
      priority: "high",
      detail: "Accessibility · Alex",
    },
    {
      id: 6,
      title: "Prepare the support checklist",
      lane: 0,
      priority: "medium",
      detail: "Operations · Maya",
    },
    {
      id: 7,
      title: "Polish the empty states",
      lane: 0,
      priority: "low",
      detail: "Design · Sam",
    },
    {
      id: 8,
      title: "Build the project overview",
      lane: 1,
      priority: "high",
      detail: "Product · Alex",
    },
    {
      id: 9,
      title: "Test the mobile layout",
      lane: 1,
      priority: "high",
      detail: "Quality · Yuki",
    },
    {
      id: 10,
      title: "Draft the getting started guide",
      lane: 1,
      priority: "medium",
      detail: "Content · Maya",
    },
    {
      id: 11,
      title: "Choose the project name",
      lane: 2,
      priority: "low",
      detail: "Product · Team",
    },
    {
      id: 12,
      title: "Set up the shared workspace",
      lane: 2,
      priority: "medium",
      detail: "Operations · Sam",
    },
  ]
}

///|
fn empty_scroll() -> @element.ScrollState {
  @element.ScrollState::new(board_size(1.0, 1.0), board_size(1.0, 1.0))
}

///|
fn initial_board() -> BoardModel {
  let drag = match @element.DragGesture::new(5.0) {
    Ok(value) => value
    Err(_) => abort("the board uses a valid drag threshold")
  }
  let model : BoardModel = {
    tasks: seed_tasks(),
    history: [],
    scrolls: [empty_scroll(), empty_scroll(), empty_scroll()],
    next_id: 13,
    selected: Some(1),
    query: "",
    active_lane: 0,
    width: 1000.0,
    height: 520.0,
    scale: 1.0,
    focused: false,
    visible: true,
    pointer: None,
    hover: None,
    drag,
    drop_lane: None,
    message: "Ready for the next release",
    events: 0,
    last_sequence: 0,
  }
  refresh_scrolls(model)
  model
}

///|
fn BoardDemo::current_board(self : BoardDemo) -> Result[BoardModel, BoardError] {
  match self.app.read(self.model, value => value) {
    Ok(value) => Ok(value)
    Err(_) => Err(AppFailure)
  }
}

///|
fn task_index(model : BoardModel, id : Int) -> Int? {
  for index, task in model.tasks {
    if task.id == id {
      return Some(index)
    }
  }
  None
}

///|
fn find_task(model : BoardModel, id : Int) -> Task? {
  match task_index(model, id) {
    Some(index) => Some(model.tasks[index])
    None => None
  }
}

///|
fn matches_query(task : Task, query : String) -> Bool {
  query == "" ||
  task.title.to_lower().contains(query.to_lower()) ||
  task.detail.to_lower().contains(query.to_lower())
}

///|
fn lane_tasks(model : BoardModel, lane : Int) -> Array[Task] {
  let values : Array[Task] = []
  for task in model.tasks {
    if task.lane == lane && matches_query(task, model.query) {
      values.push(task)
    }
  }
  values
}

///|
fn filtered_tasks(model : BoardModel) -> Array[Task] {
  let values : Array[Task] = []
  for lane in 0..<3 {
    for task in lane_tasks(model, lane) {
      values.push(task)
    }
  }
  values
}

///|
fn reconcile_selection(model : BoardModel) -> Unit {
  match model.selected {
    Some(id) =>
      match find_task(model, id) {
        Some(task) => if matches_query(task, model.query) { return }
        None => ()
      }
    None => ()
  }
  let tasks = filtered_tasks(model)
  if tasks.length() > 0 {
    model.selected = Some(tasks[0].id)
    model.active_lane = tasks[0].lane
  } else {
    model.selected = None
  }
}

///|
fn cancel_drag(model : BoardModel) -> Unit {
  model.drag = model.drag.cancel()
  model.drop_lane = None
}

///|
fn remember(model : BoardModel, action : UndoAction) -> Unit {
  if model.history.length() == 32 {
    ignore(model.history.remove(0))
  }
  model.history.push(action)
}

///|
fn select_task(model : BoardModel, id : Int) -> Unit {
  match find_task(model, id) {
    Some(task) =>
      if matches_query(task, model.query) {
        model.selected = Some(id)
        model.active_lane = task.lane
        ensure_selection_visible(model)
      }
    None => ()
  }
}

///|
fn move_task(model : BoardModel, id : Int, lane : Int) -> Unit {
  match task_index(model, id) {
    None => model.message = "That task is no longer available"
    Some(index) => {
      let task = model.tasks[index]
      if task.lane != lane {
        remember(model, Moved(id, task.lane, model.selected))
        model.tasks[index] = { ..task, lane, }
        model.selected = Some(id)
        model.active_lane = lane
        model.message = "Moved “\{task.title}” to \{lane_name(lane)}"
        refresh_scrolls(model)
        reconcile_selection(model)
        ensure_selection_visible(model)
      }
    }
  }
}

///|
fn undo(model : BoardModel) -> Unit {
  if model.history.length() == 0 {
    model.message = "Nothing to undo"
    return
  }
  let action = model.history.remove(model.history.length() - 1)
  match action {
    Added(id, selected) => {
      match task_index(model, id) {
        Some(index) => ignore(model.tasks.remove(index))
        None => ()
      }
      model.selected = selected
      model.message = "Undid the last added task"
    }
    Moved(id, lane, selected) => {
      match task_index(model, id) {
        Some(index) => model.tasks[index] = { ..model.tasks[index], lane, }
        None => ()
      }
      model.selected = selected
      model.message = "Undid the last task move"
    }
  }
  refresh_scrolls(model)
  reconcile_selection(model)
  match model.selected {
    Some(id) =>
      match find_task(model, id) {
        Some(task) => model.active_lane = task.lane
        None => ()
      }
    None => ()
  }
  refresh_scrolls(model)
  ensure_selection_visible(model)
}

///|
fn refresh_hover(model : BoardModel) -> Unit {
  model.hover = match model.pointer {
    Some(point) => if model.visible { hit_card(model, point) } else { None }
    None => None
  }
}

///|
fn apply_command(model : BoardModel, command : BoardCommand) -> Unit {
  // A semantic focus proxy may confirm the selection caused by the same
  // pointer down. Reaffirming that exact card must not erase its new gesture.
  match command {
    Select(id) => if model.selected != Some(id) { cancel_drag(model) }
    _ => cancel_drag(model)
  }
  match command {
    Select(id) => select_task(model, id)
    Move(id, lane) => move_task(model, id, lane)
    Add(title) => {
      if model.tasks.length() >= 100 || model.next_id >= 1_000_000 {
        model.message = "The demo holds up to 100 tasks; undo an addition to make room"
        return
      }
      let id = model.next_id
      model.next_id += 1
      remember(model, Added(id, model.selected))
      model.tasks.push({
        id,
        title,
        lane: 0,
        priority: "medium",
        detail: "New task · You",
      })
      model.query = ""
      model.selected = Some(id)
      model.active_lane = 0
      model.message = "Added “\{title}” to Backlog"
      refresh_scrolls(model)
      ensure_selection_visible(model)
    }
    Query(query) => {
      model.query = query
      for lane in 0..<3 {
        model.scrolls[lane] = match model.scrolls[lane].scroll_to(0.0, 0.0) {
          Ok(value) => value
          Err(_) => model.scrolls[lane]
        }
      }
      reconcile_selection(model)
      refresh_scrolls(model)
      ensure_selection_visible(model)
      let count = filtered_tasks(model).length()
      model.message = if query == "" {
        "Showing all tasks"
      } else {
        "\{count} matching tasks"
      }
    }
    Undo => undo(model)
    Lane(lane) => {
      model.active_lane = lane
      let tasks = lane_tasks(model, lane)
      let selected_in_lane = match model.selected {
        None => false
        Some(id) => tasks.any(task => task.id == id)
      }
      if !selected_in_lane {
        model.selected = if tasks.length() == 0 {
          None
        } else {
          Some(tasks[0].id)
        }
      }
      refresh_scrolls(model)
      ensure_selection_visible(model)
    }
    Cancel => {
      model.pointer = None
      model.hover = None
    }
  }
  refresh_hover(model)
}

///|
fn keyboard_select(model : BoardModel, key : @primitives.Key) -> Unit {
  let tasks = if model.width < 700.0 {
    lane_tasks(model, model.active_lane)
  } else {
    filtered_tasks(model)
  }
  if tasks.length() == 0 {
    model.selected = None
    return
  }
  let mut current = -1
  for index, task in tasks {
    if model.selected == Some(task.id) {
      current = index
    }
  }
  let next = match key {
    @primitives.Home => 0
    @primitives.End => tasks.length() - 1
    @primitives.ArrowUp =>
      if current < 0 {
        tasks.length() - 1
      } else if current > 0 {
        current - 1
      } else {
        0
      }
    _ => if current < tasks.length() - 1 { current + 1 } else { current }
  }
  select_task(model, tasks[next].id)
}

///|
fn apply_input(model : BoardModel, input : @primitives.InputEvent) -> Unit {
  match input {
    @primitives.PointerMoved(position~) => {
      model.pointer = Some(position)
      model.hover = if model.visible { hit_card(model, position) } else { None }
      model.drag = model.drag.update(position)
      model.drop_lane = if model.drag.is_dragging() {
        lane_at(model, position)
      } else {
        None
      }
    }
    @primitives.PointerButtonPressed(position~, button~, ..) => {
      cancel_drag(model)
      if !model.visible || !(button is @primitives.Primary) {
        return
      }
      model.focused = true
      model.pointer = Some(position)
      model.hover = hit_card(model, position)
      match model.hover {
        Some(id) => {
          select_task(model, id)
          model.drag = model.drag.begin(id.to_uint64(), position)
        }
        None => ()
      }
    }
    @primitives.PointerButtonReleased(position~, button~, ..) => {
      if !(button is @primitives.Primary) {
        return
      }
      let (next, released) = model.drag.release(position)
      model.drag = next
      model.drop_lane = None
      if model.visible && model.focused {
        match (released, lane_at(model, position)) {
          (Some(id), Some(lane)) => move_task(model, id.to_int(), lane)
          _ => ()
        }
      }
      model.pointer = Some(position)
      model.hover = if model.visible { hit_card(model, position) } else { None }
    }
    @primitives.Scroll(position~, delta~, ..) => {
      if !model.visible {
        return
      }
      cancel_drag(model)
      match lane_at(model, position) {
        Some(lane) => {
          model.scrolls[lane] = match
            model.scrolls[lane].scroll_by(0.0, delta.y()) {
            Ok(value) => value
            Err(_) => model.scrolls[lane]
          }
          model.pointer = Some(position)
          model.hover = hit_card(model, position)
        }
        None => ()
      }
    }
    @primitives.KeyPressed(key~, modifiers~, ..) => {
      if !model.focused || !model.visible {
        return
      }
      match key {
        @primitives.Escape => cancel_drag(model)
        @primitives.Character(value) =>
          if (modifiers.control() || modifiers.meta()) &&
            value.to_lower() == "z" &&
            !modifiers.shift() {
            cancel_drag(model)
            undo(model)
          }
        @primitives.ArrowLeft | @primitives.ArrowRight =>
          if modifiers.alt() {
            cancel_drag(model)
            match model.selected {
              Some(id) =>
                match find_task(model, id) {
                  Some(task) => {
                    let delta = if key is @primitives.ArrowLeft {
                      -1
                    } else {
                      1
                    }
                    let lane = task.lane + delta
                    if lane >= 0 && lane < 3 {
                      move_task(model, id, lane)
                    }
                  }
                  None => ()
                }
              None => ()
            }
          }
        @primitives.ArrowUp
        | @primitives.ArrowDown
        | @primitives.Home
        | @primitives.End => {
          cancel_drag(model)
          keyboard_select(model, key)
        }
        _ => ()
      }
      // Keyboard reveal, moves, and undo can change which clipped card sits
      // under an unmoved pointer. Reconcile after the new geometry is ready.
      refresh_hover(model)
    }
    @primitives.KeyReleased(..) | @primitives.TextInput(..) => ()
  }
}

///|
fn apply_event(
  model : BoardModel,
  event : @platform.Event,
  command : BoardCommand?,
) -> Unit {
  model.last_sequence = event.sequence()
  model.events += 1
  match event.kind() {
    @platform.Wake =>
      match command {
        Some(value) => apply_command(model, value)
        None => ()
      }
    @platform.Resized(width~, height~) => {
      cancel_drag(model)
      model.width = width
      model.height = height
      model.hover = None
      refresh_scrolls(model)
      ensure_selection_visible(model)
    }
    @platform.ScaleChanged => {
      cancel_drag(model)
      model.scale = event.scale()
    }
    @platform.FocusChanged(focused) => {
      model.focused = focused
      if !focused {
        cancel_drag(model)
        model.hover = None
      }
    }
    @platform.VisibilityChanged(visible) => {
      model.visible = visible
      if !visible {
        cancel_drag(model)
        model.hover = None
      }
    }
    @platform.Input(input) => apply_input(model, input)
    @platform.Destroyed | @platform.CloseRequested | @platform.ExitRequested =>
      cancel_drag(model)
    _ => ()
  }
}

///|
pub fn BoardDemo::new() -> Result[BoardDemo, BoardError] {
  let app = match @core.App::new() {
    Ok(value) => value
    Err(_) => return Err(AppFailure)
  }
  match app.start() {
    Ok(_) => ()
    Err(_) => return Err(AppFailure)
  }
  let model = match app.create_entity(initial_board()) {
    Ok(value) => value
    Err(_) => return Err(AppFailure)
  }
  Ok({
    app,
    model,
    ingress: @platform.EventIngress::new(@platform.WindowId::new(2)),
    commands: [],
    host_width: 1000.0,
    host_height: 520.0,
    host_scale: 1.0,
    stopped: false,
  })
}

///|
fn BoardDemo::enqueue(
  self : BoardDemo,
  kind : @platform.EventKind,
  scale : Double,
) -> Result[Int64, BoardError] {
  if self.stopped {
    return Err(Stopped)
  }
  if self.ingress.pending_count() >= 1024 {
    return Err(QueueFull)
  }
  match self.ingress.enqueue(kind, scale) {
    Ok(value) => Ok(value.sequence())
    Err(_) => Err(AppFailure)
  }
}

///|
fn BoardDemo::enqueue_command(
  self : BoardDemo,
  command : BoardCommand,
) -> Result[Unit, BoardError] {
  match self.enqueue(@platform.Wake, self.host_scale) {
    Err(error) => Err(error)
    Ok(sequence) => {
      self.commands.push({ sequence, command, })
      Ok(())
    }
  }
}

///|
fn BoardDemo::queue_input(
  self : BoardDemo,
  input : @primitives.InputEvent,
) -> Result[Unit, BoardError] {
  match self.enqueue(@platform.Input(input), self.host_scale) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
fn bounded_point(
  x : Double,
  y : Double,
) -> Result[@primitives.Point, BoardError] {
  if x < -1_000_000.0 || x > 1_000_000.0 || y < -1_000_000.0 || y > 1_000_000.0 {
    return Err(InvalidInput)
  }
  match @primitives.Point::new(x, y) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidInput)
  }
}

///|
pub fn BoardDemo::set_viewport(
  self : BoardDemo,
  width : Double,
  height : Double,
  scale : Double,
) -> Result[Unit, BoardError] {
  if self.stopped {
    return Err(Stopped)
  }
  if width.is_nan() ||
    width.is_inf() ||
    height.is_nan() ||
    height.is_inf() ||
    scale.is_nan() ||
    scale.is_inf() ||
    width < 1.0 ||
    width > 8192.0 ||
    height < 1.0 ||
    height > 8192.0 ||
    scale <= 0.0 ||
    scale > 8.0 {
    return Err(InvalidViewport)
  }
  // Reserve both possible events before accepting either, so queue exhaustion
  // cannot leave host viewport metadata partially updated.
  if self.ingress.pending_count() > 1022 {
    return Err(QueueFull)
  }
  if scale != self.host_scale {
    match self.enqueue(@platform.ScaleChanged, scale) {
      Ok(_) => self.host_scale = scale
      Err(error) => return Err(error)
    }
  }
  if width != self.host_width || height != self.host_height {
    match self.enqueue(@platform.Resized(width~, height~), scale) {
      Ok(_) => {
        self.host_width = width
        self.host_height = height
      }
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
pub fn BoardDemo::pointer_move(
  self : BoardDemo,
  x : Double,
  y : Double,
) -> Result[Unit, BoardError] {
  match bounded_point(x, y) {
    Ok(position) => self.queue_input(@primitives.PointerMoved(position~))
    Err(error) => Err(error)
  }
}

///|
pub fn BoardDemo::pointer_button(
  self : BoardDemo,
  x : Double,
  y : Double,
  pressed : Bool,
) -> Result[Unit, BoardError] {
  match bounded_point(x, y) {
    Err(error) => Err(error)
    Ok(position) => {
      let button = @primitives.Primary
      let modifiers = @primitives.Modifiers::none()
      self.queue_input(
        if pressed {
          @primitives.PointerButtonPressed(position~, button~, modifiers~)
        } else {
          @primitives.PointerButtonReleased(position~, button~, modifiers~)
        },
      )
    }
  }
}

///|
pub fn BoardDemo::scroll(
  self : BoardDemo,
  x : Double,
  y : Double,
  dx : Double,
  dy : Double,
) -> Result[Unit, BoardError] {
  match (bounded_point(x, y), bounded_point(dx, dy)) {
    (Ok(position), Ok(delta)) =>
      self.queue_input(
        @primitives.Scroll(
          position~,
          delta~,
          modifiers=@primitives.Modifiers::none(),
        ),
      )
    _ => Err(InvalidInput)
  }
}

///|
pub fn BoardDemo::key(
  self : BoardDemo,
  key : String,
  shift : Bool,
  control : Bool,
  alt : Bool,
  meta : Bool,
) -> Result[Unit, BoardError] {
  if key.length() == 0 || key.length() > 32 {
    return Err(InvalidInput)
  }
  let key = match key {
    "Escape" => @primitives.Escape
    "ArrowLeft" => @primitives.ArrowLeft
    "ArrowRight" => @primitives.ArrowRight
    "ArrowUp" => @primitives.ArrowUp
    "ArrowDown" => @primitives.ArrowDown
    "Home" => @primitives.Home
    "End" => @primitives.End
    _ => @primitives.Character(key)
  }
  self.queue_input(
    @primitives.KeyPressed(
      key~,
      modifiers=@primitives.Modifiers::new(shift~, control~, alt~, meta~),
      repeat=false,
    ),
  )
}

///|
pub fn BoardDemo::focus(
  self : BoardDemo,
  focused : Bool,
) -> Result[Unit, BoardError] {
  match self.enqueue(@platform.FocusChanged(focused), self.host_scale) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
pub fn BoardDemo::visible(
  self : BoardDemo,
  visible : Bool,
) -> Result[Unit, BoardError] {
  match self.enqueue(@platform.VisibilityChanged(visible), self.host_scale) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
pub fn BoardDemo::cancel(self : BoardDemo) -> Result[Unit, BoardError] {
  self.enqueue_command(Cancel)
}

///|
/// Commands share EventIngress sequence numbers with pointer, keyboard, and
/// lifecycle events, so a command never jumps ahead of already queued input.
pub fn BoardDemo::command(
  self : BoardDemo,
  kind : String,
  id : Int,
  value : String,
) -> Result[Unit, BoardError] {
  if self.stopped {
    return Err(Stopped)
  }
  if kind.length() > 16 || value.length() > 80 {
    return Err(InvalidInput)
  }
  let command = match kind {
    "select" =>
      if id > 0 && id < 1_000_000 {
        Select(id)
      } else {
        return Err(InvalidCommand)
      }
    "move" => {
      if id <= 0 || id >= 1_000_000 {
        return Err(InvalidCommand)
      }
      let lane = match value {
        "0" => 0
        "1" => 1
        "2" => 2
        _ => return Err(InvalidCommand)
      }
      Move(id, lane)
    }
    "add" => {
      let title = value.trim().to_owned()
      if title.length() == 0 {
        return Err(InvalidInput)
      }
      for ch in title.iter() {
        if ch.to_int() < 32 || ch.to_int() == 127 {
          return Err(InvalidInput)
        }
      }
      Add(title)
    }
    "query" => Query(value.trim().to_owned())
    "undo" => Undo
    "lane" =>
      if id >= 0 && id < 3 {
        Lane(id)
      } else {
        return Err(InvalidCommand)
      }
    _ => return Err(InvalidCommand)
  }
  self.enqueue_command(command)
}

///|
pub fn BoardDemo::render_frame(
  self : BoardDemo,
) -> Result[@scene.SceneSnapshot, BoardError] {
  if self.stopped {
    return Err(Stopped)
  }
  for event in self.ingress.drain() {
    let command = if self.commands.length() > 0 &&
      self.commands[0].sequence == event.sequence() {
      Some(self.commands.remove(0).command)
    } else {
      None
    }
    match
      self.app.update(self.model, context => {
        match context.get() {
          Err(error) => Err(error)
          Ok(model) => {
            apply_event(model, event, command)
            context.set(model)
          }
        }
      }) {
      Ok(_) => ()
      Err(_) => return Err(AppFailure)
    }
    match self.app.run_ready(64) {
      Ok(_) => ()
      Err(_) => return Err(AppFailure)
    }
  }
  match self.current_board() {
    Ok(model) => board_scene(model)
    Err(error) => Err(error)
  }
}

///|
pub fn BoardDemo::dispose(self : BoardDemo) -> Unit {
  if !self.stopped {
    self.stopped = true
    self.ingress.close()
    self.commands.clear()
    ignore(self.app.request_stop())
    ignore(self.app.run_ready(64))
  }
}

///|
pub fn json_quote(value : String) -> String {
  "\"\{@capability.json_escape(value)}\""
}
