///|
fn[T] mutation_ok(result : Result[T, @diagnostics.FrameworkError]) -> T raise {
  match result {
    Ok(value) => value
    Err(_) => fail("unexpected failure")
  }
}

///|
fn[T] mutation_invalid(
  result : Result[T, @diagnostics.FrameworkError],
) -> Unit raise {
  match result {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) => fail("invalid value was accepted")
  }
}

///|
fn mutation_repeat(text : String, count : Int) -> String {
  let builder = StringBuilder()
  for _index = 0; _index < count; _index = _index + 1 {
    builder.write_string(text)
  }
  builder.to_string()
}

///|
fn mutation_descriptor(
  id : String,
  exposure : @capability.Exposure,
  external_name : String?,
  version : Int,
) -> Result[@capability.Descriptor, @diagnostics.FrameworkError] {
  @capability.Descriptor::new(
    id,
    "Title",
    "Description",
    @capability.Workflow,
    @capability.Schema::int(),
    @capability.Schema::int(),
    @capability.ExternalSideEffect,
    false,
    exposure,
    external_name,
    version,
  )
}

///|
fn mutation_identity(
  descriptor : @capability.Descriptor,
) -> @capability.TypedCapability[Int, Int] {
  @capability.TypedCapability::new(
    descriptor,
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => Ok(value),
    () => Ok(()),
    _origin => Ok(()),
  )
}

///|
test "record declarations reject empty and duplicate names without changing caller order" {
  mutation_invalid(
    @capability.SchemaField::new("", @capability.Schema::int(), true),
  )
  let a = mutation_ok(
    @capability.SchemaField::new("a", @capability.Schema::int(), true),
  )
  let b = mutation_ok(
    @capability.SchemaField::new("b", @capability.Schema::bool(), false),
  )
  let z = mutation_ok(
    @capability.SchemaField::new("z", @capability.Schema::string(), true),
  )
  let fields = [z, b, a]
  let schema = mutation_ok(@capability.Schema::record(fields))
  assert_eq(fields[0].name(), "z")
  assert_true(a.is_required())
  assert_true(!b.is_required())
  assert_eq(
    a.schema().canonical_json(),
    @capability.Schema::int().canonical_json(),
  )
  assert_eq(
    schema.canonical_json(),
    "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\",\"minimum\":-2147483648,\"maximum\":2147483647},\"b\":{\"type\":\"boolean\"},\"z\":{\"type\":\"string\"}},\"required\":[\"a\",\"z\"],\"additionalProperties\":false}",
  )
  mutation_invalid(@capability.Schema::record([a, z, a]))
  mutation_invalid(@capability.Schema::record([z, a, z]))
  fields.clear()
  assert_true(
    schema.accepts(
      @capability.ObjectValue([
        ("a", @capability.IntValue(2)),
        ("z", @capability.StringValue("yes")),
      ]),
    ),
  )
}

///|
test "closed record validates every field type and rejects raw duplicate keys" {
  let a = mutation_ok(
    @capability.SchemaField::new("a", @capability.Schema::int(), true),
  )
  let b = mutation_ok(
    @capability.SchemaField::new("b", @capability.Schema::bool(), false),
  )
  let schema = mutation_ok(@capability.Schema::record([b, a]))
  assert_true(schema.is_object())
  assert_true(!schema.is_unit())
  assert_true(
    schema.accepts(@capability.ObjectValue([("a", @capability.IntValue(1))])),
  )
  for
    value in [
      @capability.UnitValue,
      @capability.ArrayValue([]),
      @capability.ObjectValue([]),
      @capability.ObjectValue([("a", @capability.StringValue("1"))]),
      @capability.ObjectValue([
        ("a", @capability.IntValue(1)),
        ("b", @capability.StringValue("false")),
      ]),
      @capability.ObjectValue([
        ("a", @capability.IntValue(1)),
        ("b", @capability.BoolValue(false)),
        ("a", @capability.IntValue(2)),
      ]),
      @capability.ObjectValue([
        ("a", @capability.IntValue(1)),
        ("b", @capability.BoolValue(false)),
        ("b", @capability.BoolValue(true)),
      ]),
    ] {
    assert_true(!schema.accepts(value))
  }
  let empty = mutation_ok(@capability.Schema::record([]))
  assert_eq(
    empty.canonical_json(),
    "{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}",
  )
  assert_true(empty.accepts(@capability.ObjectValue([])))
  assert_true(
    !empty.accepts(@capability.ObjectValue([("extra", @capability.UnitValue)])),
  )
}

