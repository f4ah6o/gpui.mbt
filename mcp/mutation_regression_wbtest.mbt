///|
test "scanner character lookup uses a sentinel outside the UTF-16 view bounds" {
  let input : StringView = "a🦊z"
  assert_eq(input.length(), 4)
  assert_eq(json_scan_code(input, 0), 97)
  assert_eq(json_scan_code(input, 1), 0xD83E)
  assert_eq(json_scan_code(input, 2), 0xDD8A)
  assert_eq(json_scan_code(input, 3), 122)
  for index in [-2, -1, 4, 5, 1024] {
    assert_eq(json_scan_code(input, index), -1)
  }
  let empty : StringView = ""
  for index in [-1, 0, 1] {
    assert_eq(json_scan_code(empty, index), -1)
  }
}

///|
test "transport checker independently enforces array and object depth bounds" {
  // This helper is a defense-in-depth check on already parsed JSON. Its own
  // recursion budget must remain sound independently of the lexical scanner.
  for object_nodes in [false, true] {
    let mut value = Json::number(0.0)
    for _ in 0..<32 {
      value = if object_nodes {
        Json::object(Map([("child", value)]))
      } else {
        Json::array([value])
      }
    }
    assert_true(json_within_transport_limits(value, 0, Ref(0)))
    value = if object_nodes {
      Json::object(Map([("child", value)]))
    } else {
      Json::array([value])
    }
    assert_false(json_within_transport_limits(value, 0, Ref(0)))
  }
}

///|
test "transport checker independently enforces aggregate node bounds" {
  for object_root in [false, true] {
    for exceeds in [false, true] {
      let size = 9999 -
        (if object_root { 1 } else { 0 }) +
        (if exceeds { 1 } else { 0 })
      let children : Array[Json] = []
      for _ in 0..<size {
        children.push(Json::number(0.0))
      }
      let array = Json::array(children)
      let value = if object_root {
        Json::object(Map([("children", array)]))
      } else {
        array
      }
      assert_eq(json_within_transport_limits(value, 0, Ref(0)), !exceeds)
    }
  }
}

///|
test "lexical container scanners reject depth exhaustion without consuming input" {
  // A caller at the nesting boundary must get failure, not an apparent
  // successful empty parse with an unchanged cursor.
  for depth in [31, 32] {
    let object_cursor = Ref(0)
    assert_eq(scan_json_object("{}", object_cursor, depth, Ref(0)), depth == 31)
    assert_eq(object_cursor.val, if depth == 31 { 2 } else { 0 })
    let array_cursor = Ref(0)
    assert_eq(scan_json_array("[]", array_cursor, depth, Ref(0)), depth == 31)
    assert_eq(array_cursor.val, if depth == 31 { 2 } else { 0 })
  }
}
