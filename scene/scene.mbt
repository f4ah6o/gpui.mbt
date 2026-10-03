///|
/// Platform-neutral paint command kinds used by headless scene tests and
/// renderer backends.
pub(all) enum PaintKind {
  Quad
  ClipPush
  ClipPop
} derive(Eq)

///|
pub extend PaintKind with Eq::{not_equal, equal}

///|
/// A bounded M3 scene foundation. Commands contain only framework values and
/// never native/GPU handles. Array order is the paint order.
pub(all) enum PaintCommand {
  QuadCommand(
    id~ : UInt64,
    bounds~ : @primitives.Rect,
    color~ : @primitives.Color
  )
  ClipPushCommand(id~ : UInt64, bounds~ : @primitives.Rect)
  ClipPopCommand(id~ : UInt64)
} derive(Eq)

///|
pub extend PaintCommand with Eq::{not_equal, equal}

///|
pub fn PaintCommand::quad(
  id : UInt64,
  bounds : @primitives.Rect,
  color : @primitives.Color,
) -> PaintCommand {
  QuadCommand(id~, bounds~, color~)
}

///|
pub fn PaintCommand::clip_push(
  id : UInt64,
  bounds : @primitives.Rect,
) -> PaintCommand {
  ClipPushCommand(id~, bounds~)
}

///|
pub fn PaintCommand::clip_pop(id : UInt64) -> PaintCommand {
  ClipPopCommand(id~)
}

///|
pub fn PaintCommand::kind(self : PaintCommand) -> PaintKind {
  match self {
    QuadCommand(..) => Quad
    ClipPushCommand(..) => ClipPush
    ClipPopCommand(..) => ClipPop
  }
}

///|
pub fn PaintCommand::id(self : PaintCommand) -> UInt64 {
  match self {
    QuadCommand(id~, ..) => id
    ClipPushCommand(id~, ..) => id
    ClipPopCommand(id~) => id
  }
}

///|
pub fn PaintCommand::bounds(self : PaintCommand) -> @primitives.Rect? {
  match self {
    QuadCommand(bounds~, ..) => Some(bounds)
    ClipPushCommand(bounds~, ..) => Some(bounds)
    ClipPopCommand(..) => None
  }
}

///|
pub fn PaintCommand::color(self : PaintCommand) -> @primitives.Color? {
  match self {
    QuadCommand(color~, ..) => Some(color)
    ClipPushCommand(..) | ClipPopCommand(..) => None
  }
}

///|
/// Snapshot construction errors.
pub enum SceneError {
  InvalidScale
  ClipUnderflow
  ClipMismatch
  UnclosedClip
} derive(Eq)

///|
pub extend SceneError with Eq::{not_equal, equal}

///|
/// Deterministic snapshot of the provisional command scene. This type is
/// deliberately distinct from the contracted versioned SceneSnapshot R0 shape.
pub struct CommandSnapshot {
  viewport : @primitives.Rect
  scale : Double
  commands : Array[PaintCommand]
}

///|
pub fn CommandSnapshot::viewport(self : CommandSnapshot) -> @primitives.Rect {
  self.viewport
}

///|
pub fn CommandSnapshot::scale(self : CommandSnapshot) -> Double {
  self.scale
}

///|
pub fn CommandSnapshot::commands(self : CommandSnapshot) -> Array[PaintCommand] {
  copy_commands(self.commands)
}

///|
/// Canonical field order and compact separators are stable for command
/// snapshots. Negative zero is normalized to zero.
pub fn CommandSnapshot::canonical_json(self : CommandSnapshot) -> String {
  let viewport = canonical_rect_json(self.viewport)
  let mut commands = ""
  let mut index = 0
  while index < self.commands.length() {
    if index > 0 {
      commands = commands + ","
    }
    commands = commands + canonical_command_json(self.commands[index])
    index += 1
  }
  "{\"viewport\":\{viewport},\"scale\":\{canonical_double(self.scale)},\"commands\":[\{commands}]}"
}

