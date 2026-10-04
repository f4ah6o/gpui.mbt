///|
/// Framework-owned transport value. Application handlers remain typed; this
/// value is used only at generated/external boundaries.
pub(all) enum Value {
  UnitValue
  BoolValue(Bool)
  IntValue(Int)
  NumberValue(Double)
  StringValue(String)
  ArrayValue(Array[Value])
  ObjectValue(Array[(String, Value)])
}

///|
pub fn Value::unit() -> Value {
  UnitValue
}

///|
pub fn Value::bool(value : Bool) -> Value {
  BoolValue(value)
}

///|
pub fn Value::int(value : Int) -> Value {
  IntValue(value)
}

///|
pub fn Value::number(value : Double) -> Value {
  NumberValue(value)
}

///|
pub fn Value::string(value : String) -> Value {
  StringValue(value)
}

///|
pub fn Value::array(values : Array[Value]) -> Value {
  ArrayValue(copy_values(values))
}

///|
pub fn Value::object(fields : Array[(String, Value)]) -> Value {
  ObjectValue(copy_object_fields(fields))
}

///|
pub fn Value::as_string(
  self : Value,
) -> Result[String, @diagnostics.FrameworkError] {
  match self {
    StringValue(value) => Ok(value)
    _ => Err(value_conversion_error("string"))
  }
}

///|
pub fn Value::as_int(self : Value) -> Result[Int, @diagnostics.FrameworkError] {
  match self {
    IntValue(value) => Ok(value)
    _ => Err(value_conversion_error("integer"))
  }
}

///|
pub fn Value::as_bool(
  self : Value,
) -> Result[Bool, @diagnostics.FrameworkError] {
  match self {
    BoolValue(value) => Ok(value)
    _ => Err(value_conversion_error("boolean"))
  }
}

///|
pub fn Value::as_number(
  self : Value,
) -> Result[Double, @diagnostics.FrameworkError] {
  match self {
    NumberValue(value) => Ok(value)
    _ => Err(value_conversion_error("number"))
  }
}

///|
pub fn Value::as_array(
  self : Value,
) -> Result[Array[Value], @diagnostics.FrameworkError] {
  match self {
    ArrayValue(values) =>
      match self.validate_transport() {
        Err(error) => Err(error)
        Ok(_) => Ok(copy_values(values))
      }
    _ => Err(value_conversion_error("array"))
  }
}

///|
pub fn Value::as_object(
  self : Value,
) -> Result[Array[(String, Value)], @diagnostics.FrameworkError] {
  match self {
    ObjectValue(fields) =>
      match self.validate_transport() {
        Err(error) => Err(error)
        Ok(_) => Ok(copy_object_fields(fields))
      }
    _ => Err(value_conversion_error("object"))
  }
}

///|
pub fn Value::clone(self : Value) -> Value {
  match self.validate_transport() {
    Err(_) => self
    Ok(_) => self.clone_transport_unchecked()
  }
}

///|
/// Clone only a transport-safe value. This is the checked choice for code
/// crossing an erased or host boundary. The compatibility `clone` method
/// returns the original invalid graph unchanged because it cannot report an
/// error; boundary code must use this method instead.
pub fn Value::try_clone_transport(
  self : Value,
) -> Result[Value, @diagnostics.FrameworkError] {
  match self.validate_transport() {
    Err(error) => Err(error)
    Ok(_) => Ok(self.clone_transport_unchecked())
  }
}

///|
fn Value::clone_transport_unchecked(self : Value) -> Value {
  match self {
    UnitValue => UnitValue
    BoolValue(value) => BoolValue(value)
    IntValue(value) => IntValue(value)
    NumberValue(value) => NumberValue(value)
    StringValue(value) => StringValue(value)
    ArrayValue(values) => {
      let copy : Array[Value] = []
      for value in values {
        copy.push(value.clone_transport_unchecked())
      }
      ArrayValue(copy)
    }
    ObjectValue(fields) => {
      let copy : Array[(String, Value)] = []
      for field in fields {
        let (name, value) = field
        copy.push((name, value.clone_transport_unchecked()))
      }
      ObjectValue(copy)
    }
  }
}

