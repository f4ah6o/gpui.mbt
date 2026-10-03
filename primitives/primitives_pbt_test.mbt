///|
// Stable suite ID: geometry.rect.invariants
test "property rect unions contain both inputs and scaling is reversible" {
  @quickcheck.check(
    (values : (Int, Int, Int, Int, Int, Int)) => {
      let (x0, y0, w0, h0, x1, y1) = values
      let x = (x0 % 100000).to_double() / 16.0
      let y = (y0 % 100000).to_double() / 16.0
      let width = (w0 % 10000).abs().to_double() / 16.0
      let height = (h0 % 10000).abs().to_double() / 16.0
      let dx = (x1 % 100000).to_double() / 16.0
      let dy = (y1 % 100000).to_double() / 16.0
      match
        (
          @primitives.Rect::new(x, y, width, height),
          @primitives.Rect::new(x + dx, y + dy, width, height),
        ) {
        (Ok(first), Ok(second)) => {
          let union_contains_both = match first.union(second) {
            Ok(union) =>
              union.contains_rect(first) && union.contains_rect(second)
            Err(_) => false
          }
          let scaled_round_trip = match first.scaled(2.0) {
            Ok(enlarged) =>
              enlarged.scaled(0.5) is Ok(restored) && restored == first
            Err(_) => false
          }
          let intersection_is_contained = match first.intersection(second) {
            Some(overlap) =>
              first.contains_rect(overlap) && second.contains_rect(overlap)
            None => true
          }
          union_contains_both && scaled_round_trip && intersection_is_contained
        }
        _ => false
      }
    },
    count=256,
    max_size=64,
    max_shrinks=500,
    seed=12725326473013217044,
  )
}

///|
// Stable suite ID: geometry.rect.translations
test "property rectangle translations preserve dimensions and inverse" {
  @quickcheck.check(
    (values : (Int, Int, Int, Int, Int, Int)) => {
      let (x0, y0, w0, h0, dx0, dy0) = values
      let x = (x0 % 100000).to_double() / 16.0
      let y = (y0 % 100000).to_double() / 16.0
      let width = (w0 % 10000).abs().to_double() / 16.0
      let height = (h0 % 10000).abs().to_double() / 16.0
      let dx = (dx0 % 10000).to_double() / 16.0
      let dy = (dy0 % 10000).to_double() / 16.0
      match
        (
          @primitives.Rect::new(x, y, width, height),
          @primitives.Point::new(dx, dy),
        ) {
        (Ok(rect), Ok(offset)) =>
          match (rect.translated(offset), @primitives.Point::new(-dx, -dy)) {
            (Ok(moved), Ok(reverse_offset)) =>
              match moved.translated(reverse_offset) {
                Ok(restored) => restored == rect
                Err(_) => false
              }
            _ => false
          }
        _ => false
      }
    },
    count=256,
    max_size=64,
    max_shrinks=500,
    seed=13790154211114911481,
  )
}
