///|
test "dimension resolution rejects indefinite percentages" {
  let half = match @layout.Dimension::percent(0.5) {
    Ok(value) => value
    Err(_) => fail("valid percentage was rejected")
  }
  assert_true(
    @layout.resolve_dimension(half, None) is Err(IndefinitePercentage),
  )
  assert_true(@layout.resolve_dimension(half, Some(80.0)) is Ok(Some(40.0)))
  assert_true(@layout.Dimension::points(-1.0) is Err(NegativeValue))
}

///|
test "row flex grow preserves order gap and deterministic bounds" {
  let size = unwrap_size(100.0, 20.0)
  let intrinsic = unwrap_size(10.0, 8.0)
  let first = unwrap_item_flex(
    @layout.FlexItem::new(
      1,
      unwrap_points(20.0),
      @layout.Dimension::auto(),
      intrinsic,
    ),
    1.0,
    1.0,
  )
  let second = unwrap_item_flex(
    @layout.FlexItem::new(
      2,
      unwrap_points(20.0),
      @layout.Dimension::auto(),
      intrinsic,
    ),
    1.0,
    1.0,
  )
  let container = unwrap_gap(
    @layout.FlexContainer::new(@layout.FlowDirection::row(), size),
    10.0,
  )
  let layout = unwrap_layout(@layout.layout_flex(container, [first, second]))
  let items = layout.items()
  assert_true(items.length() == 2)
  assert_true(items[0].id() == 1 && items[1].id() == 2)
  assert_true(items[0].bounds().left() == 0.0)
  assert_true(items[0].bounds().size().width() == 45.0)
  assert_true(items[1].bounds().left() == 55.0)
  assert_true(items[1].bounds().right() == 100.0)
  assert_true(!layout.overflow())
}

///|
test "fractional exact-fit distribution ignores floating-point residue" {
  let size = unwrap_size(10.0, 20.0)
  let intrinsic = unwrap_size(1.0, 8.0)
  let first = unwrap_item_flex(
    @layout.FlexItem::new(
      21,
      unwrap_points(0.7),
      @layout.Dimension::auto(),
      intrinsic,
    ),
    0.8,
    1.0,
  )
  let second = unwrap_item_flex(
    @layout.FlexItem::new(
      22,
      unwrap_points(9.1),
      @layout.Dimension::auto(),
      intrinsic,
    ),
    1.1,
    1.0,
  )
  let container = unwrap_gap(
    @layout.FlexContainer::new(@layout.FlowDirection::row(), size),
    0.1,
  )
  let layout = unwrap_layout(@layout.layout_flex(container, [first, second]))
  let items = layout.items()
  assert_true(items.length() == 2)
  assert_true(!layout.overflow())
  assert_true(!items[0].overflow())
  assert_true(!items[1].overflow())
}

///|
test "shrink clamps once and reports minimum-driven overflow" {
  let size = unwrap_size(50.0, 20.0)
  let intrinsic = unwrap_size(40.0, 10.0)
  let first = unwrap_main_limits(
    @layout.FlexItem::new(
      1,
      unwrap_points(40.0),
      @layout.Dimension::auto(),
      intrinsic,
    ),
    35.0,
    None,
  )
  let second = unwrap_main_limits(
    @layout.FlexItem::new(
      2,
      unwrap_points(40.0),
      @layout.Dimension::auto(),
      intrinsic,
    ),
    35.0,
    None,
  )
  let container = @layout.FlexContainer::new(@layout.FlowDirection::row(), size)
  let layout = unwrap_layout(@layout.layout_flex(container, [first, second]))
  let items = layout.items()
  assert_true(items[0].bounds().size().width() == 35.0)
  assert_true(items[1].bounds().size().width() == 35.0)
  assert_true(layout.overflow())
  assert_true(items[1].overflow())

  let huge_size = unwrap_size(1.0e308, 20.0)
  let huge_intrinsic = unwrap_size(1.0e308, 10.0)
  let huge_first = @layout.FlexItem::new(
    11,
    unwrap_points(1.0e308),
    @layout.Dimension::auto(),
    huge_intrinsic,
  )
  let huge_second = @layout.FlexItem::new(
    12,
    unwrap_points(1.0e308),
    @layout.Dimension::auto(),
    huge_intrinsic,
  )
  let huge_container = @layout.FlexContainer::new(
    @layout.FlowDirection::row(),
    huge_size,
  )
  assert_true(
    @layout.layout_flex(huge_container, [huge_first, huge_second])
    is Err(NonFiniteValue),
  )
}

