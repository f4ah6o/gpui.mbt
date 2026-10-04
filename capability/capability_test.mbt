///|
fn running_capability_app() -> @core.App raise {
  let app = match @core.App::new() {
    Ok(value) => value
    Err(_) => fail("app allocation should succeed")
  }
  match app.start() {
    Ok(_) => app
    Err(_) => fail("app should start")
  }
}

///|
fn external_int_descriptor(
  id : String,
  kind : @capability.OperationKind,
) -> @capability.Descriptor raise {
  match
    @capability.Descriptor::new(
      id,
      id,
      "test capability",
      kind,
      @capability.Schema::int(),
      @capability.Schema::int(),
      if kind is @capability.Query {
        @capability.ReadOnly
      } else {
        @capability.StateChange
      },
      true,
      @capability.External,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("valid descriptor rejected")
  }
}

///|
fn int_capability(
  app : @core.App,
  entity : @core.Entity[Int],
  id : String,
  kind : @capability.OperationKind,
) -> @capability.TypedCapability[Int, Int] {
  @capability.TypedCapability::new(
    external_int_descriptor(id, kind),
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => {
      if kind is @capability.Query {
        app.read(entity, current => current)
      } else {
        match
          app.update(entity, context => {
            match context.set(value) {
              Err(error) => Err(error)
              Ok(_) => context.notify()
            }
          }) {
          Err(error) => Err(error)
          Ok(_) => app.read(entity, current => current)
        }
      }
    },
    () => {
      if entity.is_live() {
        Ok(())
      } else {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.EntityNotLive,
            id,
            entity_id=entity.id().value(),
            subsystem="capability-test",
          ),
        )
      }
    },
    _origin => Ok(()),
  )
}

///|
test "schema projection is deterministic and validates closed records" {
  let string_field = match
    @capability.SchemaField::new("name", @capability.Schema::string(), true) {
    Ok(value) => value
    Err(_) => fail("valid field rejected")
  }
  let enabled_field = match
    @capability.SchemaField::new("enabled", @capability.Schema::bool(), false) {
    Ok(value) => value
    Err(_) => fail("valid field rejected")
  }
  let first = match @capability.Schema::record([string_field, enabled_field]) {
    Ok(value) => value
    Err(_) => fail("valid record schema rejected")
  }
  let second = match @capability.Schema::record([enabled_field, string_field]) {
    Ok(value) => value
    Err(_) => fail("valid record schema rejected")
  }
  assert_eq(first.canonical_json(), second.canonical_json())
  assert_true(
    first.accepts(
      @capability.Value::object([
        ("enabled", @capability.Value::bool(true)),
        ("name", @capability.Value::string("demo")),
      ]),
    ),
  )
  assert_true(
    !first.accepts(
      @capability.Value::object([
        ("name", @capability.Value::string("demo")),
        ("extra", @capability.Value::int(1)),
      ]),
    ),
  )
  assert_true(
    !first.accepts(
      @capability.Value::object([("enabled", @capability.Value::bool(true))]),
    ),
  )
}

///|
test "registry enumeration and manifest ignore registration order" {
  let app = running_capability_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let first = @capability.Registry::new()
  let second = @capability.Registry::new()
  let a = int_capability(app, entity, "document.rename", @capability.Command)
  let b = int_capability(app, entity, "document.current", @capability.Query)
  assert_true(first.register(a) is Ok(_))
  assert_true(first.register(b) is Ok(_))
  assert_true(second.register(b) is Ok(_))
  assert_true(second.register(a) is Ok(_))
  assert_eq(first.external_manifest_json(), second.external_manifest_json())
  let descriptors = first.descriptors()
  assert_true(descriptors.length() == 2)
  assert_eq(descriptors[0].id(), "document.current")
  assert_eq(descriptors[1].id(), "document.rename")
}

///|
test "gui direct and erased registry invocation share one handler" {
  let app = running_capability_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let owner = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("owner creation should succeed")
  }
  let notifications = Ref(0)
  assert_true(
    app.update(owner, context => {
      match
        context.subscribe(entity, event => {
          if event.kind() is @core.Changed {
            notifications.val += 1
          }
          Ok(())
        }) {
        Ok(_) => Ok(())
        Err(error) => Err(error)
      }
    })
    is Ok(_),
  )
  let command = int_capability(
    app,
    entity,
    "document.rename",
    @capability.Command,
  )
  let query = int_capability(app, entity, "document.current", @capability.Query)
  let gui = command.gui_binding()
  let registry = @capability.Registry::new()
  assert_true(registry.register(command) is Ok(_))
  assert_true(registry.register(query) is Ok(_))

  assert_true(gui.trigger(7) is Ok(7))
  assert_true(command.invoke(@capability.Direct, 8) is Ok(8))
  assert_true(
    registry.invoke(
      "document.rename",
      @capability.RemoteMcp,
      @capability.Value::int(9),
    )
    is Ok(@capability.IntValue(9)),
  )
  assert_true(app.run_ready(16) is Ok(3))
  assert_true(notifications.val == 3)
  assert_true(
    registry.invoke(
      "document.current",
      @capability.RemoteMcp,
      @capability.Value::int(0),
    )
    is Ok(@capability.IntValue(9)),
  )
  assert_true(app.read(entity, current => current) is Ok(9))
}

///|
test "registry rejects collisions invalid values policy and stale handles" {
  let app = running_capability_app()
  let entity = match app.create_entity(0) {
    Ok(value) => value
    Err(_) => fail("entity creation should succeed")
  }
  let registry = @capability.Registry::new()
  let command = int_capability(
    app,
    entity,
    "document.rename",
    @capability.Command,
  )
  assert_true(registry.register(command) is Ok(_))
  match registry.register(command) {
    Err(error) => assert_true(error.code() is @diagnostics.InvalidInput)
    Ok(_) => fail("duplicate capability id must fail")
  }
  match
    registry.invoke(
      "document.rename",
      @capability.RemoteMcp,
      @capability.Value::string("wrong"),
    ) {
    Err(error) => assert_true(error.code() is @diagnostics.ConversionFailed)
    Ok(_) => fail("invalid external value must fail")
  }

  let internal_descriptor = match
    @capability.Descriptor::new(
      "internal.reset",
      "Reset",
      "internal only",
      @capability.Command,
      @capability.Schema::int(),
      @capability.Schema::int(),
      @capability.StateChange,
      false,
      @capability.Internal,
      None,
      1,
    ) {
    Ok(value) => value
    Err(_) => fail("valid descriptor rejected")
  }
  let internal = @capability.TypedCapability::new(
    internal_descriptor,
    value => value.as_int(),
    value => Ok(@capability.Value::int(value)),
    value => Ok(value),
    () => Ok(()),
    _ => Ok(()),
  )
  assert_true(registry.register(internal) is Ok(_))
  match
    registry.invoke(
      "internal.reset",
      @capability.RemoteMcp,
      @capability.Value::int(1),
    ) {
    Err(error) => assert_true(error.code() is @diagnostics.PermissionDenied)
    Ok(_) => fail("remote invocation of internal capability must fail")
  }
  registry.teardown()
  match
    registry.invoke(
      "document.rename",
      @capability.Direct,
      @capability.Value::int(1),
    ) {
    Err(error) => assert_true(error.code() is @diagnostics.StaleHandle)
    Ok(_) => fail("torn down registry must reject invocation")
  }
}
