///|
fn[T] required(result : Result[T, @diagnostics.FrameworkError]) -> T {
  match result {
    Ok(value) => value
    Err(error) => abort("\{error.operation()}: \{error.code().label()}")
  }
}

///|
fn quad_scene(
  width : Int,
  height : Int,
  scale : Double,
) -> @scene.SceneSnapshot {
  let viewport = match
    @primitives.Rect::new(0.0, 0.0, width.to_double(), height.to_double()) {
    Ok(r) => r
    Err(_) => abort("viewport")
  }
  let bounds = match @primitives.Rect::new(24.0, 24.0, 160.0, 100.0) {
    Ok(r) => r
    Err(_) => abort("bounds")
  }
  let background = match @primitives.Color::rgba(24, 28, 36, 255) {
    Ok(c) => c
    Err(_) => abort("color")
  }
  let accent = match @primitives.Color::rgba(64, 160, 240, 255) {
    Ok(c) => c
    Err(_) => abort("color")
  }
  let scene = @scene.Scene::new([
    @scene.PaintCommand::quad(1, viewport, background),
    @scene.PaintCommand::quad(2, bounds, accent),
  ])
  match scene.snapshot_v1(viewport, scale) {
    Ok(s) => s
    Err(_) => abort("scene")
  }
}

///|
fn main {
  let host = required(@native.Host::start())
  let window = required(
    host.create_window(640, 400, "gpui.mbt — Ubuntu Wayland"),
  )
  let mut width = 640
  let mut height = 400
  let mut scale = 1.0
  let mut dirty = true
  let mut frames = 0
  let smoke = @env.get_env_var("GPUI_UBUNTU_SMOKE") == Some("1")
  while host.state() == @native.Running {
    match host.dispatch(100) {
      Err(error) => {
        println("\{error.operation()}: \{error.code().label()}")
        ignore(host.request_exit())
      }
      Ok(events) =>
        for event in events {
          scale = event.scale()
          match event.kind() {
            @platform.Resized(width=w, height=h) => {
              width = w.to_int()
              height = h.to_int()
              dirty = true
            }
            @platform.ScaleChanged => dirty = true
            @platform.FrameCompleted => {
              frames += 1
              if smoke {
                ignore(host.request_exit())
              }
            }
            @platform.CloseRequested => ignore(host.request_exit())
            @platform.Input(@primitives.KeyPressed(key=@primitives.Escape, ..)) =>
              ignore(host.request_exit())
            _ => ()
          }
        }
    }
    if dirty && host.state() == @native.Running {
      match host.present(window, quad_scene(width, height, scale)) {
        Ok(_) => dirty = false
        Err(error) =>
          if error.code() is @diagnostics.Busy {
            ()
          } else {
            println("\{error.operation()}: \{error.code().label()}")
            ignore(host.request_exit())
          }
      }
    }
  }
  ignore(host.destroy_window(window))
  required(host.stop())
  if smoke && frames == 0 {
    abort("no frame completed")
  }
}