///|
test "padding border column alignment and stretch stay platform neutral" {
  let size = unwrap_size(80.0, 100.0)
  let padding = unwrap_insets(4.0, 5.0, 6.0, 7.0)
  let border = unwrap_insets(1.0, 2.0, 3.0, 4.0)
  let intrinsic = unwrap_size(10.0, 10.0)
  let item = @layout.FlexItem::new(
    7,
    unwrap_points(20.0),
    @layout.Dimension::auto(),
    intrinsic,
  )
  let container = @layout.FlexContainer::new(
      @layout.FlowDirection::column(),
      size,
    )
    .with_insets(padding, border)
    .with_align(@layout.AlignItems::stretch())
    .with_justify(@layout.JustifyContent::center())
  let layout = unwrap_layout(@layout.layout_flex(container, [item]))
  let content = layout.content_bounds()
  assert_true(content.left() == 11.0)
  assert_true(content.top() == 5.0)
  assert_true(content.size().width() == 62.0)
  assert_true(content.size().height() == 86.0)
  let bounds = layout.items()[0].bounds()
  assert_true(bounds.left() == content.left())
  assert_true(bounds.size().width() == content.size().width())
  assert_true(bounds.top() == 38.0)
}

///|
test "duplicate ids are rejected before producing layout" {
  let size = unwrap_size(100.0, 30.0)
  let intrinsic = unwrap_size(10.0, 10.0)
  let item = @layout.FlexItem::new(
    9,
    @layout.Dimension::auto(),
    @layout.Dimension::auto(),
    intrinsic,
  )
  let container = @layout.FlexContainer::new(@layout.FlowDirection::row(), size)
  assert_true(@layout.layout_flex(container, [item, item]) is Err(DuplicateId))
}

///|
fn unwrap_size(width : Double, height : Double) -> @primitives.Size raise {
  match @primitives.Size::new(width, height) {
    Ok(value) => value
    Err(_) => fail("valid size was rejected")
  }
}

///|
fn unwrap_points(value : Double) -> @layout.Dimension raise {
  match @layout.Dimension::points(value) {
    Ok(result) => result
    Err(_) => fail("valid point dimension was rejected")
  }
}

///|
fn unwrap_insets(
  top : Double,
  right : Double,
  bottom : Double,
  left : Double,
) -> @layout.Insets raise {
  match @layout.Insets::new(top, right, bottom, left) {
    Ok(value) => value
    Err(_) => fail("valid insets were rejected")
  }
}

///|
fn unwrap_gap(
  container : @layout.FlexContainer,
  gap : Double,
) -> @layout.FlexContainer raise {
  match container.with_gap(gap) {
    Ok(value) => value
    Err(_) => fail("valid gap was rejected")
  }
}

///|
fn unwrap_item_flex(
  item : @layout.FlexItem,
  grow : Double,
  shrink : Double,
) -> @layout.FlexItem raise {
  match item.with_flex(grow, shrink) {
    Ok(value) => value
    Err(_) => fail("valid flex factors were rejected")
  }
}

///|
fn unwrap_main_limits(
  item : @layout.FlexItem,
  min : Double,
  max : Double?,
) -> @layout.FlexItem raise {
  match item.with_main_limits(min, max) {
    Ok(value) => value
    Err(_) => fail("valid main limits were rejected")
  }
}

///|
fn unwrap_layout(
  result : Result[@layout.FlexLayout, @layout.LayoutError],
) -> @layout.FlexLayout raise {
  match result {
    Ok(value) => value
    Err(_) => fail("valid flex layout was rejected")
  }
}
