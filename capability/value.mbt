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
    ArrayValue(values) => Ok(copy_values(values))
    _ => Err(value_conversion_error("array"))
  }
}

///|
pub fn Value::as_object(
  self : Value,
) -> Result[Array[(String, Value)], @diagnostics.FrameworkError] {
  match self {
    ObjectValue(fields) => Ok(copy_object_fields(fields))
    _ => Err(value_conversion_error("object"))
  }
}

///|
pub fn Value::clone(self : Value) -> Value {
  match self {
    UnitValue => UnitValue
    BoolValue(value) => BoolValue(value)
    IntValue(value) => IntValue(value)
    NumberValue(value) => NumberValue(value)
    StringValue(value) => StringValue(value)
    ArrayValue(values) => ArrayValue(copy_values(values))
    ObjectValue(fields) => ObjectValue(copy_object_fields(fields))
  }
}

///|
/// Canonical JSON used by tests and generated adapters.
pub fn Value::canonical_json(self : Value) -> String {
  match self {
    UnitValue => "null"
    BoolValue(value) => if value { "true" } else { "false" }
    IntValue(value) => "\{value}"
    NumberValue(value) => {
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
    }
    StringValue(value) => "\"\{json_escape(value)}\""
    ArrayValue(values) => {
      let builder = StringBuilder()
      builder.write_string("[")
      for index, value in values {
        if index > 0 {
          builder.write_string(",")
        }
        builder.write_string(value.canonical_json())
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
        builder.write_string(value.canonical_json())
      }
      builder.write_string("}")
      builder.to_string()
    }
  }
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
