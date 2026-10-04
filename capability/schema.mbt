///|
/// Deterministic, framework-owned schema. The canonical form is transport
/// neutral; validation operates on capability.Value rather than host objects.
pub struct Schema {
  priv canonical : String
  priv unit_like : Bool
  priv validate : (Value) -> Bool
}

///|
pub struct SchemaField {
  priv name : String
  priv schema : Schema
  priv required : Bool
}

///|
pub fn SchemaField::new(
  name : String,
  schema : Schema,
  required : Bool,
) -> Result[SchemaField, @diagnostics.FrameworkError] {
  if name.length() == 0 {
    Err(schema_error("record field name must not be empty"))
  } else {
    Ok({ name, schema, required, })
  }
}

///|
pub fn SchemaField::name(self : SchemaField) -> String {
  self.name
}

///|
pub fn SchemaField::schema(self : SchemaField) -> Schema {
  self.schema
}

///|
pub fn SchemaField::is_required(self : SchemaField) -> Bool {
  self.required
}

///|
pub struct SchemaVariant {
  priv tag : String
  priv schema : Schema
}

///|
pub fn SchemaVariant::new(
  tag : String,
  schema : Schema,
) -> Result[SchemaVariant, @diagnostics.FrameworkError] {
  if tag.length() == 0 {
    Err(schema_error("variant tag must not be empty"))
  } else {
    Ok({ tag, schema, })
  }
}

///|
pub fn SchemaVariant::tag(self : SchemaVariant) -> String {
  self.tag
}

///|
pub fn SchemaVariant::schema(self : SchemaVariant) -> Schema {
  self.schema
}

///|
pub fn Schema::unit() -> Schema {
  {
    canonical: "{\"type\":\"null\"}",
    unit_like: true,
    validate: value => value is UnitValue,
  }
}

///|
pub fn Schema::bool() -> Schema {
  {
    canonical: "{\"type\":\"boolean\"}",
    unit_like: false,
    validate: value => value is BoolValue(_),
  }
}

///|
pub fn Schema::int() -> Schema {
  {
    canonical: "{\"type\":\"integer\"}",
    unit_like: false,
    validate: value => value is IntValue(_),
  }
}

///|
pub fn Schema::number() -> Schema {
  {
    canonical: "{\"type\":\"number\"}",
    unit_like: false,
    validate: value => {
      match value {
        NumberValue(number) => finite_number(number)
        _ => false
      }
    },
  }
}

///|
pub fn Schema::string() -> Schema {
  {
    canonical: "{\"type\":\"string\"}",
    unit_like: false,
    validate: value => value is StringValue(_),
  }
}

///|
pub fn Schema::array(item : Schema) -> Schema {
  let item_schema = item
  {
    canonical: "{\"type\":\"array\",\"items\":\{item.canonical_json()}}",
    unit_like: false,
    validate: value => {
      match value {
        ArrayValue(values) => {
          let mut accepted = true
          let mut index = 0
          while index < values.length() && accepted {
            accepted = item_schema.accepts(values[index])
            index += 1
          }
          accepted
        }
        _ => false
      }
    },
  }
}

///|
pub fn Schema::optional(item : Schema) -> Schema {
  let item_schema = item
  {
    canonical: "{\"anyOf\":[\{item.canonical_json()},{\"type\":\"null\"}]}",
    unit_like: false,
    validate: value => {
      match value {
        UnitValue => true
        _ => item_schema.accepts(value)
      }
    },
  }
}

///|
/// Build an order-independent closed record schema. Field names are sorted in
/// the canonical form and duplicate declarations fail deterministically.
pub fn Schema::record(
  fields : Array[SchemaField],
) -> Result[Schema, @diagnostics.FrameworkError] {
  let sorted = sorted_schema_fields(fields)
  let mut index = 1
  while index < sorted.length() {
    if sorted[index - 1].name == sorted[index].name {
      return Err(schema_error("duplicate record field: \{sorted[index].name}"))
    }
    index += 1
  }
  let builder = StringBuilder()
  builder.write_string("{\"type\":\"object\",\"properties\":{")
  for field_index, field in sorted {
    if field_index > 0 {
      builder.write_string(",")
    }
    builder.write_string("\"")
    builder.write_string(json_escape(field.name))
    builder.write_string("\":")
    builder.write_string(field.schema.canonical_json())
  }
  builder.write_string("},\"required\":[")
  let mut required_count = 0
  for field in sorted {
    if field.required {
      if required_count > 0 {
        builder.write_string(",")
      }
      builder.write_string("\"")
      builder.write_string(json_escape(field.name))
      builder.write_string("\"")
      required_count += 1
    }
  }
  builder.write_string("],\"additionalProperties\":false}")
  let captured = copy_schema_fields(sorted)
  Ok({
    canonical: builder.to_string(),
    unit_like: false,
    validate: value => record_accepts(captured, value),
  })
}