///|
test "tagged declarations validate names sort tags and retain their schema snapshot" {
  mutation_invalid(
    @capability.SchemaVariant::new("", @capability.Schema::unit()),
  )
  let a = mutation_ok(
    @capability.SchemaVariant::new("a", @capability.Schema::int()),
  )
  let b = mutation_ok(
    @capability.SchemaVariant::new("b", @capability.Schema::bool()),
  )
  let z = mutation_ok(
    @capability.SchemaVariant::new("z", @capability.Schema::string()),
  )
  mutation_invalid(@capability.Schema::tagged("", [a]))
  mutation_invalid(@capability.Schema::tagged("kind", []))
  mutation_invalid(@capability.Schema::tagged("kind", [a, z, a]))
  mutation_invalid(@capability.Schema::tagged("kind", [z, a, z]))
  let variants = [z, b, a]
  let schema = mutation_ok(@capability.Schema::tagged("kind", variants))
  assert_eq(variants[0].tag(), "z")
  assert_eq(
    b.schema().canonical_json(),
    @capability.Schema::bool().canonical_json(),
  )
  assert_eq(
    schema.canonical_json(),
    "{\"oneOf\":[{\"type\":\"object\",\"properties\":{\"kind\":{\"const\":\"a\"},\"value\":{\"type\":\"integer\",\"minimum\":-2147483648,\"maximum\":2147483647}},\"required\":[\"kind\",\"value\"],\"additionalProperties\":false},{\"type\":\"object\",\"properties\":{\"kind\":{\"const\":\"b\"},\"value\":{\"type\":\"boolean\"}},\"required\":[\"kind\",\"value\"],\"additionalProperties\":false},{\"type\":\"object\",\"properties\":{\"kind\":{\"const\":\"z\"},\"value\":{\"type\":\"string\"}},\"required\":[\"kind\",\"value\"],\"additionalProperties\":false}]}",
  )
  variants.clear()
  assert_true(schema.is_object())
  assert_true(!schema.is_unit())
  assert_true(
    schema.accepts(
      @capability.ObjectValue([
        ("value", @capability.StringValue("last")),
        ("kind", @capability.StringValue("z")),
      ]),
    ),
  )
  assert_true(
    schema.accepts(
      @capability.ObjectValue([
        ("kind", @capability.StringValue("a")),
        ("value", @capability.IntValue(7)),
      ]),
    ),
  )
}

///|
test "tagged values require exactly one known string discriminator and a matching payload" {
  let a = mutation_ok(
    @capability.SchemaVariant::new("a", @capability.Schema::int()),
  )
  let schema = mutation_ok(@capability.Schema::tagged("kind", [a]))
  for
    value in [
      @capability.UnitValue,
      @capability.ObjectValue([]),
      @capability.ObjectValue([("kind", @capability.StringValue("a"))]),
      @capability.ObjectValue([("value", @capability.IntValue(1))]),
      @capability.ObjectValue([
        ("kind", @capability.StringValue("a")),
        ("extra", @capability.IntValue(1)),
      ]),
      @capability.ObjectValue([
        ("other", @capability.StringValue("a")),
        ("value", @capability.IntValue(1)),
      ]),
      @capability.ObjectValue([
        ("kind", @capability.IntValue(1)),
        ("value", @capability.IntValue(1)),
      ]),
      @capability.ObjectValue([
        ("kind", @capability.StringValue("unknown")),
        ("value", @capability.IntValue(1)),
      ]),
      @capability.ObjectValue([
        ("kind", @capability.StringValue("a")),
        ("value", @capability.StringValue("wrong")),
      ]),
      @capability.ObjectValue([
        ("kind", @capability.StringValue("a")),
        ("value", @capability.IntValue(1)),
        ("extra", @capability.UnitValue),
      ]),
      @capability.ObjectValue([
        ("kind", @capability.StringValue("a")),
        ("value", @capability.IntValue(1)),
        ("kind", @capability.StringValue("a")),
      ]),
      @capability.ObjectValue([
        ("kind", @capability.StringValue("a")),
        ("kind", @capability.StringValue("a")),
      ]),
    ] {
    assert_true(!schema.accepts(value))
  }
}

