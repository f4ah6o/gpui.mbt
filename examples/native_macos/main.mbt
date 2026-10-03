///|
fn rect(x : Double, y : Double, w : Double, h : Double) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, w, h) {
    Ok(r) => r
    Err(_) => abort("invalid demo geometry")
  }
}

///|
fn scene(
  width : Double,
  height : Double,
  scale : Double,
  active : Bool,
) -> @scene.SceneSnapshot {
  let color = match
    @primitives.Color::rgba(if active { 230 } else { 50 }, 130, 210, 255) {
    Ok(c) => c
    Err(_) => abort("invalid demo color")
  }
  let commands = @scene.Scene::new([
    @scene.PaintCommand::clip_push(
      1,
      rect(24.0, 24.0, width - 48.0, height - 48.0),
    ),
    @scene.PaintCommand::quad(
      2,
      rect(64.0, 64.0, width - 128.0, height - 128.0),
      color,
    ),
    @scene.PaintCommand::clip_pop(1),
  ])
  match commands.snapshot_v1(rect(0.0, 0.0, width, height), scale) {
    Ok(s) => s
    Err(_) => abort("invalid scene")
  }
}

///|
fn run(
  host : &@platform.Backend,
  smoke : Bool,
) -> Result[Unit, @diagnostics.FrameworkError] {
  let window = match
    host.create_window(
      "gpui.mbt — Metal quads; click or press Space", 640.0, 360.0,
    ) {
    Ok(w) => w
    Err(e) => return Err(e)
  }
  let mut width = 640.0
  let mut height = 360.0
  let mut active = false
  let mut resized = false
  let mut requested = false
  let mut frames = 0
  let mut last_sequence : Int64 = 0
  let mut done = false
  let mut ticks = 0
  while !done && (!smoke || ticks < 1000) {
    ticks += 1
    let event = match host.next_event() {
      Ok(e) => e
      Err(e) => return Err(e)
    }
    match event {
      None => ()
      Some(e) => {
        if e.window == window {
          if e.sequence <= last_sequence {
            abort("event sequence regressed")
          }
          last_sequence = e.sequence
        }
        let mut repaint = false
        match e.kind {
          @platform.Created => repaint = true
          @platform.Resized(width=w, height=h) => {
            width = w
            height = h
            repaint = width >= 128.0 && height >= 128.0
            if smoke && width == 720.0 && height == 400.0 {
              resized = true
            }
          }
          @platform.ScaleChanged | @platform.FocusChanged(_) => repaint = true
          @platform.Input(@primitives.PointerButtonPressed(position~, ..)) =>
            if width >= 128.0 &&
              height >= 128.0 &&
              rect(64.0, 64.0, width - 128.0, height - 128.0).contains(position) {
              active = !active
              repaint = true
            }
          @platform.Input(@primitives.KeyPressed(key=@primitives.Space, ..)) => {
            active = !active
            repaint = true
          }
          @platform.Input(@primitives.KeyPressed(key=@primitives.Escape, ..)) =>
            match host.request_close(window) {
              Err(e) => return Err(e)
              Ok(_) => ()
            }
          @platform.CloseRequested => {
            requested = true
            match host.destroy_window(window) {
              Err(e) => return Err(e)
              Ok(_) => ()
            }
          }
          @platform.Destroyed => done = true
          @platform.ExitRequested =>
            match host.destroy_window(window) {
              Err(e) => return Err(e)
              Ok(_) => ()
            }
          _ => ()
        }
        if repaint && !done && !requested {
          let (current_width, current_height, current_scale) = match
            host.window_metrics(window) {
            Ok(metrics) => metrics
            Err(e) => return Err(e)
          }
          if current_width < 128.0 || current_height < 128.0 {
            continue
          }
          match
            host.present(
              window,
              scene(current_width, current_height, current_scale, active),
            ) {
            Err(e) => return Err(e)
            Ok(_) => frames += 1
          }
          if smoke && frames == 1 {
            match host.set_size(window, 720.0, 400.0) {
              Err(e) => return Err(e)
              Ok(_) => ()
            }
          } else if smoke && resized {
            match host.request_close(window) {
              Err(e) => return Err(e)
              Ok(_) => ()
            }
          }
        }
      }
    }
  }
  if smoke {
    if !done || !resized || !requested || frames < 2 {
      abort("native smoke incomplete")
    }
    println(
      "GPUI_MACOS_SMOKE {\"frames\":\{frames},\"resized\":true,\"close_requested\":true,\"destroyed\":true}",
    )
  }
  Ok(())
}

///|
fn main {
  let smoke = @env.args().contains("--smoke")
  match @macos.Host::start() {
    Err(e) => abort("macOS startup: " + e.code().label())
    Ok(host) => {
      let result = run(host, smoke)
      let stopped = host.stop()
      match result {
        Err(e) => abort(e.operation() + ": " + e.code().label())
        Ok(_) => ()
      }
      match stopped {
        Err(e) => abort(e.operation() + ": " + e.code().label())
        Ok(_) => ()
      }
    }
  }
}
