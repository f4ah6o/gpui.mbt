///|
test "public constructors and direct items reject non-finite transforms" {
  let bounds = match @primitives.Rect::new(0.0, 0.0, 100.0, 30.0) {
    Ok(value) => value
    Err(_) => abort("fixture bounds rejected")
  }
  let color = match @primitives.Color::rgba(1, 2, 3, 255) {
    Ok(value) => value
    Err(_) => abort("fixture color rejected")
  }
  for value in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0] {
    let transform : AffineTransform = {
      a: 1.0,
      b: 0.0,
      c: 0.0,
      d: 1.0,
      tx: value,
      ty: 0.0,
    }
    assert_true(
      SceneItem::text(1, bounds, "Label", 16.0, color, transform, 1.0, None)
      is Err(NonFiniteTransform),
    )
    assert_true(
      SceneItem::quad(1, bounds, color, transform, 1.0, None)
      is Err(NonFiniteTransform),
    )
    for
      item in [
        TextItem(
          id=1,
          bounds~,
          text="Label",
          font_size=16.0,
          color~,
          transform~,
          opacity=1.0,
          clip_chain_id=None,
        ),
        QuadItem(
          id=1,
          bounds~,
          color~,
          transform~,
          opacity=1.0,
          clip_chain_id=None,
        ),
      ] {
      assert_true(
        SceneSnapshot::new(bounds, 1.0, [], [], [item])
        is Err(NonFiniteTransform),
      )
    }
  }
}

///|
test "canonical text escaping preserves isolated UTF-16 surrogates" {
  let high = "😀".unsafe_substring(start=0, end=1)
  let low = "😀".unsafe_substring(start=1, end=2)
  assert_eq(snapshot_text_json(high), "\"\\ud83d\"")
  assert_eq(snapshot_text_json(low), "\"\\ude00\"")
  assert_eq(snapshot_text_json(high + low), "\"\\ud83d\\ude00\"")
}
