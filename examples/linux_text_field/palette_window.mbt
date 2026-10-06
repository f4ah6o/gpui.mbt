///|
struct PaletteFixture {
  palette : @palette.CommandPalette
  tree : Ref[@element.ElementTree]
  actions : Ref[Int]
  last_action : Ref[String]
  background_actions : Ref[Int]
  background_releases : Ref[Int]
  direct_ready : Ref[Bool]
}

///|
fn palette_fixture() -> PaletteFixture {
  let bounds = native_field_bounds(640.0, 480.0).unwrap()
  let field = make_field("", bounds).unwrap()
  let viewport = @primitives.Rect::new(0.0, 0.0, 640.0, 480.0).unwrap()
  let tree = Ref(
    @element.ElementTree::new([
      @element.ElementNode::new(1, None, viewport),
      @element.ElementNode::new(9, Some(1), bounds).with_focusable(true),
      field.element_node(Some(1)),
    ])
    .unwrap()
    .with_focus(9)
    .unwrap(),
  )
  let actions = Ref(0)
  let last_action = Ref("")
  let commands = []
  for index = 0; index < 13; index = index + 1 {
    let id = "palette.command.\{index}"
    let label = if index == 0 {
      "Open settings"
    } else {
      "日本: コマンド \{index}"
    }
    let metadata = @palette.CommandMetadata::new(id, label, index != 2).unwrap()
    let descriptor = @capability.Descriptor::new(
      id,
      label,
      "Standalone palette command",
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
    background_actions: Ref(0),
    background_releases: Ref(0),
    direct_ready: Ref(false),
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
) -> @scene.SceneItem {
  let document = @text.TextDocument::new(label).unwrap()
  let measurement = measure(document).unwrap()
  admit(document, measurement).unwrap()
  let (origin, bounds) = @text_field.scene_text_run_geometry(measurement).unwrap()
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
  ).unwrap()
}

///|
fn palette_scene(
  fixture : PaletteFixture,
  width : Double,
  height : Double,
  scale : Double,
) -> @scene.SceneSnapshot {
  let viewport = @primitives.Rect::new(0.0, 0.0, width, height).unwrap()
  let palette = fixture.palette
  let white = @primitives.Color::rgba(238, 242, 248, 255).unwrap()
  let items : Array[@scene.SceneItem] = []
  let clips : Array[@scene.ClipChain] = []
  if palette.is_open() {
    let field = field_scene(palette.field(), width, height, scale).unwrap()
    for item in field.items() {
      items.push(item)
    }
    for clip in field.clip_chains() {
      clips.push(clip)
    }
    let picker = palette.picker()
    let (list_clip, rows) = picker
      .paint_items(
        200,
        8,
        @primitives.Rect::new(24.0, 84.0, 512.0, 288.0).unwrap(),
        36.0,
        (id, command, position, clip) => {
          let color = if command.is_enabled() {
            white
          } else {
            @primitives.Color::rgba(128, 132, 140, 255).unwrap()
          }
          Ok(
            palette_label(
              id,
              command.label(),
              position.x(),
              position.y(),
              color,
              Some(clip),
            ),
          )
        },
      )
      .unwrap()
    clips.push(list_clip)
    for item in rows {
      items.push(item)
    }
    if picker.match_count() == 0 {
      items.push(
        palette_label(220, "No matching commands", 32.0, 92.0, white, Some(8)),
      )
    }
  } else {
    items.push(
      @scene.SceneItem::quad(
        1,
        viewport,
        @primitives.Color::rgba(24, 28, 36, 255).unwrap(),
        @scene.AffineTransform::identity(),
        1.0,
        None,
      ).unwrap(),
    )
    items.push(
      @scene.SceneItem::quad(
        3,
        palette.field().bounds(),
        @primitives.Color::rgba(48, 74, 114, 255).unwrap(),
        @scene.AffineTransform::identity(),
        1.0,
        None,
      ).unwrap(),
    )
    items.push(
      palette_label(
        4,
        "Open command palette (click or Ctrl+K)",
        32.0,
        37.0,
        white,
        None,
      ),
    )
  }
  items.push(
    palette_label(
      230,
      "Actions: \{fixture.actions.val}  Background: \{fixture.background_actions.val}",
      24.0,
      404.0,
      white,
      None,
    ),
  )
  @scene.SceneSnapshot::new(viewport, scale, [], clips, items).unwrap()
}

///|
fn palette_state_line(
  fixture : PaletteFixture,
  presentation : Int,
  owner : ImeOwner?,
  commits : Int,
) -> String {
  let palette = fixture.palette
  let semantics = palette.semantics()
  let options = semantics.options.map(option => {
    "id": option.id.to_json(),
    "name": option.name.to_json(),
    "role": option.role.to_json(),
    "selected": option.selected.to_json(),
    "disabled": option.disabled.to_json(),
    "index": option.index.to_json(),
  })
  let active_id : Json = match semantics.active_id {
    Some(value) => value.to_json()
    None => Json::null()
  }
  let active_index : Json = match palette.picker().active_index() {
    Some(value) => value.to_json()
    None => Json::null()
  }
  let focus_owner : Json = match fixture.tree.val.focused() {
    Some(value) => value.to_int().to_json()
    None => Json::null()
  }
  let value : Json = {
    "version": 1,
    "presentation": presentation.to_json(),
    "open": palette.is_open().to_json(),
    "open_epoch": palette.open_epoch().to_json(),
    "query": palette.picker().query().to_json(),
    "matches": palette.picker().match_count().to_json(),
    "active_id": active_id,
    "active_index": active_index,
    "visible_start": palette.picker().visible_start().to_json(),
    "visible_count": semantics.options.length().to_json(),
    "actions": fixture.actions.val.to_json(),
    "last_action": fixture.last_action.val.to_json(),
    "background_actions": fixture.background_actions.val.to_json(),
    "background_releases": fixture.background_releases.val.to_json(),
    "focus_owner": focus_owner,
    "direct_ready": fixture.direct_ready.val.to_json(),
    "semantic": {
      "role": semantics.role.to_json(),
      "name": semantics.name.to_json(),
      "search_role": semantics.search_role.to_json(),
      "search_name": semantics.search_name.to_json(),
      "search_value": semantics.search_value.to_json(),
      "search_focused": semantics.search_focused.to_json(),
      "collection_role": semantics.collection_role.to_json(),
      "options": options.to_json(),
    },
  }
  // Keep the existing strict accepted field/frame stream unchanged. Palette
  // semantics/actions are a separate acceptance record at the same frame ID.
  "\{ime_observer_line(presentation, palette.field(), owner, commits)}\nGPUI_PALETTE_STATE \{value.stringify()}"
}

///|
fn end_palette_owner(
  host : @native.Host,
  window : @platform.WindowId,
  owner : ImeOwner?,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if owner is Some(active) {
    ignore(host.set_text_session_panel(window, active.epoch, false))
    match host.end_text_session(window, active.epoch) {
      Ok(_) => ()
      Err(error) =>
        if !(error.code() is @diagnostics.StaleHandle) {
          return Err(error)
        }
    }
  }
  // A stale old epoch after native Left is already fenced. Direct rearming
  // waits for actual native leave; teardown never enables a new owner.
  host.set_direct_keyboard_text(window, false)
}

///|
fn run_palette_window() -> Unit {
  let host = required(@native.Host::start())
  let window = required(
    host.create_window(
      640, 480, "gpui.mbt reusable command palette: Japanese IME",
    ),
  )
  required(host.require_capability(@platform.GrayscaleTextFrames))
  let fixture = palette_fixture()
  let palette = fixture.palette
  let mut width = 640.0
  let mut height = 480.0
  let mut scale = 1.0
  let mut owner : ImeOwner? = None
  let mut native_focused = false
  let mut owner_open_epoch = 0
  let mut dirty = true
  let mut external_edit = false
  let mut commits = 0
  let mut presentation = 0
  while host.state() == @native.Running {
    let mut input : @primitives.InputEvent? = None
    let mut effect : @palette.PaletteEffect = @palette.None
    match host.next_editor_event(timeout_ms=16) {
      Err(error) => {
        report(error)
        ignore(host.request_exit())
      }
      Ok(None) => ()
      Ok(Some(@native.Platform(event))) =>
        if event.window() == window {
          scale = event.scale()
          match event.kind() {
            @platform.Resized(width=w, height=h) => {
              width = w
              height = h
              dirty = true
            }
            @platform.ScaleChanged => dirty = true
            @platform.FocusChanged(focused) => {
              native_focused = focused
              if !focused {
                fixture.direct_ready.val = false
              }
              if !focused && palette.is_open() {
                effect = palette.blur().unwrap()
                dirty = true
              }
            }
            @platform.CloseRequested | @platform.Destroyed =>
              ignore(host.request_exit())
            @platform.Input(event) => input = Some(event)
            _ => ()
          }
        }
      Ok(Some(@native.TextSession(target, event))) =>
        if owner is Some(active) {
          let lifecycle = event is @native.Entered || event is @native.Left
          if palette.is_open() &&
            owner_open_epoch == palette.open_epoch() &&
            ime_target_current(active, window, target, lifecycle~) {
            owner = Some({ ..active, sequence: target.sequence, })
            match event {
              @native.Entered => {
                owner = Some({
                  ..active,
                  entered: true,
                  seat: target.seat,
                  proxy_generation: target.proxy_generation,
                  sequence: target.sequence,
                })
                required(
                  host.set_text_session_panel(window, active.epoch, true),
                )
                dirty = true
              }
              @native.Left => {
                effect = palette.blur().unwrap()
                native_focused = false
                dirty = true
              }
              @native.Preedit(text~, cursor_utf16~, styles~, ..) => {
                match ime_preedit(palette.field(), text, cursor_utf16, styles) {
                  Ok(candidate) =>
                    match
                      palette.install_field_at(owner_open_epoch, candidate) {
                      Ok(_) =>
                        required(
                          host.set_text_session_panel(
                            window,
                            active.epoch,
                            text.length() != 0,
                          ),
                        )
                      Err(_) => {
                        println("GPUI_PALETTE_REJECT preedit bound")
                        external_edit = true
                      }
                    }
                  Err(_) => {
                    println("GPUI_PALETTE_REJECT preedit admission")
                    external_edit = true
                  }
                }
                dirty = true
              }
              @native.Commit(text~, deletion~, position~) => {
                match ime_commit(palette.field(), text, deletion, position) {
                  Ok(candidate) =>
                    match
                      palette.install_field_at(owner_open_epoch, candidate) {
                      Ok(_) => {
                        commits += 1
                        required(
                          host.set_text_session_panel(
                            window,
                            active.epoch,
                            false,
                          ),
                        )
                      }
                      Err(_) => {
                        println("GPUI_PALETTE_REJECT commit bound")
                        external_edit = true
                      }
                    }
                  Err(_) => {
                    println("GPUI_PALETTE_REJECT commit admission")
                    external_edit = true
                  }
                }
                dirty = true
              }
              @native.ForwardedPressed(keysym~, key~, modifiers~) =>
                if ime_command_key(keysym, key, modifiers) is Some(key) {
                  input = Some(
                    @primitives.KeyPressed(key~, modifiers~, repeat=false),
                  )
                }
              @native.ForwardedReleased(keysym~, key~, modifiers~) =>
                if ime_command_key(keysym, key, modifiers) is Some(key) {
                  input = Some(@primitives.KeyReleased(key~, modifiers~))
                }
            }
          }
        }
    }
    if input is Some(event) {
      let was_open = palette.is_open()
      let before_input = palette.field().committed_document()
      let mut opened = false
      if !was_open {
        let opener = (
            event
            is @primitives.PointerButtonPressed(
              position~,
              button=@primitives.Primary,
              ..
            ) &&
            palette.field().bounds().contains(position)
          ) ||
          (
            event
            is @primitives.KeyPressed(
              key=@primitives.Character("k"),
              modifiers~,
              repeat=false
            ) &&
            modifiers.control()
          )
        if opener {
          palette.open(fixture.tree).unwrap()
          opened = true
          dirty = true
        }
      }
      if !opened {
        if was_open &&
          event
          is @primitives.PointerButtonPressed(
            position~,
            button=@primitives.Primary,
            ..
          ) &&
          !palette.field().bounds().contains(position) {
          effect = palette.blur().unwrap()
        } else {
          match palette.handle_input(event, measure, admit, hit) {
            Ok(outcome) => {
              effect = outcome.effect
              if !outcome.consumed &&
                event
                is @primitives.KeyPressed(
                  key=@primitives.Enter
                  | @primitives.Escape,
                  ..
                ) &&
                fixture.tree.val.focused() == Some(9) {
                fixture.background_actions.val += 1
              }
              if !outcome.consumed &&
                event
                is @primitives.KeyReleased(
                  key=@primitives.Enter
                  | @primitives.Escape,
                  ..
                ) &&
                fixture.tree.val.focused() == Some(9) {
                fixture.background_releases.val += 1
              }
            }
            Err(_) => println("GPUI_PALETTE_REJECT input")
          }
        }
        dirty = true
      }
      if palette.is_open() &&
        palette.field().committed_document() != before_input {
        external_edit = true
      }
    }
    match effect {
      @palette.Closed(epoch~, ..) => {
        let fenced = end_palette_owner(host, window, owner)
        fixture.direct_ready.val = false
        owner = None
        external_edit = false
        match fenced {
          Ok(_) =>
            if palette.finish_close(epoch, fixture.tree) is Err(_) {
              println("GPUI_PALETTE_REJECT command")
            }
          Err(error) => {
            report(error)
            ignore(host.request_exit())
          }
        }
        dirty = true
      }
      @palette.CompositionCancelled => {
        external_edit = true
        dirty = true
      }
      @palette.FieldAction(action) =>
        match action {
          @text_field.Copy(text) => ignore(host.write_clipboard(text))
          // Keep the fixture bounded/read-only regarding clipboard writes except
          // explicit copy. Paste/cut are outside this palette acceptance profile.
          _ => ()
        }
      @palette.None => ()
    }
    if external_edit && palette.is_open() && palette.field().is_composing() {
      palette
      .install_field_at(
        palette.open_epoch(),
        palette.field().cancel_composition(measure, admit).unwrap(),
      )
      .unwrap()
      if owner is Some(active) {
        required(host.set_text_session_panel(window, active.epoch, false))
      }
    }
    if external_edit && palette.is_open() && native_focused {
      if owner is Some(active) {
        owner = Some(
          required(ime_sync(host, window, palette.field(), Some(active), true)),
        )
      }
      external_edit = false
    }
    if !palette.is_open() &&
      native_focused &&
      !fixture.direct_ready.val &&
      host.state() == @native.Running {
      match host.set_direct_keyboard_text(window, true) {
        Ok(_) => {
          fixture.direct_ready.val = true
          palette.retire_key_guard(palette.open_epoch())
          dirty = true
        }
        Err(error) =>
          match error.code() {
            @diagnostics.Busy | @diagnostics.UnsupportedCapability => ()
            _ => {
              report(error)
              ignore(host.request_exit())
            }
          }
      }
    }
    if dirty && host.state() == @native.Running {
      let presented = host.present(
        window,
        palette_scene(fixture, width, height, scale),
      )
      match classify_field_frame(presented) {
        Accepted => {
          if palette.is_open() && native_focused {
            owner = Some(
              required(
                ime_sync(host, window, palette.field(), owner, external_edit),
              ),
            )
            owner_open_epoch = palette.open_epoch()
            fixture.direct_ready.val = false
          }
          external_edit = false
          presentation += 1
          println(palette_state_line(fixture, presentation, owner, commits))
          field_state_flush_stdout()
          dirty = false
        }
        BusyPending => ()
        RecoverPending =>
          if host.recover_renderer(window) is Err(error) {
            report(error)
            ignore(host.request_exit())
          }
        RejectPending => {
          // Fail closed instead of replaying any input against a shown/stale
          // picker value. Busy retains the entire prepared palette value.
          println("GPUI_PALETTE_REJECT presentation")
          if palette.is_open() {
            ignore(palette.blur())
          }
          ignore(end_palette_owner(host, window, owner))
          owner = None
          ignore(host.request_exit())
        }
      }
    }
  }
  ignore(end_palette_owner(host, window, owner))
  ignore(host.destroy_window(window))
  required(host.stop())
}
