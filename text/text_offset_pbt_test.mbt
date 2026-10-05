///|
fn text_offset_pbt_index(value : Int, limit : Int) -> Int {
  let remainder = value % limit
  if remainder < 0 {
    remainder + limit
  } else {
    remainder
  }
}

///|
fn text_offset_pbt_fragment(index : Int) -> String {
  match index {
    0 => "a"
    1 => "\u0000"
    2 => "\n"
    3 => "\u{7F}"
    4 => "\u{80}"
    5 => "\u{7FF}"
    6 => "\u{800}"
    7 => "\u{D7FF}"
    8 => "\u{E000}"
    9 => "\u{FFFF}"
    10 => "\u{10000}"
    11 => "😀"
    12 => "\u{10FFFF}"
    13 => "\u{0301}"
    _ => "\u{200D}"
  }
}

///|
fn text_offset_pbt_utf16_width(index : Int) -> Int {
  if index == 10 || index == 11 || index == 12 {
    2
  } else {
    1
  }
}

///|
fn text_offset_pbt_utf8_width(index : Int) -> Int {
  match index {
    0 | 1 | 2 | 3 => 1
    4 | 5 | 13 => 2
    6 | 7 | 8 | 9 | 14 => 3
    _ => 4
  }
}

///|
fn text_offset_pbt_reference(
  values : Array[Int],
) -> (String, Array[Int], Array[Int]) {
  let builder = StringBuilder()
  let utf16_boundaries = [0]
  let utf8_boundaries = [0]
  let mut utf16_offset = 0
  let mut utf8_offset = 0
  for value in values {
    let index = text_offset_pbt_index(value, 15)
    builder.write_string(text_offset_pbt_fragment(index))
    utf16_offset += text_offset_pbt_utf16_width(index)
    utf8_offset += text_offset_pbt_utf8_width(index)
    utf16_boundaries.push(utf16_offset)
    utf8_boundaries.push(utf8_offset)
  }
  (builder.to_string(), utf16_boundaries, utf8_boundaries)
}

///|
// Stable suite ID: text.utf16-utf8-bridge.invariants
test "property UTF-16 and UTF-8 offsets match independent scalar tables" {
  @quickcheck.check(
    (values : Array[Int]) => {
      let (source, utf16_boundaries, utf8_boundaries) = text_offset_pbt_reference(
        values,
      )
      let document = match @text.TextDocument::new(source) {
        Err(_) => return false
        Ok(value) => value
      }
      if utf16_boundaries.length() != utf8_boundaries.length() ||
        document.utf16_length() !=
        utf16_boundaries[utf16_boundaries.length() - 1] ||
        document.utf8_length() !=
        Ok(utf8_boundaries[utf8_boundaries.length() - 1]) {
        return false
      }
      for boundary in 0..<utf16_boundaries.length() {
        let utf16 = utf16_boundaries[boundary]
        let utf8 = utf8_boundaries[boundary]
        let observed_utf8 = match document.utf8_offset(utf16) {
          Err(_) => return false
          Ok(value) => value
        }
        let observed_utf16 = match document.utf16_offset(utf8) {
          Err(_) => return false
          Ok(value) => value
        }
        if observed_utf8 != utf8 || observed_utf16 != utf16 {
          return false
        }
      }
      for index in 0..<values.length() {
        let scalar_index = text_offset_pbt_index(values[index], 15)
        let utf16_start = utf16_boundaries[index]
        let utf8_start = utf8_boundaries[index]
        for delta in 1..<text_offset_pbt_utf16_width(scalar_index) {
          if !(document.utf8_offset(utf16_start + delta) is Err(SplitSurrogate)) {
            return false
          }
        }
        for delta in 1..<text_offset_pbt_utf8_width(scalar_index) {
          if !(document.utf16_offset(utf8_start + delta) is Err(SplitUtf8)) {
            return false
          }
        }
      }
      let utf16_length = utf16_boundaries[utf16_boundaries.length() - 1]
      let utf8_length = utf8_boundaries[utf8_boundaries.length() - 1]
      document.utf8_offset(-1) is Err(NegativeOffset) &&
      document.utf8_offset(utf16_length + 1) is Err(OutOfBounds) &&
      document.utf16_offset(-1) is Err(NegativeOffset) &&
      document.utf16_offset(utf8_length + 1) is Err(OutOfBounds)
    },
    count=256,
    max_size=32,
    max_shrinks=500,
    seed=4815306127957175914,
  )
}
