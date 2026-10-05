///|
fn origin_test_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(value) => value
    Err(_) => abort("valid origin-test rectangle rejected")
  }
}

///|
fn origin_test_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid origin-test point rejected")
  }
}

///|
fn origin_test_color() -> @primitives.Color {
  match @primitives.Color::rgba(40, 50, 60, 200) {
    Ok(value) => value
    Err(_) => abort("valid origin-test color rejected")
  }
}

///|
test "text run canonical schema keeps origin after bounds and old kinds stable" {
  let viewport = origin_test_rect(0.0, 0.0, 100.0, 60.0)
  let bounds = origin_test_rect(11.0, 12.0, 40.0, 22.0)
  let clip = origin_test_rect(5.0, 6.0, 70.0, 45.0)
  let text_origin = origin_test_point(14.5, 15.25)
  let color = origin_test_color()
  let transform = match
    @scene.AffineTransform::new(0.0, 1.0, -1.0, 0.0, 80.0, 4.0) {
    Ok(value) => value
    Err(_) => abort("valid origin-test transform rejected")
  }
  let run = match
    @scene.SceneItem::text_run(
      42,
      bounds,
      text_origin,
      "Origin 日本語",
      17.5,
      color,
      transform,
      0.75,
      Some(7),
    ) {
    Ok(value) => value
    Err(_) => abort("valid text run rejected")
  }
  assert_eq(run.id(), 42)
  assert_eq(run.clip_chain_id(), Some(7))
  match run {
    @scene.TextRunItem(text_origin~, text~, ..) => {
      assert_true(text_origin == origin_test_point(14.5, 15.25))
      assert_eq(text, "Origin 日本語")
    }
    _ => fail("text_run constructor returned a different variant")
  }

  let source_items = [run]
  let source_chains = [@scene.ClipChain::new(7, [clip])]
  let snapshot = match
    @scene.SceneSnapshot::new(viewport, 1.0, [], source_chains, source_items) {
    Ok(value) => value
    Err(_) => abort("valid origin-aware snapshot rejected")
  }
  assert_eq(snapshot.schema_version(), 1)
  assert_eq(
    snapshot.canonical_json(),
    "{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":100,\"height\":60},\"scale\":1,\"resources\":[],\"clip_chains\":[{\"id\":7,\"rects\":[{\"x\":5,\"y\":6,\"width\":70,\"height\":45}]}],\"items\":[{\"kind\":\"text_run\",\"id\":42,\"bounds\":{\"x\":11,\"y\":12,\"width\":40,\"height\":22},\"text_origin\":{\"x\":14.5,\"y\":15.25},\"text\":\"Origin \\u65e5\\u672c\\u8a9e\",\"font_size\":17.5,\"color\":{\"red\":40,\"green\":50,\"blue\":60,\"alpha\":200},\"transform\":{\"a\":0,\"b\":1,\"c\":-1,\"d\":0,\"tx\":80,\"ty\":4},\"opacity\":0.75,\"clip_chain_id\":7}]}",
  )

  // Snapshot ingress and egress both detach their arrays; the copied run keeps
  // its validated origin and clipping reference.
  source_chains.clear()
  source_items.clear()
  let copied_items = snapshot.items()
  assert_eq(copied_items.length(), 1)
  assert_true(copied_items[0].id() == 42)
  assert_true(copied_items[0].clip_chain_id() == Some(7))
  copied_items.clear()
  assert_eq(snapshot.items().length(), 1)
  let copied_chains = snapshot.clip_chains()
  copied_chains.clear()
  assert_eq(snapshot.clip_chains().length(), 1)
  assert_eq(snapshot.clip_chains()[0].rects().length(), 1)
}

///|
test "text run constructor and snapshot revalidate text paint fields" {
  let viewport = origin_test_rect(0.0, 0.0, 100.0, 60.0)
  let text_origin = origin_test_point(0.0, 0.0)
  let color = origin_test_color()
  let transform = @scene.AffineTransform::identity()
  for font_size in [0.0, -1.0, 1024.1, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0] {
    assert_true(
      @scene.SceneItem::text_run(
        1,
        viewport,
        text_origin,
        "Label",
        font_size,
        color,
        transform,
        1.0,
        None,
      )
      is Err(InvalidFontSize),
    )
    let raw = @scene.TextRunItem(
      id=1,
      bounds=viewport,
      text_origin~,
      text="Label",
      font_size~,
      color~,
      transform~,
      opacity=1.0,
      clip_chain_id=None,
    )
    assert_true(
      @scene.SceneSnapshot::new(viewport, 1.0, [], [], [raw])
      is Err(InvalidFontSize),
    )
  }

  for opacity in [-0.1, 1.1, 0.0 / 0.0, 1.0 / 0.0] {
    assert_true(
      @scene.SceneItem::text_run(
        1,
        viewport,
        text_origin,
        "Label",
        16.0,
        color,
        transform,
        opacity,
        None,
      )
      is Err(InvalidOpacity),
    )
    let raw = @scene.TextRunItem(
      id=1,
      bounds=viewport,
      text_origin~,
      text="Label",
      font_size=16.0,
      color~,
      transform~,
      opacity~,
      clip_chain_id=None,
    )
    assert_true(
      @scene.SceneSnapshot::new(viewport, 1.0, [], [], [raw])
      is Err(InvalidOpacity),
    )
  }

  let invalid_transform = @scene.AffineTransform::new(
    1.0,
    0.0,
    0.0,
    1.0,
    0.0 / 0.0,
    0.0,
  )
  assert_true(invalid_transform is Err(NonFiniteTransform))
  let unknown_clip = @scene.TextRunItem(
    id=1,
    bounds=viewport,
    text_origin~,
    text="Label",
    font_size=16.0,
    color~,
    transform~,
    opacity=1.0,
    clip_chain_id=Some(7),
  )
  assert_true(
    @scene.SceneSnapshot::new(viewport, 1.0, [], [], [unknown_clip])
    is Err(UnknownClipChain),
  )
}

///|
test "text run keeps lone UTF-16 surrogate and finite typed geometry" {
  let viewport = origin_test_rect(-0.0, 0.0, 100.0, 60.0)
  let color = origin_test_color()
  let text_origin = origin_test_point(-0.0, 4.0)
  let high = "😀".unsafe_substring(start=0, end=1)
  let run = match
    @scene.SceneItem::text_run(
      5,
      viewport,
      text_origin,
      high,
      16.0,
      color,
      @scene.AffineTransform::identity(),
      1.0,
      None,
    ) {
    Ok(value) => value
    Err(_) => abort("valid lone-surrogate text run rejected")
  }
  let snapshot = match @scene.SceneSnapshot::new(viewport, 1.0, [], [], [run]) {
    Ok(value) => value
    Err(_) => abort("valid lone-surrogate snapshot rejected")
  }
  assert_true(
    snapshot.canonical_json().contains("\"text_origin\":{\"x\":0,\"y\":4}"),
  )
  assert_true(snapshot.canonical_json().contains("\"text\":\"\\ud83d\""))
  assert_true(
    @primitives.Point::new(0.0 / 0.0, 0.0) is Err(@primitives.NonFiniteValue),
  )
  assert_true(
    @primitives.Point::new(0.0, 1.0 / 0.0) is Err(@primitives.NonFiniteValue),
  )
  assert_true(
    @primitives.Rect::new(0.0, 0.0, 1.0 / 0.0, 1.0)
    is Err(@primitives.NonFiniteValue),
  )
  assert_true(
    @primitives.Rect::new(1.0e308, 0.0, 1.0e308, 1.0)
    is Err(@primitives.BoundsOverflow),
  )
}