///|
/// Build a deterministic tagged-variant schema. The external representation is
/// a closed object containing the discriminator string and a `value` field.
pub fn Schema::tagged(
  discriminator : String,
  variants : Array[SchemaVariant],
) -> Result[Schema, @diagnostics.FrameworkError] {
  if discriminator.length() == 0 {
    return Err(schema_error("variant discriminator must not be empty"))
  }
  if discriminator == "value" {
    return Err(schema_error("variant discriminator must not be value"))
  }
  let sorted = sorted_schema_variants(variants)
  if sorted.length() == 0 {
    return Err(schema_error("tagged schema requires at least one variant"))
  }
  let mut index = 1
  while index < sorted.length() {
    if sorted[index - 1].tag == sorted[index].tag {
      return Err(schema_error("duplicate variant tag: \{sorted[index].tag}"))
    }
    index += 1
  }
  let builder = StringBuilder()
  builder.write_string("{\"oneOf\":[")
  for variant_index, variant in sorted {
    if variant_index > 0 {
      builder.write_string(",")
    }
    builder.write_string("{\"type\":\"object\",\"properties\":{\"")
    builder.write_string(json_escape(discriminator))
    builder.write_string("\":{\"const\":\"")
    builder.write_string(json_escape(variant.tag))
    builder.write_string("\"},\"value\":")
    builder.write_string(variant.schema.canonical_json())
    builder.write_string("},\"required\":[\"")
    builder.write_string(json_escape(discriminator))
    builder.write_string("\",\"value\"],\"additionalProperties\":false}")
  }
  builder.write_string("]}")
  let captured = copy_schema_variants(sorted)
  let captured_discriminator = discriminator
  Ok({
    canonical: builder.to_string(),
    unit_like: false,
    validate: value => tagged_accepts(captured_discriminator, captured, value),
  })
}

///|
pub fn Schema::canonical_json(self : Schema) -> String {
  self.canonical
}

///|
pub fn Schema::is_unit(self : Schema) -> Bool {
  self.unit_like
}

///|
pub fn Schema::accepts(self : Schema, value : Value) -> Bool {
  (self.validate)(value)
}

///|
fn finite_number(value : Double) -> Bool {
  value == value &&
  value <= 1.7976931348623157e+308 &&
  value >= -1.7976931348623157e+308
}

///|
fn schema_error(message : String) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.InvalidInput,
    "capability.schema",
    subsystem="capability",
    message~,
  )
}

///|
fn sorted_schema_fields(fields : Array[SchemaField]) -> Array[SchemaField] {
  let sorted = copy_schema_fields(fields)
  let mut index = 1
  while index < sorted.length() {
    let current = sorted[index]
    let mut cursor = index
    while cursor > 0 && current.name < sorted[cursor - 1].name {
      sorted[cursor] = sorted[cursor - 1]
      cursor -= 1
    }
    sorted[cursor] = current
    index += 1
  }
  sorted
}

///|
fn copy_schema_fields(fields : Array[SchemaField]) -> Array[SchemaField] {
  let copy : Array[SchemaField] = []
  for field in fields {
    copy.push(field)
  }
  copy
}

///|
fn sorted_schema_variants(
  variants : Array[SchemaVariant],
) -> Array[SchemaVariant] {
  let sorted = copy_schema_variants(variants)
  let mut index = 1
  while index < sorted.length() {
    let current = sorted[index]
    let mut cursor = index
    while cursor > 0 && current.tag < sorted[cursor - 1].tag {
      sorted[cursor] = sorted[cursor - 1]
      cursor -= 1
    }
    sorted[cursor] = current
    index += 1
  }
  sorted
}

///|
fn copy_schema_variants(
  variants : Array[SchemaVariant],
) -> Array[SchemaVariant] {
  let copy : Array[SchemaVariant] = []
  for variant in variants {
    copy.push(variant)
  }
  copy
}

///|
fn record_accepts(fields : Array[SchemaField], value : Value) -> Bool {
  match value {
    ObjectValue(values) => {
      if has_duplicate_value_fields(values) {
        return false
      }
      for field in fields {
        match lookup_value_field(values, field.name) {
          None => if field.required { return false }
          Some(candidate) =>
            if !field.schema.accepts(candidate) {
              return false
            }
        }
      }
      for entry in values {
        let (name, _) = entry
        let mut known = false
        for field in fields {
          if field.name == name {
            known = true
          }
        }
        if !known {
          return false
        }
      }
      true
    }
    _ => false
  }
}

///|
fn tagged_accepts(
  discriminator : String,
  variants : Array[SchemaVariant],
  value : Value,
) -> Bool {
  match value {
    ObjectValue(fields) => {
      if fields.length() != 2 || has_duplicate_value_fields(fields) {
        return false
      }
      let tag = match lookup_value_field(fields, discriminator) {
        Some(StringValue(text)) => text
        _ => return false
      }
      let payload = match lookup_value_field(fields, "value") {
        Some(value) => value
        None => return false
      }
      for variant in variants {
        if variant.tag == tag {
          return variant.schema.accepts(payload)
        }
      }
      false
    }
    _ => false
  }
}

///|
fn lookup_value_field(fields : Array[(String, Value)], name : String) -> Value? {
  for field in fields {
    let (candidate, value) = field
    if candidate == name {
      return Some(value)
    }
  }
  None
}

///|
fn has_duplicate_value_fields(fields : Array[(String, Value)]) -> Bool {
  let mut outer = 0
  while outer < fields.length() {
    let (name, _) = fields[outer]
    let mut inner = outer + 1
    while inner < fields.length() {
      let (candidate, _) = fields[inner]
      if name == candidate {
        return true
      }
      inner += 1
    }
    outer += 1
  }
  false
}
