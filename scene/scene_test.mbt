///|
fn scene_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("valid rectangle rejected")
  }
}

///|
fn scene_color(red : Int, green : Int, blue : Int) -> @primitives.Color {
  match @primitives.Color::rgba(red, green, blue, 255) {
    Ok(value) => value
    Err(_) => abort("valid color rejected")
  }
}

///|
test "scene preserves deterministic paint order and command data" {
  let first_bounds = scene_rect(0.0, 0.0, 10.0, 10.0)
  let second_bounds = scene_rect(2.0, 3.0, 4.0, 5.0)
  let first_color = scene_color(10, 20, 30)
  let second_color = scene_color(40, 50, 60)
  let scene = @scene.Scene::new([
    @scene.PaintCommand::quad(10, first_bounds, first_color),
    @scene.PaintCommand::clip_push(20, second_bounds),
    @scene.PaintCommand::quad(30, second_bounds, second_color),
    @scene.PaintCommand::clip_pop(20),
  ])
  assert_eq(scene.command_count(), 4)
  match scene.command_at(0) {
    None => fail("missing first command")
    Some(command) => {
      assert_true(command.kind() == @scene.PaintKind::Quad)
      assert_true(command.id() == 10)
      assert_true(command.bounds() == Some(first_bounds))
      assert_true(command.color() == Some(first_color))
    }
  }
  match scene.command_at(3) {
    None => fail("missing final command")
    Some(command) => {
      assert_true(command.kind() == @scene.PaintKind::ClipPop)
      assert_true(command.id() == 20)
      assert_true(command.bounds() is None)
      assert_true(command.color() is None)
    }
  }
  assert_true(scene.command_at(-1) is None)
  assert_true(scene.command_at(4) is None)
}

///|
test "scene owns its command storage" {
  let bounds = scene_rect(0.0, 0.0, 10.0, 10.0)
  let color = scene_color(1, 2, 3)
  let commands : Array[@scene.PaintCommand] = [
    @scene.PaintCommand::quad(1, bounds, color),
  ]
  let scene = @scene.Scene::new(commands)
  commands.push(@scene.PaintCommand::clip_pop(99))
  assert_eq(scene.command_count(), 1)
  let exposed = scene.commands()
  exposed.push(@scene.PaintCommand::clip_pop(100))
  assert_eq(scene.command_count(), 1)
}
