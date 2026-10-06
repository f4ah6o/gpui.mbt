///|
pub struct TextRange {
  start : Int
  end : Int
}

///|
pub fn TextRange::length(
  self : TextRange,
) -> Int where {
  proof_require: valid_text_range(self),
  proof_ensure: result => {
    result == self.end - self.start && 0 <= result && result <= 2147483647
  },
} {
  self.end - self.start
}

///|
fn utf8_scalar_width(
  scalar : Int,
) -> Int where {
  proof_require: valid_unicode_scalar(scalar),
  proof_ensure: result => utf8_width_post(scalar, result),
} {
  if scalar <= 0x7F {
    1
  } else if scalar <= 0x7FF {
    2
  } else if scalar <= 0xFFFF {
    3
  } else {
    4
  }
}

///|
fn utf16_scalar_width(
  scalar : Int,
) -> Int where {
  proof_require: valid_unicode_scalar(scalar),
  proof_ensure: result => utf16_width_post(scalar, result),
} {
  if scalar <= 0xFFFF {
    1
  } else {
    2
  }
}

///|
/// Construct and check a concrete admissible range; no assumed witness.
fn range_preconditions_are_inhabited() -> Unit where { proof_ensure: true, } {
  let witness : TextRange = { start: 0, end: 2147483647, }
  proof_assert valid_text_range(witness)
}