///|
test "scalar array and optional schemas preserve value kinds" {
  assert_true(@capability.Schema::unit().is_unit())
  assert_true(!@capability.Schema::unit().is_object())
  assert_true(!@capability.Schema::number().accepts(@capability.IntValue(1)))
  assert_true(
    @capability.Schema::number().accepts(@capability.NumberValue(1.5)),
  )
  assert_true(
    @capability.Schema::number().accepts(
      @capability.NumberValue(-1.7976931348623157e+308),
    ),
  )
  assert_true(
    @capability.Schema::number().accepts(
      @capability.NumberValue(1.7976931348623157e+308),
    ),
  )
  let array = @capability.Schema::int().array()
  assert_true(!array.is_object())
  assert_true(!array.is_unit())
  assert_true(array.accepts(@capability.ArrayValue([])))
  assert_true(
    array.accepts(
      @capability.ArrayValue([@capability.IntValue(1), @capability.IntValue(2)]),
    ),
  )
  assert_true(!array.accepts(@capability.UnitValue))
  assert_true(
    !array.accepts(
      @capability.ArrayValue([
        @capability.IntValue(1),
        @capability.BoolValue(false),
      ]),
    ),
  )
  let optional = @capability.Schema::bool().optional()
  assert_true(!optional.is_unit())
  assert_true(!optional.is_object())
  assert_true(optional.accepts(@capability.UnitValue))
  assert_true(optional.accepts(@capability.BoolValue(false)))
  assert_true(!optional.accepts(@capability.StringValue("false")))
}

///|
test "canonical values sort nested object names and normalize signed zero" {
  assert_eq(@capability.Value::bool(false).canonical_json(), "false")
  assert_eq(@capability.Value::bool(true).canonical_json(), "true")
  assert_eq(
    @capability.Value::number(-0.0).canonical_json(),
    @capability.Value::number(0.0).canonical_json(),
  )
  assert_eq(@capability.Value::number(1.5).canonical_json(), "1.5")
  for
    names in [
      ["a", "b", "z"],
      ["a", "z", "b"],
      ["b", "a", "z"],
      ["b", "z", "a"],
      ["z", "a", "b"],
      ["z", "b", "a"],
    ] {
    let fields = names.map(name => (name, @capability.StringValue(name)))
    assert_eq(
      @capability.ObjectValue(fields).canonical_json(),
      "{\"a\":\"a\",\"b\":\"b\",\"z\":\"z\"}",
    )
    assert_eq(fields.map(field => field.0), names)
  }
  let fields = [
    ("z", @capability.IntValue(3)),
    ("b", @capability.BoolValue(false)),
    ("a", @capability.StringValue("first")),
  ]
  let value = @capability.ObjectValue(fields)
  assert_eq(value.canonical_json(), "{\"a\":\"first\",\"b\":false,\"z\":3}")
  assert_eq(fields[0].0, "z")
  let outer = @capability.ObjectValue([
    ("z", value),
    (
      "a",
      @capability.ArrayValue([
        @capability.UnitValue,
        @capability.BoolValue(false),
      ]),
    ),
  ])
  assert_eq(
    outer.canonical_json(),
    "{\"a\":[null,false],\"z\":{\"a\":\"first\",\"b\":false,\"z\":3}}",
  )
}

