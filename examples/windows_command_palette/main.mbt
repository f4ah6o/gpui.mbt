///|
extern "C" fn native_palette_flush_stdout() -> Unit = "gpui_windows_palette_flush_stdout"

///|
fn palette_log(line : String) -> Unit {
  println(line)
  native_palette_flush_stdout()
}

///|
fn[T] required(value : Result[T, @diagnostics.FrameworkError]) -> T {
  match value {
    Ok(value) => value
    Err(error) => abort("\{error.operation()}: \{error.code().label()}")
  }
}

///|
fn report(error : @diagnostics.FrameworkError) -> Unit {
  palette_log("\{error.operation()}: \{error.code().label()}")
}

///|
struct PaletteFixture {
  palette : @palette.CommandPalette
  tree : Ref[@element.ElementTree]
  actions : Ref[Int]
  last_action : Ref[String]
  background_presses : Ref[Int]
  background_releases : Ref[Int]
  native_begins : Ref[Int]
  native_updates : Ref[Int]
  native_cancels : Ref[Int]
  native_ends : Ref[Int]
  native_records : Ref[Int]
  stale_records : Ref[Int]
  rejected_records : Ref[Int]
  guarded_presses : Ref[Int]
  guarded_releases : Ref[Int]
}

///|
fn palette_fixture() -> PaletteFixture {
  let bounds = @primitives.Rect::new(24.0, 28.0, 512.0, 44.0).unwrap()
  let field = palette_field(bounds).unwrap()
  let viewport = @primitives.Rect::new(0.0, 0.0, 640.0, 480.0).unwrap()
  let background_bounds = @primitives.Rect::new(24.0, 414.0, 360.0, 40.0).unwrap()
  let tree = Ref(
    @element.ElementTree::new([
      @element.ElementNode::new(1, None, viewport).with_pointer_events(false),
      @element.ElementNode::new(9, Some(1), background_bounds).with_focusable(
        true,
      ),
      field.element_node(Some(1)),
    ])
    .unwrap()
    .with_focus(9)
    .unwrap(),
  )
  let actions = Ref(0)
  let last_action = Ref("")
  let commands = []
  let labels = [
    "Open settings", "Go to file", "Disabled command", "日本語設定", "Format document",
    "Find in project", "Open recent file", "Toggle terminal", "Toggle sidebar", "Jump to line",
    "Open command", "Theme: Dark", "About gpui.mbt", "Check for updates", "Close window",
    "Command history",
  ]
  for index = 0; index < labels.length(); index = index + 1 {
    let id = "palette.command.\{index}"
    let label = labels[index]
    let enabled = index != 2
    let metadata = @palette.CommandMetadata::new(id, label, enabled).unwrap()
    let descriptor = @capability.Descriptor::new(
      id,
      label,
      "Bounded Windows command-palette fixture action",
      @capability.Command,
      @capability.Schema::unit(),
      @capability.Schema::unit(),
      @capability.StateChange,
      false,
      @capability.Local,
      None,
      1,
    ).unwrap()
    let binding = @capability.TypedCapability::new(
      descriptor,
      _ => Ok(()),
      _ => Ok(@capability.Value::unit()),
      _ => {
        actions.val += 1
        last_action.val = id
        Ok(())
      },
      () => Ok(()),
      _ => Ok(()),
    ).gui_binding()
    commands.push(@palette.PaletteCommand::new(metadata, binding))
  }
  {
    palette: @palette.CommandPalette::new(field, commands).unwrap(),
    tree,
    actions,
    last_action,
    background_presses: Ref(0),
    background_releases: Ref(0),
    native_begins: Ref(0),
    native_updates: Ref(0),
    native_cancels: Ref(0),
    native_ends: Ref(0),
    native_records: Ref(0),
    stale_records: Ref(0),
    rejected_records: Ref(0),
    guarded_presses: Ref(0),
    guarded_releases: Ref(0),
  }
}

///|
fn palette_label(
  id : UInt64,
  label : String,
  x : Double,
  y : Double,
  color : @primitives.Color,
  clip : Int?,
) -> Result[@scene.SceneItem, @palette.PaletteError] {
  let document = match @text.TextDocument::new(label) {
    Ok(value) => value
    Err(_) => return Err(@palette.InvalidField)
  }
  let measurement = match palette_measure(document) {
    Ok(value) => value
    Err(_) => return Err(@palette.InvalidField)
  }
  match palette_admit(document, measurement) {
    Err(_) => return Err(@palette.InvalidField)
    Ok(_) => ()
  }
  let (origin, bounds) = match
    @text_field.scene_text_run_geometry(measurement) {
    Ok(value) => value
    Err(_) => return Err(@palette.InvalidField)
  }
  match
    @scene.SceneItem::text_run(
      id,
      bounds,
      origin,
      label,
      FIELD_FONT_SIZE,
      color,
      @scene.AffineTransform::new(1.0, 0.0, 0.0, 1.0, x, y).unwrap(),
      1.0,
      clip,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(@palette.InvalidField)
  }
}

