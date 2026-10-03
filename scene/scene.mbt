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
fn copy_commands(commands : Array[PaintCommand]) -> Array[PaintCommand] {
  let owned : Array[PaintCommand] = []
  for command in commands {
    owned.push(command)
  }
  owned
}
