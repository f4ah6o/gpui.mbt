///|
test "unique-key scan accepts valid nested objects and independent scopes" {
  assert_true(@mcp.validate_unique_json_keys("{}"))
  assert_true(
    @mcp.validate_unique_json_keys(
      "{\"left\":{\"id\":1},\"right\":[{\"id\":2},{\"id\":3}]}",
    ),
  )
  assert_true(
    @mcp.validate_unique_json_keys(
      "{\"text\":\"\\\"name\\\":1,\\\"name\\\":2\",\"emoji\":\"🦊\"}",
    ),
  )
  assert_true(@mcp.validate_unique_json_keys("[null,true,false,0,-2.5e3]"))
}

///|
test "unique-key scan rejects decoded duplicates at every object depth" {
  assert_false(@mcp.validate_unique_json_keys("{\"name\":1,\"name\":2}"))
  assert_false(
    @mcp.validate_unique_json_keys("{\"outer\":{\"name\":1,\"name\":2}}"),
  )
  assert_false(@mcp.validate_unique_json_keys("{\"a\":1,\"\\u0061\":2}"))
  assert_false(
    @mcp.validate_unique_json_keys("{\"🦊\":1,\"\\ud83e\\udd8a\":2}"),
  )
}

///|
test "unique-key scan is bounded and safely rejects truncated containers" {
  assert_false(@mcp.validate_unique_json_keys("{\"key\":"))
  assert_false(@mcp.validate_unique_json_keys("[1,{\"key\":2}"))

  let nested = StringBuilder()
  let mut depth = 0
  while depth < 32 {
    nested.write_char('[')
    depth += 1
  }
  nested.write_string("0")
  while depth > 0 {
    nested.write_char(']')
    depth -= 1
  }
  assert_true(@mcp.validate_unique_json_keys(nested.to_string()))

  let too_deep = StringBuilder()
  depth = 0
  while depth <= 32 {
    too_deep.write_char('[')
    depth += 1
  }
  too_deep.write_string("0")
  while depth > 0 {
    too_deep.write_char(']')
    depth -= 1
  }
  assert_false(@mcp.validate_unique_json_keys(too_deep.to_string()))

  let oversized = StringBuilder()
  oversized.write_char('"')
  let mut index = 0
  while index < 1_048_576 {
    oversized.write_char('x')
    index += 1
  }
  oversized.write_char('"')
  assert_false(@mcp.validate_unique_json_keys(oversized.to_string()))

  let at_node_limit = StringBuilder()
  at_node_limit.write_char('[')
  let mut node = 0
  while node < 9_999 {
    if node > 0 {
      at_node_limit.write_char(',')
    }
    at_node_limit.write_char('0')
    node += 1
  }
  at_node_limit.write_char(']')
  assert_true(@mcp.validate_unique_json_keys(at_node_limit.to_string()))

  let over_node_limit = StringBuilder()
  over_node_limit.write_char('[')
  node = 0
  while node < 10_000 {
    if node > 0 {
      over_node_limit.write_char(',')
    }
    over_node_limit.write_char('0')
    node += 1
  }
  over_node_limit.write_char(']')
  assert_false(@mcp.validate_unique_json_keys(over_node_limit.to_string()))
}
