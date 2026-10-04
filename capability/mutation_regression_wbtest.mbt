///|
fn resource_text(length : Int) -> String {
  let builder = StringBuilder()
  for _index = 0; _index < length; _index = _index + 1 {
    builder.write_char('x')
  }
  builder.to_string()
}

///|
fn assert_transport_stats(
  value : Value,
  nodes : Int,
  chars : Int,
) -> Unit raise {
  match transport_stats(value, 0) {
    Ok((actual_nodes, actual_chars)) => {
      assert_eq(actual_nodes, nodes)
      assert_eq(actual_chars, chars)
    }
    Err(_) =>
      fail("a value exactly within both budgets must have bounded stats")
  }
}

///|
fn assert_transport_stats_rejects(value : Value) -> Unit raise {
  match transport_stats(value, 0) {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) =>
      fail("recursive transport accounting must reject an exhausted budget")
  }
}

///|
test "transport stats rejects oversized array aggregates before returning counters" {
  // The inner array remains valid at both sizes. Only the outer aggregate
  // crosses the node budget, which must be enforced inside recursive stats.
  let leaves = Array::make(9_998, UnitValue)
  let value = ArrayValue([ArrayValue(leaves)])
  assert_transport_stats(value, 10_000, 49_993)
  leaves.push(UnitValue)
  assert_transport_stats_rejects(value)
}

///|
test "transport stats counts object field names against its recursive node budget" {
  let leaves = Array::make(9_997, UnitValue)
  let value = ObjectValue([("k", ArrayValue(leaves))])
  assert_transport_stats(value, 10_000, 49_992)
  leaves.push(UnitValue)
  assert_transport_stats_rejects(value)
}

///|
test "transport stats enforces the scalar JSON budget before returning counters" {
  let exact = resource_text(1_048_574)
  assert_transport_stats(StringValue(exact), 1, 1_048_576)
  assert_transport_stats_rejects(StringValue(exact + "x"))
}

///|
test "transport stats enforces the aggregate array JSON budget before returning counters" {
  let exact = resource_text(1_048_572)
  assert_transport_stats(ArrayValue([StringValue(exact)]), 2, 1_048_576)
  assert_transport_stats_rejects(ArrayValue([StringValue(exact + "x")]))
}

///|
test "transport stats enforces the aggregate object JSON budget before returning counters" {
  let exact = resource_text(1_048_568)
  assert_transport_stats(ObjectValue([("k", StringValue(exact))]), 3, 1_048_576)
  assert_transport_stats_rejects(ObjectValue([("k", StringValue(exact + "x"))]))
}