///|
test "transport copies isolate nested mutable input and accessor results" {
  let children : Array[@capability.Value] = [@capability.IntValue(7)]
  let fields = [("items", @capability.ArrayValue(children))]
  let original = @capability.ObjectValue(fields)
  let copied = mutation_ok(original.try_clone_transport())
  let constructed = @capability.Value::object(fields)
  let access = mutation_ok(original.as_object())
  let copied_array = @capability.Value::array([original])
  children[0] = @capability.IntValue(99)
  fields.clear()
  for snapshot in [copied, constructed, @capability.ObjectValue(access)] {
    assert_eq(snapshot.canonical_json(), "{\"items\":[7]}")
  }
  assert_eq(copied_array.canonical_json(), "[{\"items\":[7]}]")
  let unpacked = mutation_ok(copied_array.as_array())
  unpacked.clear()
  assert_eq(copied_array.canonical_json(), "[{\"items\":[7]}]")
}

///|
test "transport accepts exact depth and node boundaries including object field names" {
  let mut nested = @capability.UnitValue
  for _index = 0; _index < 32; _index = _index + 1 {
    nested = @capability.ArrayValue([nested])
  }
  assert_true(nested.validate_transport() is Ok(_))
  mutation_invalid(@capability.ArrayValue([nested]).validate_transport())
  let mut nested_object = @capability.UnitValue
  let mut mixed = @capability.UnitValue
  for index = 0; index < 32; index = index + 1 {
    nested_object = @capability.ObjectValue([("child", nested_object)])
    mixed = if index % 2 == 0 {
      @capability.ArrayValue([mixed])
    } else {
      @capability.ObjectValue([("child", mixed)])
    }
  }
  assert_true(nested_object.validate_transport() is Ok(_))
  assert_true(mixed.validate_transport() is Ok(_))
  mutation_invalid(
    @capability.ObjectValue([("child", nested_object)]).validate_transport(),
  )
  mutation_invalid(
    @capability.ObjectValue([("child", mixed)]).validate_transport(),
  )
  let items = Array::make(9_999, @capability.UnitValue)
  assert_true(@capability.ArrayValue(items).validate_transport() is Ok(_))
  items.push(@capability.UnitValue)
  mutation_invalid(@capability.ArrayValue(items).validate_transport())
  // One object, one field name, one array and 9997 leaves total 10000 nodes.
  let leaves = Array::make(9_997, @capability.UnitValue)
  let object = @capability.ObjectValue([
    ("items", @capability.ArrayValue(leaves)),
  ])
  assert_true(object.validate_transport() is Ok(_))
  leaves.push(@capability.UnitValue)
  mutation_invalid(object.validate_transport())
  let pair = @capability.ArrayValue([
    @capability.ArrayValue(Array::make(4_998, @capability.UnitValue)),
    @capability.ArrayValue(Array::make(4_999, @capability.UnitValue)),
  ])
  assert_true(pair.validate_transport() is Ok(_))
  mutation_invalid(@capability.ArrayValue([pair]).validate_transport())
}

///|
test "transport caps object fields independently of total node count" {
  let fields : Array[(String, @capability.Value)] = []
  for index = 0; index < 1_024; index = index + 1 {
    fields.push(("field_\{index}", @capability.UnitValue))
  }
  assert_true(@capability.ObjectValue(fields).validate_transport() is Ok(_))
  fields.push(("one_more", @capability.UnitValue))
  mutation_invalid(@capability.ObjectValue(fields).validate_transport())
}

