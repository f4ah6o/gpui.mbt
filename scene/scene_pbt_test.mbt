///|
fn scene_pbt_rect() -> @primitives.Rect {
  match @primitives.Rect::new(0.0, 0.0, 100.0, 100.0) {
    Ok(value) => value
    Err(_) => abort("valid scene property rectangle rejected")
  }
}

///|
// Stable suite ID: scene.clip-stack.invariants
test "property balanced clip stacks validate and unclosed stacks are rejected" {
  @quickcheck.check(
    (value : Int) => {
      let depth = (value % 4).abs()
      let ids : Array[UInt64] = [11, 22, 33, 44]
      let bounds = scene_pbt_rect()
      let balanced : Array[@scene.PaintCommand] = []
      let mut index = 0
      while index < depth {
        balanced.push(@scene.PaintCommand::clip_push(ids[index], bounds))
        index += 1
      }
      let mut pop_index = depth
      while pop_index > 0 {
        pop_index -= 1
        balanced.push(@scene.PaintCommand::clip_pop(ids[pop_index]))
      }
      let valid = @scene.Scene::new(balanced)
      let valid_ok = valid.validate() is Ok(_) &&
        valid.command_snapshot(bounds, 1.0) is Ok(_)
      if depth == 0 {
        valid_ok
      } else {
        let unclosed : Array[@scene.PaintCommand] = []
        index = 0
        while index < depth {
          unclosed.push(@scene.PaintCommand::clip_push(ids[index], bounds))
          index += 1
        }
        let invalid = @scene.Scene::new(unclosed)
        valid_ok &&
        invalid.validate() is Err(UnclosedClip) &&
        invalid.command_snapshot(bounds, 1.0) is Err(UnclosedClip)
      }
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=11936210308445291877,
  )
}
