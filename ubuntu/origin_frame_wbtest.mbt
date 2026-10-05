///|
fn origin_frame_rect(
  x : Double,
  y : Double,
  w : Double,
  h : Double,
) -> @primitives.Rect {
  @primitives.Rect::new(x, y, w, h).unwrap()
}

///|
test "mixed ABI3 preserves legacy fields and independently carries run origin" {
  let viewport = origin_frame_rect(0.0, 0.0, 320.0, 200.0)
  let color = @primitives.Color::rgba(20, 24, 30, 255).unwrap()
  let identity = @scene.AffineTransform::identity()
  let quad = @scene.SceneItem::quad(1, viewport, color, identity, 1.0, None).unwrap()
  let old = @scene.SceneItem::text(
    2,
    origin_frame_rect(8.0, 9.0, 64.0, 32.0),
    "old",
    16.0,
    color,
    identity,
    1.0,
    None,
  ).unwrap()
  let transform = @scene.AffineTransform::new(0.9, 0.2, -0.1, 1.1, 30.0, 50.0).unwrap()
  let run = @scene.SceneItem::text_run(
    3,
    origin_frame_rect(-2.0, -3.0, 40.5, 30.5),
    @primitives.Point::new(1.25, 2.5).unwrap(),
    "jÁ",
    18.0,
    color,
    transform,
    0.75,
    Some(7),
  ).unwrap()
  let chain = @scene.ClipChain::new(7, [
    origin_frame_rect(10.0, 10.0, 20.0, 30.0),
    origin_frame_rect(15.0, 8.0, 30.0, 20.0),
  ])
  let snapshot = @scene.SceneSnapshot::new(viewport, 2.0, [], [chain], [
    quad, old, run,
  ]).unwrap()
  let frame = mixed_frame_data(snapshot).unwrap()
  assert_eq(frame.abi, 3)
  assert_eq(frame.data.length(), 5 + 3 * 25)
  assert_eq(frame.text, b"oldj\xc3\x81")
  for offset in [5, 30] {
    assert_eq(frame.data[offset + 23], 0.0)
    assert_eq(frame.data[offset + 24], 0.0)
  }
  assert_eq(frame.data[5], 0.0)
  assert_eq(frame.data[30], 1.0)
  assert_eq(frame.data[50], 0.0)
  assert_eq(frame.data[51], 3.0)
  assert_eq(frame.data[52], 16.0)
  let offset = 55
  assert_eq(frame.data[offset], 2.0)
  assert_eq(frame.data[offset + 1], -2.0)
  assert_eq(frame.data[offset + 2], -3.0)
  assert_eq(frame.data[offset + 3], 40.5)
  assert_eq(frame.data[offset + 4], 30.5)
  assert_eq(frame.data[offset + 9], 0.9)
  assert_eq(frame.data[offset + 10], 0.2)
  assert_eq(frame.data[offset + 11], -0.1)
  assert_eq(frame.data[offset + 12], 1.1)
  assert_eq(frame.data[offset + 13], 30.0)
  assert_eq(frame.data[offset + 14], 50.0)
  assert_eq(frame.data[offset + 15], 0.75)
  assert_eq(frame.data[offset + 16], 15.0)
  assert_eq(frame.data[offset + 17], 10.0)
  assert_eq(frame.data[offset + 18], 15.0)
  assert_eq(frame.data[offset + 19], 18.0)
  assert_eq(frame.data[offset + 20], 3.0)
  assert_eq(frame.data[offset + 21], 3.0)
  assert_eq(frame.data[offset + 22], 18.0)
  assert_eq(frame.data[offset + 23], 1.25)
  assert_eq(frame.data[offset + 24], 2.5)
}

///|
test "legacy-only text still selects unchanged ABI2 layout" {
  let viewport = origin_frame_rect(0.0, 0.0, 100.0, 80.0)
  let item = @scene.SceneItem::text(
    1,
    origin_frame_rect(2.0, 3.0, 40.0, 20.0),
    "Hi",
    18.0,
    @primitives.Color::rgba(0, 0, 0, 255).unwrap(),
    @scene.AffineTransform::identity(),
    1.0,
    None,
  ).unwrap()
  let snapshot = @scene.SceneSnapshot::new(viewport, 1.0, [], [], [item]).unwrap()
  let frame = mixed_frame_data(snapshot).unwrap()
  assert_eq(frame.abi, 2)
  assert_eq(frame.data.length(), 28)
  assert_eq(frame.data[5], 1.0)
  assert_eq(frame.data[6], 2.0)
  assert_eq(frame.data[7], 3.0)
  assert_eq(frame.data[25], 0.0)
  assert_eq(frame.data[26], 2.0)
  assert_eq(frame.data[27], 18.0)
  assert_eq(frame.text, b"Hi")
}

///|
test "new runs reject malformed text before UTF8 and legacy quad admission" {
  let viewport = origin_frame_rect(0.0, 0.0, 100.0, 80.0)
  let run = @scene.SceneItem::text_run(
    1,
    viewport,
    @primitives.Point::new(0.0, 0.0).unwrap(),
    "😀".unsafe_substring(start=0, end=1),
    18.0,
    @primitives.Color::rgba(0, 0, 0, 255).unwrap(),
    @scene.AffineTransform::identity(),
    1.0,
    None,
  ).unwrap()
  let snapshot = @scene.SceneSnapshot::new(viewport, 1.0, [], [], [run]).unwrap()
  match mixed_frame_data(snapshot) {
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) => fail("lone surrogate was replaced or encoded")
  }
  match frame_data(snapshot) {
    Err(error) => assert_eq(error.code().label(), "unsupported_capability")
    Ok(_) => fail("origin run silently entered legacy quad transport")
  }
}