///|
fn mutation_json_boundary(make : (String) -> @capability.Value) -> Unit raise {
  let overhead = mutation_ok(make("").try_canonical_json()).length()
  let exact = mutation_repeat("x", 1_048_576 - overhead)
  let value = make(exact)
  assert_true(value.validate_transport() is Ok(_))
  assert_eq(mutation_ok(value.try_canonical_json()).length(), 1_048_576)
  mutation_invalid(make(exact + "x").validate_transport())
}

///|
test "transport JSON budget counts booleans numbers commas and object punctuation" {
  mutation_json_boundary(text => @capability.StringValue(text))
  mutation_json_boundary(text => {
    @capability.ArrayValue([
      @capability.StringValue(text),
      @capability.BoolValue(false),
    ])
  })
  mutation_json_boundary(text => {
    @capability.ArrayValue([
      @capability.BoolValue(true),
      @capability.StringValue(text),
    ])
  })
  mutation_json_boundary(text => {
    @capability.ArrayValue([
      @capability.StringValue(text),
      @capability.NumberValue(1.5),
    ])
  })
  mutation_json_boundary(text => {
    @capability.ArrayValue([
      @capability.StringValue(text),
      @capability.NumberValue(-0.0),
    ])
  })
  mutation_json_boundary(text => {
    @capability.ObjectValue([
      ("a", @capability.StringValue(text)),
      ("b", @capability.BoolValue(false)),
    ])
  })
  mutation_json_boundary(text => {
    @capability.ObjectValue([(text, @capability.UnitValue)])
  })
}

///|
test "transport JSON budget counts escaped controls and supplementary Unicode" {
  // Observable JSON lengths include both quotes and UTF-16 surrogate pairs.
  for
    (suffix, encoded_length) in [
      ("\u{1f}", 6),
      ("🦊", 2),
      ("\"", 2),
      ("\\", 2),
      ("\n", 2),
      ("\r", 2),
      ("\t", 2),
    ] {
    let text = mutation_repeat("x", 1_048_574 - encoded_length) + suffix
    let value = @capability.StringValue(text)
    assert_true(value.validate_transport() is Ok(_))
    assert_eq(mutation_ok(value.try_canonical_json()).length(), 1_048_576)
    mutation_invalid(@capability.StringValue(text + "x").validate_transport())
  }
  mutation_invalid(
    @capability.StringValue(mutation_repeat("x", 1_048_577)).validate_transport(),
  )
}

///|
test "descriptor names versions and explicit aliases enforce their contract" {
  mutation_invalid(mutation_descriptor("", @capability.External, None, 1))
  mutation_invalid(mutation_descriptor("valid", @capability.External, None, 0))
  mutation_invalid(mutation_descriptor("valid", @capability.External, None, -1))
  mutation_invalid(
    mutation_descriptor("valid", @capability.External, Some(""), 1),
  )
  let derived = mutation_ok(
    mutation_descriptor(
      "document.part-file/read",
      @capability.External,
      None,
      2,
    ),
  )
  assert_eq(derived.external_name(), "document_part_file_read")
  assert_eq(derived.id(), "document.part-file/read")
  assert_eq(derived.title(), "Title")
  assert_eq(derived.description(), "Description")
  assert_true(derived.kind() is @capability.Workflow)
  assert_true(derived.effect() is @capability.ExternalSideEffect)
  assert_true(!derived.is_idempotent())
  assert_eq(derived.version(), 2)
  let explicit = mutation_ok(
    mutation_descriptor("other", @capability.Local, Some("literal.name"), 1),
  )
  assert_eq(explicit.external_name(), "literal.name")
  assert_true(explicit.exposure() is @capability.Local)
}

