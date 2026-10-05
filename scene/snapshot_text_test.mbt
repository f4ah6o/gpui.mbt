///|
fn text_snapshot_item(text : String) -> @scene.SceneItem {
  match
    @scene.SceneItem::text(
      2,
      snapshot_rect(1.0, 2.0, 30.0, 20.0),
      text,
      16.0,
      snapshot_color(10, 20, 30),
      @scene.AffineTransform::identity(),
      0.5,
      None,
    ) {
    Ok(item) => item
    Err(_) => abort("valid text item rejected")
  }
}

///|
test "bounded text extends v1 without changing mixed scene order" {
  let viewport = snapshot_rect(0.0, 0.0, 100.0, 50.0)
  let bounds = snapshot_rect(1.0, 2.0, 30.0, 20.0)
  let color = snapshot_color(10, 20, 30)
  let transform = @scene.AffineTransform::identity()
  let first = @scene.QuadItem(
    id=1,
    bounds~,
    color~,
    transform~,
    opacity=1.0,
    clip_chain_id=None,
  )
  let label = text_snapshot_item("Next")
  let last = @scene.QuadItem(
    id=3,
    bounds~,
    color~,
    transform~,
    opacity=1.0,
    clip_chain_id=None,
  )
  match @scene.SceneSnapshot::new(viewport, 1.0, [], [], [first, label, last]) {
    Err(_) => fail("mixed scene rejected")
    Ok(snapshot) => {
      let items = snapshot.items()
      assert_true(items[0].id() == 1)
      assert_true(items[1].id() == 2)
      assert_true(items[2].id() == 3)
      assert_true(items[1].clip_chain_id() is None)
      assert_true(items[1] is @scene.TextItem(text="Next", font_size=16.0, ..))
      assert_eq(
        snapshot.canonical_json(),
        "{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":100,\"height\":50},\"scale\":1,\"resources\":[],\"clip_chains\":[],\"items\":[{\"kind\":\"quad\",\"id\":1,\"bounds\":{\"x\":1,\"y\":2,\"width\":30,\"height\":20},\"color\":{\"red\":10,\"green\":20,\"blue\":30,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null},{\"kind\":\"text\",\"id\":2,\"bounds\":{\"x\":1,\"y\":2,\"width\":30,\"height\":20},\"text\":\"Next\",\"font_size\":16,\"color\":{\"red\":10,\"green\":20,\"blue\":30,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":0.5,\"clip_chain_id\":null},{\"kind\":\"quad\",\"id\":3,\"bounds\":{\"x\":1,\"y\":2,\"width\":30,\"height\":20},\"color\":{\"red\":10,\"green\":20,\"blue\":30,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null}]}",
      )
    }
  }
}

///|
test "text canonical JSON preserves Unicode and escapes controls and punctuation" {
  let viewport = snapshot_rect(0.0, 0.0, 100.0, 50.0)
  let label = text_snapshot_item(
    "日本 😀 e\u0301 \" \\\n\r\t\u0000\u0008\u000c\u001f\u2028\u2029",
  )
  match @scene.SceneSnapshot::new(viewport, 1.0, [], [], [label]) {
    Err(_) => fail("Unicode scene rejected")
    Ok(snapshot) =>
      assert_true(
        snapshot
        .canonical_json()
        .contains(
          "\"text\":\"\\u65e5\\u672c \\ud83d\\ude00 e\\u0301 \\\" \\\\\\n\\r\\t\\u0000\\u0008\\u000c\\u001f\\u2028\\u2029\"",
        ),
      )
  }
}

///|
test "bounded text font and UTF-16 limits are checked by constructors and snapshots" {
  let viewport = snapshot_rect(0.0, 0.0, 100.0, 50.0)
  let color = snapshot_color(10, 20, 30)
  let transform = @scene.AffineTransform::identity()
  for font_size in [0.0, -1.0, 1024.1, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0] {
    assert_true(
      @scene.SceneItem::text(
        1,
        viewport,
        "Label",
        font_size,
        color,
        transform,
        1.0,
        None,
      )
      is Err(InvalidFontSize),
    )
    let bypassed = @scene.TextItem(
      id=1,
      bounds=viewport,
      text="Label",
      font_size~,
      color~,
      transform~,
      opacity=1.0,
      clip_chain_id=None,
    )
    assert_true(
      @scene.SceneSnapshot::new(viewport, 1.0, [], [], [bypassed])
      is Err(InvalidFontSize),
    )
  }
  let boundary = "😀".repeat(32_768)
  assert_eq(boundary.length(), 65_536)
  for text in ["", boundary] {
    assert_true(
      @scene.SceneItem::text(
        1,
        viewport,
        text,
        1024.0,
        color,
        transform,
        1.0,
        None,
      )
      is Ok(_),
    )
  }
  let too_long = boundary + "x"
  assert_true(
    @scene.SceneItem::text(
      1,
      viewport,
      too_long,
      16.0,
      color,
      transform,
      1.0,
      None,
    )
    is Err(TextTooLong),
  )
  let bypassed = @scene.TextItem(
    id=1,
    bounds=viewport,
    text=too_long,
    font_size=16.0,
    color~,
    transform~,
    opacity=1.0,
    clip_chain_id=None,
  )
  assert_true(
    @scene.SceneSnapshot::new(viewport, 1.0, [], [], [bypassed])
    is Err(TextTooLong),
  )
}

///|
test "text snapshots validate opacity and clip references after public enum construction" {
  let viewport = snapshot_rect(0.0, 0.0, 100.0, 50.0)
  let color = snapshot_color(10, 20, 30)
  let transform = match
    @scene.AffineTransform::new(0.0, 1.0, -1.0, 0.0, 80.0, 4.0) {
    Ok(value) => value
    Err(_) => abort("valid transform rejected")
  }
  for opacity in [-0.1, 1.1, 0.0 / 0.0, 1.0 / 0.0] {
    assert_true(
      @scene.SceneItem::text(
        1,
        viewport,
        "Label",
        16.0,
        color,
        transform,
        opacity,
        None,
      )
      is Err(InvalidOpacity),
    )
    let bypassed = @scene.TextItem(
      id=1,
      bounds=viewport,
      text="Label",
      font_size=16.0,
      color~,
      transform~,
      opacity~,
      clip_chain_id=None,
    )
    assert_true(
      @scene.SceneSnapshot::new(viewport, 1.0, [], [], [bypassed])
      is Err(InvalidOpacity),
    )
  }
  let clipped = @scene.TextItem(
    id=1,
    bounds=viewport,
    text="Label",
    font_size=16.0,
    color~,
    transform~,
    opacity=0.25,
    clip_chain_id=Some(7),
  )
  assert_true(clipped.clip_chain_id() == Some(7))
  assert_true(
    @scene.SceneSnapshot::new(viewport, 1.0, [], [], [clipped])
    is Err(UnknownClipChain),
  )
  match
    @scene.SceneSnapshot::new(
      viewport,
      2.0,
      [],
      [@scene.ClipChain::new(7, [viewport])],
      [clipped],
    ) {
    Err(_) => fail("valid clipped transformed text rejected")
    Ok(snapshot) => {
      assert_true(
        snapshot
        .canonical_json()
        .contains(
          "\"transform\":{\"a\":0,\"b\":1,\"c\":-1,\"d\":0,\"tx\":80,\"ty\":4},\"opacity\":0.25,\"clip_chain_id\":7",
        ),
      )
      let copy = snapshot.items()
      ignore(copy.pop())
      assert_eq(snapshot.items().length(), 1)
    }
  }
}
