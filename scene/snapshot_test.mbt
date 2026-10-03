///|
fn snapshot_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("valid snapshot rectangle rejected")
  }
}

///|
fn snapshot_color(red : Int, green : Int, blue : Int) -> @primitives.Color {
  match @primitives.Color::rgba(red, green, blue, 255) {
    Ok(value) => value
    Err(_) => abort("valid snapshot color rejected")
  }
}

///|
test "scene snapshot v1 freezes quad and active clip chain deterministically" {
  let viewport = snapshot_rect(-0.0, 0.0, 100.0, 50.0)
  let clip = snapshot_rect(0.0, 0.0, 80.0, 40.0)
  let bounds = snapshot_rect(1.0, 2.0, 3.0, 4.0)
  let color = snapshot_color(10, 20, 30)
  let scene = @scene.Scene::new([
    @scene.PaintCommand::clip_push(9, clip),
    @scene.PaintCommand::quad(7, bounds, color),
    @scene.PaintCommand::clip_pop(9),
  ])
  match scene.snapshot_v1(viewport, 2.0) {
    Err(_) => fail("valid v1 scene snapshot rejected")
    Ok(snapshot) => {
      assert_eq(snapshot.schema_version(), 1)
      assert_true(snapshot.viewport() == viewport)
      assert_true(snapshot.scale() == 2.0)
      assert_eq(snapshot.resources().length(), 0)
      let chains = snapshot.clip_chains()
      assert_eq(chains.length(), 1)
      assert_eq(chains[0].id(), 0)
      assert_eq(chains[0].rects().length(), 1)
      assert_true(chains[0].rects()[0] == clip)
      let items = snapshot.items()
      assert_eq(items.length(), 1)
      assert_true(items[0].id() == 7)
      assert_true(items[0].clip_chain_id() == Some(0))
      assert_eq(
        snapshot.canonical_json(),
        "{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":100,\"height\":50},\"scale\":2,\"resources\":[],\"clip_chains\":[{\"id\":0,\"rects\":[{\"x\":0,\"y\":0,\"width\":80,\"height\":40}]}],\"items\":[{\"kind\":\"quad\",\"id\":7,\"bounds\":{\"x\":1,\"y\":2,\"width\":3,\"height\":4},\"color\":{\"red\":10,\"green\":20,\"blue\":30,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":0}]}",
      )
    }
  }
}

///|
test "scene snapshot v1 validates envelope references and ownership" {
  let viewport = snapshot_rect(0.0, 0.0, 20.0, 20.0)
  let bounds = snapshot_rect(1.0, 1.0, 5.0, 5.0)
  let color = snapshot_color(1, 2, 3)
  let item = match
    @scene.SceneItem::quad(
      1,
      bounds,
      color,
      @scene.AffineTransform::identity(),
      1.0,
      Some(99),
    ) {
    Ok(value) => value
    Err(_) => abort("valid item rejected")
  }
  assert_true(
    @scene.SceneSnapshot::new(viewport, 1.0, [], [], [item])
    is Err(UnknownClipChain),
  )
  assert_true(
    @scene.SceneSnapshot::new(
      viewport,
      1.0,
      [],
      [@scene.ClipChain::new(1, [bounds]), @scene.ClipChain::new(1, [bounds])],
      [],
    )
    is Err(DuplicateClipChain),
  )
  assert_true(
    @scene.SceneItem::quad(
      2,
      bounds,
      color,
      @scene.AffineTransform::identity(),
      1.5,
      None,
    )
    is Err(InvalidOpacity),
  )
}

///|
test "scene snapshot v1 rejects invalid command scale and clip structure" {
  let viewport = snapshot_rect(0.0, 0.0, 20.0, 20.0)
  let bounds = snapshot_rect(0.0, 0.0, 10.0, 10.0)
  let invalid = @scene.Scene::new([@scene.PaintCommand::clip_push(1, bounds)])
  assert_true(invalid.snapshot_v1(viewport, 1.0) is Err(UnclosedClip))
  let empty = @scene.Scene::empty()
  assert_true(empty.snapshot_v1(viewport, 0.0) is Err(InvalidScale))
}


///|
test "scene snapshot v1 reuses identical active clip chains" {
  let viewport = snapshot_rect(0.0, 0.0, 100.0, 50.0)
  let clip = snapshot_rect(0.0, 0.0, 80.0, 40.0)
  let first = snapshot_rect(1.0, 2.0, 3.0, 4.0)
  let second = snapshot_rect(5.0, 6.0, 7.0, 8.0)
  let color = snapshot_color(10, 20, 30)
  let scene = @scene.Scene::new([
    @scene.PaintCommand::clip_push(9, clip),
    @scene.PaintCommand::quad(7, first, color),
    @scene.PaintCommand::quad(8, second, color),
    @scene.PaintCommand::clip_pop(9),
  ])
  match scene.snapshot_v1(viewport, 1.0) {
    Err(_) => fail("valid v1 scene snapshot rejected")
    Ok(snapshot) => {
      let chains = snapshot.clip_chains()
      let items = snapshot.items()
      assert_eq(chains.length(), 1)
      assert_eq(items.length(), 2)
      assert_true(items[0].clip_chain_id() == Some(0))
      assert_true(items[1].clip_chain_id() == Some(0))
    }
  }
}