///|
test "registry enumeration is lexically sorted and failed collisions do not adopt handles" {
  let registry = @capability.Registry::new()
  for
    (id, exposure) in [
      ("z", @capability.External),
      ("b", @capability.Internal),
      ("a", @capability.Local),
      ("c", @capability.External),
    ] {
    assert_true(
      registry.register(
        mutation_identity(
          mutation_ok(mutation_descriptor(id, exposure, None, 1)),
        ),
      )
      is Ok(_),
    )
  }
  let descriptors = registry.descriptors()
  assert_eq(descriptors.map(value => value.id()), ["a", "b", "c", "z"])
  assert_eq(registry.external_descriptors().map(value => value.id()), ["c", "z"])
  descriptors.clear()
  assert_eq(registry.descriptors().length(), 4)
  let duplicate = mutation_identity(
    mutation_ok(
      mutation_descriptor("a", @capability.Internal, Some("unused"), 1),
    ),
  )
  mutation_invalid(registry.register(duplicate))
  let collision = mutation_identity(
    mutation_ok(
      mutation_descriptor("different", @capability.External, Some("z"), 1),
    ),
  )
  mutation_invalid(registry.register(collision))
  let other = @capability.Registry::new()
  assert_true(other.register(collision) is Ok(_))
  assert_true(other.register(duplicate) is Ok(_))
  registry.teardown()
  assert_true(collision.invoke(@capability.Direct, 7) is Ok(7))
  assert_true(duplicate.invoke(@capability.Direct, 8) is Ok(8))
}

///|
test "external name collisions apply only between externally exposed operations" {
  for first in [@capability.Internal, @capability.Local, @capability.External] {
    for
      second in [@capability.Internal, @capability.Local, @capability.External] {
      let registry = @capability.Registry::new()
      assert_true(
        registry.register(
          mutation_identity(
            mutation_ok(mutation_descriptor("one", first, Some("shared"), 1)),
          ),
        )
        is Ok(_),
      )
      let result = registry.register(
        mutation_identity(
          mutation_ok(mutation_descriptor("two", second, Some("shared"), 1)),
        ),
      )
      if first is @capability.External && second is @capability.External {
        mutation_invalid(result)
      } else {
        assert_true(result is Ok(_))
      }
    }
  }
}

///|
test "every invocation origin enforces exposure before availability policy or execution" {
  for
    exposure in [@capability.Internal, @capability.Local, @capability.External] {
    for
      origin in [
        @capability.Gui,
        @capability.Direct,
        @capability.LocalAutomation,
        @capability.RemoteMcp,
      ] {
      let callbacks = Ref(0)
      let operation = @capability.TypedCapability::new(
        mutation_ok(mutation_descriptor("check", exposure, None, 1)),
        value => value.as_int(),
        value => Ok(@capability.IntValue(value)),
        value => {
          callbacks.val += 1
          Ok(value)
        },
        () => {
          callbacks.val += 1
          Ok(())
        },
        _origin => {
          callbacks.val += 1
          Ok(())
        },
      )
      let allowed = match origin {
        @capability.Gui | @capability.Direct => true
        @capability.LocalAutomation => !(exposure is @capability.Internal)
        @capability.RemoteMcp => exposure is @capability.External
      }
      let result = operation.invoke(origin, 9)
      if allowed {
        assert_true(result is Ok(9))
        assert_eq(callbacks.val, 3)
      } else {
        match result {
          Err(error) =>
            assert_true(error.code() is @diagnostics.PermissionDenied)
          Ok(_) => fail("exposure policy was bypassed")
        }
        assert_eq(callbacks.val, 0)
      }
    }
  }
}

///|
test "erased input schema rejection runs before a permissive decoder and handler" {
  let decodes = Ref(0)
  let executions = Ref(0)
  let operation = @capability.TypedCapability::new(
    mutation_ok(
      mutation_descriptor("strict.input", @capability.External, None, 1),
    ),
    _value => {
      decodes.val += 1
      Ok(1)
    },
    value => Ok(@capability.IntValue(value)),
    value => {
      executions.val += 1
      Ok(value)
    },
    () => Ok(()),
    _origin => Ok(()),
  )
  let registry = @capability.Registry::new()
  assert_true(registry.register(operation) is Ok(_))
  mutation_invalid(
    registry.invoke_external(
      "strict_input",
      @capability.RemoteMcp,
      @capability.StringValue("wrong"),
    ),
  )
  assert_eq(decodes.val, 0)
  assert_eq(executions.val, 0)
  assert_true(
    registry.invoke_external(
      "strict_input",
      @capability.RemoteMcp,
      @capability.IntValue(7),
    )
    is Ok(@capability.IntValue(1)),
  )
  assert_eq(decodes.val, 1)
  assert_eq(executions.val, 1)
}

