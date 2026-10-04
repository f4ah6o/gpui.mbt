///|
/// Treat object member names as unique before decoding them into `Map`.
///
/// The core JSON parser stores object members in a map and therefore keeps
/// only the last occurrence of a duplicate name. This bounded lexical pass
/// preserves that distinction long enough for the protocol host to reject an
/// ambiguous request. Callers still use `@json.parse` for full JSON validation.
pub fn validate_unique_json_keys(line : String) -> Bool {
  if line.length() > MAX_UNIQUE_KEY_SCAN_CHARS {
    return false
  }
  let input : StringView = line
  let index = Ref(0)
  let nodes = Ref(0)
  if !scan_json_value(input, index, 0, nodes) {
    return false
  }
  skip_json_whitespace(input, index)
  index.val == input.length()
}

///|
const MAX_UNIQUE_KEY_SCAN_CHARS : Int = 1_048_576

///|
const MAX_UNIQUE_KEY_SCAN_DEPTH : Int = 32

///|
const MAX_UNIQUE_KEY_SCAN_NODES : Int = 10_000

///|
fn scan_json_value(
  input : StringView,
  index : Ref[Int],
  depth : Int,
  nodes : Ref[Int],
) -> Bool {
  nodes.val += 1
  if nodes.val > MAX_UNIQUE_KEY_SCAN_NODES {
    return false
  }
  skip_json_whitespace(input, index)
  match json_scan_code(input, index.val) {
    123 => scan_json_object(input, index, depth, nodes)
    91 => scan_json_array(input, index, depth, nodes)
    34 => scan_json_string(input, index)
    -1 => false
    _ => scan_json_atom(input, index)
  }
}

///|
fn scan_json_object(
  input : StringView,
  index : Ref[Int],
  depth : Int,
  nodes : Ref[Int],
) -> Bool {
  if depth >= MAX_UNIQUE_KEY_SCAN_DEPTH {
    return false
  }
  index.val += 1
  skip_json_whitespace(input, index)
  if json_scan_code(input, index.val) == 125 {
    index.val += 1
    return true
  }
  let names : Map[String, Unit] = Map([])
  while index.val < input.length() {
    let name = match scan_json_key(input, index) {
      Some(value) => value
      None => return false
    }
    if names.get(name) is Some(_) {
      return false
    }
    names[name] = ()
    skip_json_whitespace(input, index)
    if json_scan_code(input, index.val) != 58 {
      return false
    }
    index.val += 1
    if !scan_json_value(input, index, depth + 1, nodes) {
      return false
    }
    skip_json_whitespace(input, index)
    match json_scan_code(input, index.val) {
      44 => {
        index.val += 1
        skip_json_whitespace(input, index)
      }
      125 => {
        index.val += 1
        return true
      }
      _ => return false
    }
  }
  false
}

///|
fn scan_json_array(
  input : StringView,
  index : Ref[Int],
  depth : Int,
  nodes : Ref[Int],
) -> Bool {
  if depth >= MAX_UNIQUE_KEY_SCAN_DEPTH {
    return false
  }
  index.val += 1
  skip_json_whitespace(input, index)
  if json_scan_code(input, index.val) == 93 {
    index.val += 1
    return true
  }
  while index.val < input.length() {
    if !scan_json_value(input, index, depth + 1, nodes) {
      return false
    }
    skip_json_whitespace(input, index)
    match json_scan_code(input, index.val) {
      44 => {
        index.val += 1
        skip_json_whitespace(input, index)
      }
      93 => {
        index.val += 1
        return true
      }
      _ => return false
    }
  }
  false
}

///|
fn scan_json_key(input : StringView, index : Ref[Int]) -> String? {
  skip_json_whitespace(input, index)
  if json_scan_code(input, index.val) != 34 {
    return None
  }
  let start = index.val
  if !scan_json_string(input, index) {
    return None
  }
  let encoded = match input.get_view(start~, end=index.val) {
    Some(value) => value
    None => return None
  }
  let decoded = @json.parse(encoded) catch { _ => return None }
  match decoded {
    Json::String(value) => Some(value)
    _ => None
  }
}

///|
fn scan_json_string(input : StringView, index : Ref[Int]) -> Bool {
  if json_scan_code(input, index.val) != 34 {
    return false
  }
  index.val += 1
  while index.val < input.length() {
    let code = json_scan_code(input, index.val)
    if code == 34 {
      index.val += 1
      return true
    }
    if code < 32 {
      return false
    }
    if code == 92 {
      index.val += 2
    } else {
      index.val += 1
    }
  }
  false
}

///|
fn scan_json_atom(input : StringView, index : Ref[Int]) -> Bool {
  let start = index.val
  while index.val < input.length() {
    match json_scan_code(input, index.val) {
      9 | 10 | 13 | 32 | 44 | 93 | 125 => break
      _ => index.val += 1
    }
  }
  index.val > start
}

///|
fn skip_json_whitespace(input : StringView, index : Ref[Int]) -> Unit {
  while index.val < input.length() {
    match json_scan_code(input, index.val) {
      9 | 10 | 13 | 32 => index.val += 1
      _ => break
    }
  }
}

///|
fn json_scan_code(input : StringView, index : Int) -> Int {
  if index < 0 || index >= input.length() {
    -1
  } else {
    input.unsafe_get(index).to_int()
  }
}