///|
/// Validate a transport value before projection or schema traversal. The
/// limits bound recursion and allocation, non-finite numbers and duplicate
/// object fields are rejected, and depth bounds reject cyclic mutable arrays.
pub fn Value::validate_transport(
  self : Value,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match transport_stats(self, 0) {
    Err(error) => Err(error)
    Ok((nodes, json_chars)) =>
      if nodes > 10_000 {
        Err(transport_error("value exceeds the 10000 node limit"))
      } else if json_chars > 1_048_576 {
        Err(
          transport_error("canonical JSON exceeds the 1048576 character limit"),
        )
      } else {
        Ok(())
      }
  }
}

///|
/// Canonical JSON with a typed failure for values outside the bounded
/// transport subset.
pub fn Value::try_canonical_json(
  self : Value,
) -> Result[String, @diagnostics.FrameworkError] {
  match self.validate_transport() {
    Err(error) => Err(error)
    Ok(_) => Ok(self.canonical_json_unchecked())
  }
}

///|
/// Convenience projection for validated values. Invalid or cyclic graphs
/// return an empty string; boundary code should use `try_canonical_json` to
/// retain the diagnostic.
pub fn Value::canonical_json(self : Value) -> String {
  match self.try_canonical_json() {
    Ok(json) => json
    Err(_) => ""
  }
}

///|
fn Value::canonical_json_unchecked(self : Value) -> String {
  match self {
    UnitValue => "null"
    BoolValue(value) => if value { "true" } else { "false" }
    IntValue(value) => "\{value}"
    NumberValue(value) =>
      if value != value {
        "\"NaN\""
      } else if value > 1.7976931348623157e+308 {
        "\"Infinity\""
      } else if value < -1.7976931348623157e+308 {
        "\"-Infinity\""
      } else {
        let normalized = if value == 0.0 { 0.0 } else { value }
        "\{normalized}"
      }
    StringValue(value) => "\"\{json_escape(value)}\""
    ArrayValue(values) => {
      let builder = StringBuilder()
      builder.write_string("[")
      for index, value in values {
        if index > 0 {
          builder.write_string(",")
        }
        builder.write_string(value.canonical_json_unchecked())
      }
      builder.write_string("]")
      builder.to_string()
    }
    ObjectValue(fields) => {
      let sorted = sorted_object_fields(fields)
      let builder = StringBuilder()
      builder.write_string("{")
      for index, field in sorted {
        if index > 0 {
          builder.write_string(",")
        }
        let (name, value) = field
        builder.write_string("\"")
        builder.write_string(json_escape(name))
        builder.write_string("\":")
        builder.write_string(value.canonical_json_unchecked())
      }
      builder.write_string("}")
      builder.to_string()
    }
  }
}

///|
fn transport_stats(
  value : Value,
  depth : Int,
) -> Result[(Int, Int), @diagnostics.FrameworkError] {
  if depth > 32 {
    return Err(transport_error("value exceeds the depth limit of 32"))
  }
  match value {
    UnitValue => Ok((1, 4))
    BoolValue(boolean) => Ok((1, if boolean { 4 } else { 5 }))
    IntValue(integer) => Ok((1, "\{integer}".length()))
    NumberValue(number) =>
      if !finite_number(number) {
        Err(transport_error("non-finite numbers are not transportable"))
      } else {
        let normalized = if number == 0.0 { 0.0 } else { number }
        Ok((1, "\{normalized}".length()))
      }
    StringValue(text) => {
      let chars = escaped_json_string_length(text)
      if chars > 1_048_576 {
        Err(
          transport_error("canonical JSON exceeds the 1048576 character limit"),
        )
      } else {
        Ok((1, chars))
      }
    }
    ArrayValue(values) => {
      if values.length() > 9_999 {
        return Err(transport_error("array exceeds the 10000 node limit"))
      }
      let mut nodes = 1
      let mut chars = 2
      for index, child in values {
        match transport_stats(child, depth + 1) {
          Err(error) => return Err(error)
          Ok((child_nodes, child_chars)) => {
            nodes += child_nodes
            chars += child_chars
            if index > 0 {
              chars += 1
            }
            if nodes > 10_000 {
              return Err(transport_error("value exceeds the 10000 node limit"))
            }
            if chars > 1_048_576 {
              return Err(
                transport_error(
                  "canonical JSON exceeds the 1048576 character limit",
                ),
              )
            }
          }
        }
      }
      Ok((nodes, chars))
    }
    ObjectValue(fields) => {
      if fields.length() > 1_024 {
        return Err(transport_error("object exceeds the 1024 field limit"))
      }
      let mut outer = 0
      while outer < fields.length() {
        let (name, _) = fields[outer]
        let mut inner = outer + 1
        while inner < fields.length() {
          let (candidate, _) = fields[inner]
          if name == candidate {
            return Err(
              transport_error("object contains a duplicate field name"),
            )
          }
          inner += 1
        }
        outer += 1
      }
      let mut nodes = 1
      let mut chars = 2
      for index, field in fields {
        let (name, child) = field
        match transport_stats(child, depth + 1) {
          Err(error) => return Err(error)
          Ok((child_nodes, child_chars)) => {
            nodes += child_nodes + 1
            // The quoted field name already includes its quotes. Add the
            // colon and the child value; commas are counted separately.
            chars += escaped_json_string_length(name) + 1 + child_chars
            if index > 0 {
              chars += 1
            }
            if nodes > 10_000 {
              return Err(transport_error("value exceeds the 10000 node limit"))
            }
            if chars > 1_048_576 {
              return Err(
                transport_error(
                  "canonical JSON exceeds the 1048576 character limit",
                ),
              )
            }
          }
        }
      }
      Ok((nodes, chars))
    }
  }
}

