///|
// Stable suite ID: layout.flex-line.invariants
test "property flex line preserves order and finite non-negative geometry" {
  @quickcheck.check(
    (values : (Int, Int, Int, Int, Int, Int)) => {
      let (width0, basis0, basis1, grow0, grow1, gap0) = values
      let width = (width0 % 400).abs().to_double() + 20.0
      let basis_a = (basis0 % 120).abs().to_double()
      let basis_b = (basis1 % 120).abs().to_double()
      let grow_a = (grow0 % 8).abs().to_double()
      let grow_b = (grow1 % 8).abs().to_double()
      let gap = (gap0 % 12).abs().to_double()
      match
        (
          @primitives.Size::new(width, 40.0),
          @primitives.Size::new(8.0, 8.0),
          @layout.Dimension::points(basis_a),
          @layout.Dimension::points(basis_b),
        ) {
        (Ok(size), Ok(intrinsic), Ok(main_a), Ok(main_b)) => {
          let first = @layout.FlexItem::new(
            1,
            main_a,
            @layout.Dimension::Auto,
            intrinsic,
          )
          let second = @layout.FlexItem::new(
            2,
            main_b,
            @layout.Dimension::Auto,
            intrinsic,
          )
          match
            (
              first.with_flex(grow_a, 1.0),
              second.with_flex(grow_b, 1.0),
              @layout.FlexContainer::new(@layout.FlowDirection::Row, size).with_gap(
                gap,
              ),
            ) {
            (Ok(a), Ok(b), Ok(container)) =>
              match @layout.layout_flex(container, [a, b]) {
                Err(_) => false
                Ok(result) => {
                  let items = result.items()
                  items.length() == 2 &&
                  items[0].id() == 1 &&
                  items[1].id() == 2 &&
                  items[0].bounds().size().width() >= 0.0 &&
                  items[1].bounds().size().width() >= 0.0 &&
                  items[0].bounds().size().height() >= 0.0 &&
                  items[1].bounds().size().height() >= 0.0 &&
                  items[0].bounds().left() <= items[1].bounds().left()
                }
              }
            _ => false
          }
        }
        _ => false
      }
    },
    count=256,
    max_size=64,
    max_shrinks=500,
    seed=15061911405573824321,
  )
}