///|
/// Immutable-by-contract frame scene. Callers create a command array in stable
/// order and hand it to the scene as one frame-bounded value.
pub struct Scene {
  commands : Array[PaintCommand]
}

///|
pub fn Scene::empty() -> Scene {
  { commands: [], }
}

///|
pub fn Scene::new(commands : Array[PaintCommand]) -> Scene {
  { commands: copy_commands(commands), }
}

///|
pub fn Scene::commands(self : Scene) -> Array[PaintCommand] {
  copy_commands(self.commands)
}

///|
pub fn Scene::command_count(self : Scene) -> Int {
  self.commands.length()
}

///|
pub fn Scene::command_at(self : Scene, index : Int) -> PaintCommand? {
  if index < 0 || index >= self.commands.length() {
    None
  } else {
    Some(self.commands[index])
  }
}

///|
/// Validate clip-stack structure without consulting a renderer. Clip IDs are
/// nested strictly: each pop must match the most recent unmatched push, and a
/// frame cannot finish with an open clip.
pub fn Scene::validate(self : Scene) -> Result[Unit, SceneError] {
  let stack : Array[UInt64] = []
  let mut depth = 0
  let mut failure : SceneError? = None
  let mut index = 0
  while index < self.commands.length() && failure is None {
    match self.commands[index] {
      ClipPushCommand(id~, ..) => {
        if depth == stack.length() {
          stack.push(id)
        } else {
          stack[depth] = id
        }
        depth += 1
      }
      ClipPopCommand(id~) =>
        if depth == 0 {
          failure = Some(ClipUnderflow)
        } else if stack[depth - 1] != id {
          failure = Some(ClipMismatch)
        } else {
          depth -= 1
        }
      QuadCommand(..) => ()
    }
    index += 1
  }
  match failure {
    Some(error) => Err(error)
    None => if depth == 0 { Ok(()) } else { Err(UnclosedClip) }
  }
}

///|
/// Freeze this provisional command scene for deterministic headless tests.
/// Scale must be finite and positive, and clip-stack structure must be valid.
/// This does not construct the contracted versioned SceneSnapshot R0 envelope.
pub fn Scene::command_snapshot(
  self : Scene,
  viewport : @primitives.Rect,
  scale : Double,
) -> Result[CommandSnapshot, SceneError] {
  if scale.is_nan() || scale.is_inf() || scale <= 0.0 {
    Err(InvalidScale)
  } else {
    match self.validate() {
      Err(error) => Err(error)
      Ok(_) => Ok({ viewport, scale, commands: copy_commands(self.commands), })
    }
  }
}

///|
fn canonical_double(value : Double) -> String {
  let normalized = if value == 0.0 { 0.0 } else { value }
  "\{normalized}"
}

///|
fn canonical_rect_json(rect : @primitives.Rect) -> String {
  let size = rect.size()
  "{\"x\":\{canonical_double(rect.left())},\"y\":\{canonical_double(rect.top())},\"width\":\{canonical_double(size.width())},\"height\":\{canonical_double(size.height())}}"
}

///|
fn canonical_color_json(color : @primitives.Color) -> String {
  "{\"red\":\{color.red()},\"green\":\{color.green()},\"blue\":\{color.blue()},\"alpha\":\{color.alpha()}}"
}

///|
fn canonical_command_json(command : PaintCommand) -> String {
  match command {
    QuadCommand(id~, bounds~, color~) =>
      "{\"kind\":\"quad\",\"id\":\{id},\"bounds\":\{canonical_rect_json(bounds)},\"color\":\{canonical_color_json(color)}}"
    ClipPushCommand(id~, bounds~) =>
      "{\"kind\":\"clip_push\",\"id\":\{id},\"bounds\":\{canonical_rect_json(bounds)}}"
    ClipPopCommand(id~) => "{\"kind\":\"clip_pop\",\"id\":\{id}}"
  }
}

///|
fn copy_commands(commands : Array[PaintCommand]) -> Array[PaintCommand] {
  let owned : Array[PaintCommand] = []
  for command in commands {
    owned.push(command)
  }
  owned
}