///|
fn escaped_json_string_length(text : String) -> Int {
  // String.length() counts UTF-16 code units, matching canonical JSON's
  // observable length. It also lets oversized input stop before scanning.
  if text.length() > 1_048_576 {
    return 1_048_577
  }
  let mut length = 2
  for character in text {
    match character {
      '"' | '\\' | '\n' | '\r' | '\t' => length += 2
      _ => {
        let code = character.to_int()
        if code < 0x20 {
          length += 6
        } else if code > 0xffff {
          length += 2
        } else {
          length += 1
        }
      }
    }
    if length > 1_048_576 {
      return 1_048_577
    }
  }
  length
}

///|
fn transport_error(message : String) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.InvalidInput,
    "capability.value.transport",
    subsystem="capability",
    message~,
  )
}

///|
pub fn json_escape(text : String) -> String {
  let builder = StringBuilder()
  for character in text {
    match character {
      '"' => builder.write_string("\\\"")
      '\\' => builder.write_string("\\\\")
      '\n' => builder.write_string("\\n")
      '\r' => builder.write_string("\\r")
      '\t' => builder.write_string("\\t")
      _ => {
        let code = character.to_int()
        if code < 0x20 {
          builder.write_string("\\u00")
          builder.write_char(hex_digit(code / 16))
          builder.write_char(hex_digit(code % 16))
        } else {
          builder.write_char(character)
        }
      }
    }
  }
  builder.to_string()
}

///|
fn hex_digit(value : Int) -> Char {
  match value {
    0 => '0'
    1 => '1'
    2 => '2'
    3 => '3'
    4 => '4'
    5 => '5'
    6 => '6'
    7 => '7'
    8 => '8'
    9 => '9'
    10 => 'a'
    11 => 'b'
    12 => 'c'
    13 => 'd'
    14 => 'e'
    15 => 'f'
    _ => '0'
  }
}

///|
fn value_conversion_error(expected : String) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.ConversionFailed,
    "capability.value",
    subsystem="capability",
    message="expected \{expected}",
  )
}

///|
fn copy_values(values : Array[Value]) -> Array[Value] {
  let copy : Array[Value] = []
  for value in values {
    copy.push(value.clone())
  }
  copy
}

///|
fn copy_object_fields(
  fields : Array[(String, Value)],
) -> Array[(String, Value)] {
  let copy : Array[(String, Value)] = []
  for field in fields {
    let (name, value) = field
    copy.push((name, value.clone()))
  }
  copy
}

///|
fn sorted_object_fields(
  fields : Array[(String, Value)],
) -> Array[(String, Value)] {
  let sorted = copy_object_fields(fields)
  let mut index = 1
  while index < sorted.length() {
    let current = sorted[index]
    let mut cursor = index
    while cursor > 0 {
      let (current_name, _) = current
      let (previous_name, _) = sorted[cursor - 1]
      if !(current_name < previous_name) {
        break
      }
      sorted[cursor] = sorted[cursor - 1]
      cursor -= 1
    }
    sorted[cursor] = current
    index += 1
  }
  sorted
}