///|
fn palette_scene(
  fixture : PaletteFixture,
  width : Double,
  height : Double,
  scale : Double,
) -> Result[@scene.SceneSnapshot, @palette.PaletteError] {
  let viewport = match @primitives.Rect::new(0.0, 0.0, width, height) {
    Ok(value) => value
    Err(_) => return Err(@palette.InvalidField)
  }
  let background = @primitives.Color::rgba(24, 28, 36, 255).unwrap()
  let white = @primitives.Color::rgba(238, 242, 248, 255).unwrap()
  let items : Array[@scene.SceneItem] = []
  let clips : Array[@scene.ClipChain] = []
  items.push(
    @scene.SceneItem::quad(
      1,
      viewport,
      background,
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ).unwrap(),
  )
  if fixture.palette.is_open() {
    let panel = @primitives.Rect::new(16.0, 16.0, 544.0, 384.0).unwrap()
    items.push(
      @scene.SceneItem::quad(
        2,
        panel,
        @primitives.Color::rgba(34, 39, 49, 255).unwrap(),
        @scene.AffineTransform::identity(),
        1.0,
        None,
      ).unwrap(),
    )
    let field = fixture.palette.field()
    let (field_clip, field_items) = match field.paint_items(100, 7) {
      Ok(value) => value
      Err(_) => return Err(@palette.InvalidField)
    }
    clips.push(field_clip)
    for item in field_items {
      items.push(item)
    }
    match palette_label(120, "Search commands", 24.0, 80.0, white, None) {
      Ok(value) => items.push(value)
      Err(error) => return Err(error)
    }
    let picker = fixture.palette.picker()
    let (list_clip, rows) = match
      picker.paint_items(
        200,
        8,
        @primitives.Rect::new(24.0, 100.0, 512.0, 288.0).unwrap(),
        36.0,
        (id, command, position, clip) => {
          let color = if command.is_enabled() {
            white
          } else {
            @primitives.Color::rgba(128, 132, 140, 255).unwrap()
          }
          palette_label(
            id,
            command.label(),
            position.x(),
            position.y(),
            color,
            Some(clip),
          )
        },
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    clips.push(list_clip)
    for item in rows {
      items.push(item)
    }
    if picker.match_count() == 0 {
      match
        palette_label(220, "No matching commands", 32.0, 110.0, white, Some(8)) {
        Ok(value) => items.push(value)
        Err(error) => return Err(error)
      }
    }
    match
      palette_label(
        230,
        "Ctrl+K opens  •  arrows navigate  •  Enter selects  •  Esc closes",
        24.0,
        388.0,
        white,
        None,
      ) {
      Ok(value) => items.push(value)
      Err(error) => return Err(error)
    }
  } else {
    let button_bounds = @primitives.Rect::new(24.0, 414.0, 360.0, 40.0).unwrap()
    items.push(
      @scene.SceneItem::quad(
        3,
        button_bounds,
        @primitives.Color::rgba(48, 74, 114, 255).unwrap(),
        @scene.AffineTransform::identity(),
        1.0,
        None,
      ).unwrap(),
    )
    match
      palette_label(
        4,
        "Open command palette (click or Ctrl+K)",
        32.0,
        424.0,
        white,
        None,
      ) {
      Ok(value) => items.push(value)
      Err(error) => return Err(error)
    }
  }
  match
    palette_label(
      240,
      "Actions: \{fixture.actions.val}    Background keys: \{fixture.background_presses.val}",
      24.0,
      462.0,
      white,
      None,
    ) {
    Ok(value) => items.push(value)
    Err(error) => return Err(error)
  }
  match @scene.SceneSnapshot::new(viewport, scale, [], clips, items) {
    Ok(value) => Ok(value)
    Err(_) => Err(@palette.InvalidField)
  }
}

///|
fn palette_owner_json(owner : PaletteNativeOwner?) -> Json {
  match owner {
    None => Json::null()
    Some(value) =>
      {
        "owner_generation": value.owner_generation.to_json(),
        "palette_open_epoch": value.open_epoch.to_json(),
        "native_epoch": value.epoch.to_json(),
        "sequence": value.sequence.to_json(),
        "composing": (value.composition is Some(_)).to_json(),
      }
  }
}

///|
fn palette_state_line(
  fixture : PaletteFixture,
  presentation : Int,
  width : Double,
  height : Double,
  scale : Double,
  owner : PaletteNativeOwner?,
  experimental_ime : Bool,
) -> String {
  let palette = fixture.palette
  let semantics = palette.semantics()
  let options = semantics.options.map(option => {
    "id": option.id.to_json(),
    "name": option.name.to_json(),
    "selected": option.selected.to_json(),
    "disabled": option.disabled.to_json(),
    "index": option.index.to_json(),
  })
  let active_id : Json = match semantics.active_id {
    Some(value) => value.to_json()
    None => Json::null()
  }
  let field = palette.field()
  let selection = field.selection()
  let focus_owner : Json = match fixture.tree.val.focused() {
    Some(value) => value.to_int().to_json()
    None => Json::null()
  }
  let caret : Json = match windows_palette_caret_rect(palette.field()) {
    Ok(value) =>
      {
        "x": value.left().to_json(),
        "y": value.top().to_json(),
        "width": value.size().width().to_json(),
        "height": value.size().height().to_json(),
      }.to_json()
    Err(_) => Json::null()
  }
  let value : Json = {
    "version": (1).to_json(),
    "presentation": presentation.to_json(),
    "open": palette.is_open().to_json(),
    "open_epoch": palette.open_epoch().to_json(),
    "query": palette.picker().query().to_json(),
    "field_text": field.document().text().to_json(),
    "committed_text": field.committed_document().text().to_json(),
    "composing": field.is_composing().to_json(),
    "selection": {
      "anchor": selection.anchor().to_json(),
      "head": selection.head().to_json(),
    }.to_json(),
    "matches": palette.picker().match_count().to_json(),
    "active_id": active_id,
    "active_index": palette.picker().active_index().to_json(),
    "visible_start": palette.picker().visible_start().to_json(),
    "visible_count": semantics.options.length().to_json(),
    "actions": fixture.actions.val.to_json(),
    "last_action": fixture.last_action.val.to_json(),
    "background_presses": fixture.background_presses.val.to_json(),
    "background_releases": fixture.background_releases.val.to_json(),
    "guarded_presses": fixture.guarded_presses.val.to_json(),
    "guarded_releases": fixture.guarded_releases.val.to_json(),
    "focus_owner": focus_owner,
    "field_focused": palette.field().is_focused().to_json(),
    "caret": caret,
    "experimental_imm32": experimental_ime.to_json(),
    "native_owner": palette_owner_json(owner),
    "native_counters": {
      "begin": fixture.native_begins.val.to_json(),
      "update": fixture.native_updates.val.to_json(),
      "cancel": fixture.native_cancels.val.to_json(),
      "end": fixture.native_ends.val.to_json(),
      "records": fixture.native_records.val.to_json(),
      "stale_records": fixture.stale_records.val.to_json(),
      "rejected_records": fixture.rejected_records.val.to_json(),
    }.to_json(),
    "viewport": {
      "logical_width": width.to_json(),
      "logical_height": height.to_json(),
      "scale": scale.to_json(),
      "font_family": FIELD_FONT_FAMILY.to_json(),
      "font_size": FIELD_FONT_SIZE.to_json(),
    }.to_json(),
    "semantic": {
      "role": semantics.role.to_json(),
      "name": semantics.name.to_json(),
      "search_role": semantics.search_role.to_json(),
      "search_name": semantics.search_name.to_json(),
      "search_value": semantics.search_value.to_json(),
      "search_focused": semantics.search_focused.to_json(),
      "collection_role": semantics.collection_role.to_json(),
      "options": options.to_json(),
    }.to_json(),
  }.to_json()
  "GPUI_WINDOWS_COMMAND_PALETTE_STATE \{value.stringify()}"
}

///|
fn readback_line(
  samples : Array[Double],
  presentation : Int,
  event_sequence : Int64,
  width : Double,
  height : Double,
  scale : Double,
) -> String {
  let pixel_width = (width * scale).to_int()
  let pixel_height = (height * scale).to_int()
  "GPUI_WINDOWS_COMMAND_PALETTE_READBACK {\"presentation\":\{presentation},\"frame_event_sequence\":\{event_sequence},\"samples\":[{\"point\":[1,1],\"rgba\":[\{samples[0]},\{samples[1]},\{samples[2]},\{samples[3]}]},{\"point\":[\{pixel_width / 4},\{pixel_height / 3}],\"rgba\":[\{samples[4]},\{samples[5]},\{samples[6]},\{samples[7]}]},{\"point\":[\{pixel_width - 2},\{pixel_height - 2}],\"rgba\":[\{samples[8]},\{samples[9]},\{samples[10]},\{samples[11]}]}]}"
}

///|
struct PendingFrame {
  presentation : Int
  open_epoch : Int
  query : String
  visible_count : Int
  active_id : String?
}

///|
/// Everything coupled to the exact SceneSnapshot passed to present. A Busy
/// result keeps this immutable prepared value intact for a retry.
struct PreparedPaletteFrame {
  scene : @scene.SceneSnapshot
  frame : PendingFrame
  field_text : String
  committed_text : String
  composing : Bool
  selection_anchor : Int
  selection_head : Int
  owner : PaletteNativeOwner?
  focus_owner : @element.FocusOwner?
  actions : Int
  dirty : Bool
  previous_pending : PendingFrame?
  width : Double
  height : Double
  scale : Double
}

///|
struct WindowPaletteInput {
  consumed : Bool
  effect : @palette.PaletteEffect
}

///|
fn pending_frame(fixture : PaletteFixture, presentation : Int) -> PendingFrame {
  let palette = fixture.palette
  {
    presentation,
    open_epoch: palette.open_epoch(),
    query: palette.picker().query(),
    visible_count: palette.semantics().options.length(),
    active_id: match palette.picker().active_command() {
      Some(value) => Some(value.id())
      None => None
    },
  }
}

///|
fn prepare_palette_frame(
  fixture : PaletteFixture,
  scene : @scene.SceneSnapshot,
  presentation : Int,
  owner : PaletteNativeOwner?,
  dirty : Bool,
  previous_pending : PendingFrame?,
  width : Double,
  height : Double,
  scale : Double,
) -> PreparedPaletteFrame {
  let field = fixture.palette.field()
  {
    scene,
    frame: pending_frame(fixture, presentation),
    field_text: field.document().text(),
    committed_text: field.committed_document().text(),
    composing: field.is_composing(),
    selection_anchor: field.selection().anchor(),
    selection_head: field.selection().head(),
    owner,
    focus_owner: fixture.tree.val.focus_owner(),
    actions: fixture.actions.val,
    dirty,
    previous_pending,
    width,
    height,
    scale,
  }
}

///|
fn pending_frame_matches(left : PendingFrame, right : PendingFrame) -> Bool {
  left.presentation == right.presentation &&
  left.open_epoch == right.open_epoch &&
  left.query == right.query &&
  left.visible_count == right.visible_count &&
  left.active_id == right.active_id
}

///|
fn palette_prepared_frame_matches_current(
  prepared : PreparedPaletteFrame,
  fixture : PaletteFixture,
  owner : PaletteNativeOwner?,
  dirty : Bool,
  pending : PendingFrame?,
  width : Double,
  height : Double,
  scale : Double,
) -> Bool {
  let palette = fixture.palette
  let field = palette.field()
  let active_id = match palette.picker().active_command() {
    Some(value) => Some(value.id())
    None => None
  }
  let owner_matches = match (prepared.owner, owner) {
    (None, None) => true
    (Some(left), Some(right)) =>
      left.owner_generation == right.owner_generation &&
      left.open_epoch == right.open_epoch &&
      left.epoch == right.epoch &&
      left.sequence == right.sequence &&
      (left.composition is Some(_)) == (right.composition is Some(_))
    _ => false
  }
  let prior_pending_matches = match (prepared.previous_pending, pending) {
    (None, None) => true
    (Some(_), None) => true
    (Some(left), Some(right)) => pending_frame_matches(left, right)
    (None, Some(_)) => false
  }
  prepared.dirty == dirty &&
  prepared.frame.open_epoch == palette.open_epoch() &&
  prepared.frame.query == palette.picker().query() &&
  prepared.frame.visible_count == palette.semantics().options.length() &&
  prepared.frame.active_id == active_id &&
  prepared.field_text == field.document().text() &&
  prepared.committed_text == field.committed_document().text() &&
  prepared.composing == field.is_composing() &&
  prepared.selection_anchor == field.selection().anchor() &&
  prepared.selection_head == field.selection().head() &&
  owner_matches &&
  prepared.focus_owner == fixture.tree.val.focus_owner() &&
  prepared.actions == fixture.actions.val &&
  prior_pending_matches &&
  prepared.width == width &&
  prepared.height == height &&
  prepared.scale == scale
}

///|
fn palette_opening_input(event : @primitives.InputEvent) -> Bool {
  match event {
    @primitives.KeyPressed(
      key=@primitives.Character("k")
      | @primitives.Character("K"),
      modifiers~,
      repeat=false
    ) => modifiers.control() && !modifiers.alt()
    _ => false
  }
}

///|
fn palette_contains_dialog_point(position : @primitives.Point) -> Bool {
  @primitives.Rect::new(16.0, 16.0, 544.0, 384.0).unwrap().contains(position)
}

///|
fn palette_handle_input(
  fixture : PaletteFixture,
  event : @primitives.InputEvent,
) -> Result[WindowPaletteInput, @palette.PaletteError] {
  let delivered : Ref[Result[WindowPaletteInput, @palette.PaletteError]?] = Ref(
    None,
  )
  ignore(
    fixture.tree.val.dispatch_input_with(event, (context, routed_event) => {
      if context.phase() == @element.Bubble &&
        context.current_target() == fixture.palette.field().id() {
        delivered.val = Some(
          match
            fixture.palette.handle_input(
              routed_event, palette_measure, palette_admit, palette_hit,
            ) {
            Ok(value) => Ok({ consumed: value.consumed, effect: value.effect, })
            Err(error) => Err(error)
          },
        )
      }
      Ok(())
    }),
  )
  match delivered.val {
    Some(value) => value
    None =>
      // The closed controller still owns a quarantined close/cancel key until
      // its native release arrives, even though ElementTree focus is restored.
      if !fixture.palette.is_open() {
        match
          fixture.palette.handle_input(
            event, palette_measure, palette_admit, palette_hit,
          ) {
          Ok(value) => Ok({ consumed: value.consumed, effect: value.effect, })
          Err(error) => Err(error)
        }
      } else {
        Ok({ consumed: false, effect: @palette.None, })
      }
  }
}

///|
fn palette_finish_effect(
  host : @native.Host,
  window : @platform.WindowId,
  fixture : PaletteFixture,
  owner : Ref[PaletteNativeOwner?],
  effect : @palette.PaletteEffect,
) -> Bool {
  match effect {
    @palette.Closed(epoch~, ..) => {
      let fenced = match palette_end_native_owner(host, window, owner.val) {
        Ok(_) => true
        Err(error) => {
          report(error)
          false
        }
      }
      if owner.val is Some(_) {
        fixture.native_ends.val += 1
      }
      owner.val = None
      match
        palette_finish_close_after_fence(
          fixture.palette,
          epoch,
          fixture.tree,
          fenced,
        ) {
        Ok(_) => fenced
        Err(_) => {
          palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT finish_close")
          false
        }
      }
    }
    @palette.CompositionCancelled =>
      match owner.val {
        Some(active) =>
          match palette_cancel_native_owner(host, window, active) {
            Ok(next) => {
              fixture.native_cancels.val += 1
              owner.val = Some(next)
              true
            }
            Err(error) => {
              report(error)
              owner.val = None
              false
            }
          }
        None => true
      }
    @palette.FieldAction(action) => {
      match action {
        @text_field.Copy(text) => ignore(host.write_clipboard(text))
        // The palette fixture does not expose cut/paste/clipboard writes.
        _ => ()
      }
      true
    }
    @palette.None => true
  }
}

///|
/// A hard presentation failure closes without a pending command. The native
/// end fence runs before focus can be restored; a failed fence leaves the
/// modal owner focused until the host shuts down.
fn palette_fail_closed_before_exit(
  fixture : PaletteFixture,
  owner : Ref[PaletteNativeOwner?],
  dirty : Ref[Bool],
  end_native : (PaletteNativeOwner?) -> Bool,
) -> Bool {
  dirty.val = false
  match fixture.palette.blur() {
    Err(_) => false
    Ok(@palette.Closed(epoch~, ..)) => {
      let fenced = end_native(owner.val)
      if owner.val is Some(_) {
        fixture.native_ends.val += 1
      }
      owner.val = None
      ignore(
        palette_finish_close_after_fence(
          fixture.palette,
          epoch,
          fixture.tree,
          fenced,
        ),
      )
      fenced
    }
    Ok(_) => false
  }
}

///|
/// Shared transition used by the native loop and regression tests. Busy keeps
/// the exact submitted scene and its coupled owner/picker/focus snapshot for
/// retry. A rejection invokes the fail-closed owner fence before returning.
fn palette_present_result(
  result : Result[Unit, @diagnostics.FrameworkError],
  prepared : PreparedPaletteFrame,
  fixture : PaletteFixture,
  owner : Ref[PaletteNativeOwner?],
  dirty : Ref[Bool],
  end_native : (PaletteNativeOwner?) -> Bool,
) -> (PaletteFrameDecision, PreparedPaletteFrame) {
  let decision = classify_palette_frame(result)
  if decision is RejectPending {
    ignore(palette_fail_closed_before_exit(fixture, owner, dirty, end_native))
  }
  (decision, prepared)
}

///|
fn palette_count_background_input(
  fixture : PaletteFixture,
  event : @primitives.InputEvent,
  consumed : Bool,
) -> Unit {
  if consumed {
    match event {
      @primitives.KeyPressed(key=@primitives.Enter | @primitives.Escape, ..) =>
        fixture.guarded_presses.val += 1
      @primitives.KeyReleased(key=@primitives.Enter | @primitives.Escape, ..) =>
        fixture.guarded_releases.val += 1
      _ => ()
    }
  } else if fixture.tree.val.focused() == Some(9UL) {
    match event {
      @primitives.KeyPressed(key=@primitives.Enter | @primitives.Escape, ..) =>
        fixture.background_presses.val += 1
      @primitives.KeyReleased(key=@primitives.Enter | @primitives.Escape, ..) =>
        fixture.background_releases.val += 1
      _ => ()
    }
  }
}

///|
fn palette_log_startup(
  host : @native.Host,
  window : @platform.WindowId,
  width : Double,
  height : Double,
  scale : Double,
  experimental_ime : Bool,
) -> Unit {
  let focus = match host.window_has_keyboard_focus(window) {
    Ok(value) => value
    Err(_) => false
  }
  palette_log(
    "GPUI_WINDOWS_COMMAND_PALETTE_START {\"profile\":\"Win32-D3D11-one-window\",\"logical_width\":\{width},\"logical_height\":\{height},\"scale\":\{scale},\"font\":\"Segoe UI 18px\",\"native_focus\":\{focus},\"experimental_imm32\":\{experimental_ime},\"readback\":\{(@env.get_env_var("GPUI_WINDOWS_READBACK") == Some("1"))}}",
  )
}

///|
fn run_palette_window() -> Unit {
  let host = required(@native.Host::start())
  let window = required(
    host.create_window(
      640, 480, "gpui.mbt — Windows command palette and Japanese IME",
    ),
  )
  required(host.require_capability(@platform.GrayscaleTextFrames))
  let fixture = palette_fixture()
  let palette = fixture.palette
  let width = Ref(640.0)
  let height = Ref(480.0)
  let scale = Ref(1.0)
  let owner : Ref[PaletteNativeOwner?] = Ref(None)
  let native_key_guard : Ref[PaletteNativeKeyGuard?] = Ref(None)
  let native_focused = Ref(false)
  let dirty = Ref(true)
  let native_external_edit = Ref(false)
  let experimental_ime = @env.get_env_var("GPUI_WINDOWS_COMMAND_PALETTE_IME") ==
    Some("1")
  let smoke = @env.get_env_var("GPUI_WINDOWS_COMMAND_PALETTE_SMOKE") ==
    Some("1")
  let mut presentation = 0
  let mut frame_completions = 0
  let mut pending : PendingFrame? = None
  let retry_prepared : Ref[PreparedPaletteFrame?] = Ref(None)
  if smoke {
    palette.open(fixture.tree).unwrap()
  }
  palette_log_startup(
    host,
    window,
    width.val,
    height.val,
    scale.val,
    experimental_ime,
  )
  palette_log(
    if experimental_ime {
      "Experimental Windows IMM32 owner is enabled; this does not by itself qualify a Japanese IME."
    } else {
      "Windows IMM32 text sessions are off by default; committed text input remains enabled."
    },
  )

  while host.state() == @native.Running {
    match host.next_editor_event(timeout_ms=16) {
      Err(error) => {
        report(error)
        ignore(host.request_exit())
      }
      Ok(None) => ()
      Ok(Some(@native.Platform(event))) => {
        match event.kind() {
          @platform.FrameCompleted => ()
          _ => retry_prepared.val = None
        }
        if event.window() == window {
          scale.val = event.scale()
          match event.kind() {
            @platform.Resized(width=w, height=h) => {
              width.val = w
              height.val = h
              dirty.val = true
            }
            @platform.ScaleChanged => dirty.val = true
            @platform.FocusChanged(focused) => {
              native_focused.val = focused
              if !focused && palette.is_open() {
                match palette.blur() {
                  Ok(effect) => {
                    dirty.val = true
                    if !palette_finish_effect(
                        host, window, fixture, owner, effect,
                      ) {
                      ignore(host.request_exit())
                    }
                  }
                  Err(_) => ignore(host.request_exit())
                }
              }
            }
            @platform.CloseRequested | @platform.Destroyed =>
              ignore(host.request_exit())
            @platform.Input(event_input) => {
              let (native_key_consumed, next_key_guard) = palette_native_guard_event(
                native_key_guard.val,
                event_input,
              )
              native_key_guard.val = next_key_guard
              if native_key_consumed {
                dirty.val = true
                palette_count_background_input(fixture, event_input, true)
              } else if !palette.is_open() {
                let prior_guard = palette_handle_input(fixture, event_input).unwrap()
                if prior_guard.consumed {
                  dirty.val = true
                  palette_count_background_input(fixture, event_input, true)
                } else {
                  let click_opener = match event_input {
                    @primitives.PointerButtonPressed(
                      position~,
                      button=@primitives.Primary,
                      ..
                    ) =>
                      @primitives.Rect::new(24.0, 414.0, 360.0, 40.0)
                      .unwrap()
                      .contains(position)
                    _ => false
                  }
                  if palette_opening_input(event_input) || click_opener {
                    match palette.open(fixture.tree) {
                      Ok(_) => dirty.val = true
                      Err(_) =>
                        palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT open")
                    }
                  } else {
                    palette_count_background_input(fixture, event_input, false)
                  }
                }
              } else {
                let composition_active = match owner.val {
                  Some(active) => active.composition is Some(_)
                  None => false
                }
                let input = event_input
                let native_key_disposition = palette_native_key_disposition(
                  owner.val,
                  palette.field(),
                  input,
                )
                let outside_dialog = match input {
                  @primitives.PointerButtonPressed(
                    position~,
                    button=@primitives.Primary,
                    ..
                  ) => !palette_contains_dialog_point(position)
                  _ => false
                }
                if outside_dialog {
                  match palette.blur() {
                    Ok(effect) => {
                      dirty.val = true
                      if !palette_finish_effect(
                          host, window, fixture, owner, effect,
                        ) {
                        ignore(host.request_exit())
                      }
                    }
                    Err(_) => ignore(host.request_exit())
                  }
                } else if native_key_disposition is CancelNativeComposition {
                  match owner.val {
                    Some(active) => {
                      let (original, cleared) = palette_native_cancel_composition(
                        active,
                      )
                      match original {
                        Some(candidate) =>
                          match
                            palette.install_field_at(
                              active.open_epoch,
                              candidate,
                            ) {
                            Ok(_) =>
                              match
                                palette_cancel_native_owner(
                                  host, window, cleared,
                                ) {
                                Ok(next) => {
                                  owner.val = Some(next)
                                  fixture.native_cancels.val += 1
                                  native_key_guard.val = Some(GuardEscape)
                                  fixture.guarded_presses.val += 1
                                  dirty.val = true
                                }
                                Err(error) => {
                                  report(error)
                                  owner.val = None
                                  ignore(host.request_exit())
                                }
                              }
                            Err(_) => {
                              fixture.rejected_records.val += 1
                              palette_log(
                                "GPUI_WINDOWS_COMMAND_PALETTE_REJECT escape_cancel_epoch",
                              )
                              ignore(host.request_exit())
                            }
                          }
                        None => {
                          fixture.rejected_records.val += 1
                          palette_log(
                            "GPUI_WINDOWS_COMMAND_PALETTE_REJECT escape_cancel_owner",
                          )
                          ignore(host.request_exit())
                        }
                      }
                    }
                    None => {
                      fixture.rejected_records.val += 1
                      ignore(host.request_exit())
                    }
                  }
                } else if native_key_disposition is NativeImeKey {
                  match palette_native_guard_for_press(input) {
                    Some(key) => {
                      native_key_guard.val = Some(key)
                      fixture.guarded_presses.val += 1
                      dirty.val = true
                    }
                    None => ()
                  }
                } else if composition_active &&
                  input
                  is @primitives.KeyPressed(
                    key=@primitives.Enter
                    | @primitives.Escape,
                    ..
                  ) {
                  match palette_handle_input(fixture, input) {
                    Ok(outcome) => {
                      dirty.val = true
                      if !palette_finish_effect(
                          host,
                          window,
                          fixture,
                          owner,
                          outcome.effect,
                        ) {
                        ignore(host.request_exit())
                      }
                    }
                    Err(_) =>
                      palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT input")
                  }
                } else if composition_active &&
                  input is @primitives.KeyPressed(..) {
                  // Native IMM32 owns conversion/navigation keys during an
                  // active composition. The palette's own field controller
                  // still reserves Enter and handles Escape above.
                } else if composition_active &&
                  input is @primitives.KeyReleased(..) {
                  // Keep the shared closing/cancelling-key quarantine live
                  // until this platform release reaches it.
                  let outcome = palette_handle_input(fixture, input).unwrap()
                  palette_count_background_input(
                    fixture,
                    input,
                    outcome.consumed,
                  )
                } else if input
                  is @primitives.PointerButtonPressed(
                    position~,
                    button=@primitives.Primary,
                    ..
                  ) &&
                  !palette.field().bounds().contains(position) {
                  // The bounded fixture navigates rows with the keyboard.
                  dirty.val = true
                } else {
                  let before = palette.field().committed_document()
                  match palette_handle_input(fixture, input) {
                    Ok(outcome) => {
                      if outcome.effect is @palette.FieldAction(_) {
                        ignore(
                          palette_finish_effect(
                            host,
                            window,
                            fixture,
                            owner,
                            outcome.effect,
                          ),
                        )
                      } else if !palette_finish_effect(
                          host,
                          window,
                          fixture,
                          owner,
                          outcome.effect,
                        ) {
                        ignore(host.request_exit())
                      }
                      if outcome.consumed {
                        dirty.val = true
                      }
                      if palette.is_open() &&
                        before != palette.field().committed_document() {
                        native_external_edit.val = true
                      }
                    }
                    Err(_) =>
                      palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT input")
                  }
                }
              }
            }
            @platform.FrameCompleted => {
              frame_completions += 1
              match pending {
                None =>
                  palette_log(
                    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE {\"presentation\":null,\"event_sequence\":\{event.sequence()}}",
                  )
                Some(frame) => {
                  let active_id = match frame.active_id {
                    Some(id) => id.to_json().stringify()
                    None => "null"
                  }
                  palette_log(
                    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE {\"presentation\":\{frame.presentation},\"event_sequence\":\{event.sequence()},\"open_epoch\":\{frame.open_epoch},\"query\":\{frame.query.to_json().stringify()},\"visible_count\":\{frame.visible_count},\"active_id\":\{active_id}}",
                  )
                  match host.readback_samples(window) {
                    Ok(samples) =>
                      palette_log(
                        readback_line(
                          samples,
                          frame.presentation,
                          event.sequence(),
                          width.val,
                          height.val,
                          scale.val,
                        ),
                      )
                    Err(error) =>
                      palette_log(
                        "GPUI_WINDOWS_COMMAND_PALETTE_READBACK_UNAVAILABLE {\"presentation\":\{frame.presentation},\"code\":\"\{error.code().label()}\"}",
                      )
                  }
                  pending = None
                  if smoke {
                    ignore(host.request_exit())
                  }
                }
              }
            }
            _ => ()
          }
        }
      }
      Ok(Some(@native.TextSession(target, event))) => {
        retry_prepared.val = None
        match owner.val {
          Some(active) if palette_native_target_current(
              palette, active, window, target,
            ) => {
            fixture.native_records.val += 1
            let accepted = palette_native_accept_event(active, target)
            owner.val = Some(accepted)
            match event {
              @native.CompositionStarted(replacement_range~) =>
                match
                  palette_native_start_composition(
                    accepted,
                    palette.field(),
                    replacement_range,
                  ) {
                  Some(next) => owner.val = Some(next)
                  None => {
                    fixture.rejected_records.val += 1
                    match palette_cancel_native_owner(host, window, accepted) {
                      Ok(next) => {
                        fixture.native_cancels.val += 1
                        owner.val = Some(next)
                      }
                      Err(error) => {
                        report(error)
                        owner.val = None
                        ignore(host.request_exit())
                      }
                    }
                  }
                }
              @native.Marked(
                text~,
                cursor_utf16~,
                attributes~,
                replacement_range~
              ) => {
                match
                  palette_native_update_mark(
                    accepted, text, cursor_utf16, attributes, replacement_range,
                  ) {
                  Ok((candidate, next)) =>
                    match
                      palette.install_field_at(active.open_epoch, candidate) {
                      Ok(_) => owner.val = Some(next)
                      Err(_) => {
                        fixture.rejected_records.val += 1
                        palette_log(
                          "GPUI_WINDOWS_COMMAND_PALETTE_REJECT marked_epoch",
                        )
                      }
                    }
                  Err(_) => {
                    fixture.rejected_records.val += 1
                    let (original, cleared) = palette_native_cancel_composition(
                      accepted,
                    )
                    match original {
                      Some(candidate) =>
                        match
                          palette.install_field_at(active.open_epoch, candidate) {
                          Ok(_) =>
                            match
                              palette_cancel_native_owner(host, window, cleared) {
                              Ok(next) => {
                                fixture.native_cancels.val += 1
                                owner.val = Some(next)
                              }
                              Err(error) => {
                                report(error)
                                owner.val = None
                                ignore(host.request_exit())
                              }
                            }
                          Err(_) => ignore(host.request_exit())
                        }
                      None => ()
                    }
                    palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT marked")
                  }
                }
                dirty.val = true
              }
              @native.Inserted(text~, replacement_range~) => {
                match
                  palette_native_append_result(
                    accepted,
                    palette.field(),
                    text,
                    replacement_range,
                  ) {
                  Ok((candidate, next)) =>
                    match
                      palette.install_field_at(active.open_epoch, candidate) {
                      Ok(_) => {
                        owner.val = Some(next)
                        native_external_edit.val = false
                      }
                      Err(_) => {
                        fixture.rejected_records.val += 1
                        palette_log(
                          "GPUI_WINDOWS_COMMAND_PALETTE_REJECT inserted_epoch",
                        )
                      }
                    }
                  Err(_) => {
                    fixture.rejected_records.val += 1
                    palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT inserted")
                    ignore(host.request_exit())
                  }
                }
                dirty.val = true
              }
              @native.CompositionEnded => {
                let (restored, next) = palette_native_end_composition(accepted)
                match restored {
                  Some(candidate) =>
                    match
                      palette.install_field_at(active.open_epoch, candidate) {
                      Ok(_) => {
                        owner.val = Some(next)
                        dirty.val = true
                      }
                      Err(_) => {
                        fixture.rejected_records.val += 1
                        ignore(host.request_exit())
                      }
                    }
                  None => owner.val = Some(next)
                }
              }
              @native.Cancelled => {
                let (restored, next) = palette_native_cancel_composition(
                  accepted,
                )
                match restored {
                  Some(candidate) =>
                    match
                      palette.install_field_at(active.open_epoch, candidate) {
                      Ok(_) => {
                        owner.val = Some(next)
                        dirty.val = true
                      }
                      Err(_) => {
                        fixture.rejected_records.val += 1
                        ignore(host.request_exit())
                      }
                    }
                  None => owner.val = Some(next)
                }
              }
            }
          }
          _ => fixture.stale_records.val += 1
        }
      }
    }

    if dirty.val && host.state() == @native.Running {
      let retained_retry = match retry_prepared.val {
        Some(value) if palette_prepared_frame_matches_current(
            value,
            fixture,
            owner.val,
            dirty.val,
            pending,
            width.val,
            height.val,
            scale.val,
          ) => Some(value)
        _ => {
          retry_prepared.val = None
          None
        }
      }
      let prepared = match retained_retry {
        Some(value) => Some(value)
        None =>
          match palette_scene(fixture, width.val, height.val, scale.val) {
            Err(_) => {
              palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT scene")
              ignore(
                palette_fail_closed_before_exit(fixture, owner, dirty, active => {
                  match palette_end_native_owner(host, window, active) {
                    Ok(_) => true
                    Err(error) => {
                      report(error)
                      false
                    }
                  }
                }),
              )
              ignore(host.request_exit())
              None
            }
            Ok(scene) =>
              Some(
                prepare_palette_frame(
                  fixture,
                  scene,
                  presentation + 1,
                  owner.val,
                  dirty.val,
                  pending,
                  width.val,
                  height.val,
                  scale.val,
                ),
              )
          }
      }
      match prepared {
        None => ()
        Some(prepared) => {
          let (decision, prepared) = palette_present_result(
            host.present(window, prepared.scene),
            prepared,
            fixture,
            owner,
            dirty,
            active => {
              match palette_end_native_owner(host, window, active) {
                Ok(_) => true
                Err(error) => {
                  report(error)
                  false
                }
              }
            },
          )
          match decision {
            Accepted => {
              presentation = prepared.frame.presentation
              pending = Some(prepared.frame)
              retry_prepared.val = None
              palette_log(
                "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED {\"presentation\":\{presentation},\"open_epoch\":\{prepared.frame.open_epoch},\"open\":\{palette.is_open()},\"query\":\{prepared.frame.query.to_json().stringify()},\"matches\":\{palette.picker().match_count()},\"visible_count\":\{prepared.frame.visible_count}}",
              )
              palette_log(
                palette_state_line(
                  fixture,
                  presentation,
                  prepared.width,
                  prepared.height,
                  prepared.scale,
                  prepared.owner,
                  experimental_ime,
                ),
              )
              if experimental_ime && palette.is_open() && native_focused.val {
                match owner.val {
                  None =>
                    match palette_begin_native_owner(host, window, palette) {
                      Ok(active) => {
                        owner.val = Some(active)
                        fixture.native_begins.val += 1
                      }
                      Err(error) => {
                        report(error)
                        ignore(host.request_exit())
                      }
                    }
                  Some(active) =>
                    match
                      palette_update_native_owner(
                        host,
                        window,
                        palette,
                        active,
                        native_external_edit.val,
                      ) {
                      Ok(next) => {
                        owner.val = Some(next)
                        fixture.native_updates.val += 1
                      }
                      Err(error) => {
                        report(error)
                        owner.val = None
                        ignore(host.request_exit())
                      }
                    }
                }
              }
              native_external_edit.val = false
              dirty.val = false
            }
            BusyPending => retry_prepared.val = Some(prepared)
            RecoverPending => {
              retry_prepared.val = Some(prepared)
              if host.recover_renderer(window) is Err(error) {
                report(error)
                dirty.val = false
                ignore(host.request_exit())
              }
            }
            RejectPending => {
              retry_prepared.val = None
              palette_log("GPUI_WINDOWS_COMMAND_PALETTE_REJECT presentation")
              ignore(host.request_exit())
            }
          }
        }
      }
    }
  }
  if palette_end_native_owner(host, window, owner.val) is Err(error) {
    report(error)
  }
  ignore(host.destroy_window(window))
  required(host.stop())
  if smoke && frame_completions == 0 {
    abort("Windows command-palette smoke exited without FrameCompleted")
  }
}

///|
fn main {
  run_palette_window()
}