///|
test "external dispatch and authorization require both exposure and exact alias" {
  let registry = @capability.Registry::new()
  let authorized : Array[String] = []
  let executed : Array[String] = []
  for
    (id, exposure, external_name, output) in [
      ("private", @capability.Internal, "private_name", 1),
      ("alpha", @capability.External, "alpha_name", 2),
      ("beta", @capability.External, "beta_name", 3),
      ("local", @capability.Local, "local_name", 4),
    ] {
    let operation = @capability.TypedCapability::new(
      mutation_ok(mutation_descriptor(id, exposure, Some(external_name), 1)),
      value => value.as_int(),
      value => Ok(@capability.IntValue(value)),
      _value => {
        executed.push(id)
        Ok(output)
      },
      () => Ok(()),
      _origin => {
        authorized.push(id)
        Ok(())
      },
    )
    assert_true(registry.register(operation) is Ok(_))
  }
  // Direct origin can execute internal capabilities through semantic IDs, but
  // the external lookup still must not expose their private aliases.
  for name in ["missing", "private_name", "local_name", "beta"] {
    match
      registry.invoke_external(
        name,
        @capability.Direct,
        @capability.IntValue(0),
      ) {
      Err(error) =>
        assert_true(error.code() is @diagnostics.UnsupportedCapability)
      Ok(_) => fail("external lookup exposed an unknown or private alias")
    }
    match registry.authorize_external(name, @capability.Direct) {
      Err(error) =>
        assert_true(error.code() is @diagnostics.UnsupportedCapability)
      Ok(_) => fail("authorization accepted an unknown or private alias")
    }
  }
  assert_eq(authorized.length(), 0)
  assert_eq(executed.length(), 0)
  assert_true(
    registry.authorize_external("beta_name", @capability.RemoteMcp) is Ok(_),
  )
  assert_eq(authorized, ["beta"])
  assert_eq(executed.length(), 0)
  assert_true(
    registry.invoke_external(
      "beta_name",
      @capability.RemoteMcp,
      @capability.IntValue(0),
    )
    is Ok(@capability.IntValue(3)),
  )
  assert_eq(authorized, ["beta", "beta"])
  assert_eq(executed, ["beta"])
}

///|
test "external manifest contains exact sorted entries and valid comma boundaries" {
  let registry = @capability.Registry::new()
  assert_eq(
    registry.external_manifest_json(),
    "{\"schema_version\":1,\"capabilities\":[]}",
  )
  for
    (id, exposure) in [
      ("z", @capability.External),
      ("hidden", @capability.Internal),
      ("a", @capability.External),
    ] {
    assert_true(
      registry.register(
        mutation_identity(
          mutation_ok(mutation_descriptor(id, exposure, None, 2)),
        ),
      )
      is Ok(_),
    )
  }
  let expected_entry = fn(id : String) {
    "{\"id\":\"\{id}\",\"external_name\":\"\{id}\",\"title\":\"Title\",\"description\":\"Description\",\"kind\":\"workflow\",\"input_schema\":{\"type\":\"integer\",\"minimum\":-2147483648,\"maximum\":2147483647},\"output_schema\":{\"type\":\"integer\",\"minimum\":-2147483648,\"maximum\":2147483647},\"effect\":\"external_side_effect\",\"idempotent\":false,\"exposure\":\"external\",\"version\":2}"
  }
  assert_eq(
    registry.external_manifest_json(),
    "{\"schema_version\":1,\"capabilities\":[\{expected_entry("a")},\{expected_entry("z")}]}",
  )
}
