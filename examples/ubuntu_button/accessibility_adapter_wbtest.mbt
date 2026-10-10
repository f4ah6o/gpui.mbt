///|
fn ubuntu_button_accessibility_token(
  snapshot : UbuntuButtonAccessibilitySnapshot,
) -> UbuntuButtonAdapterToken {
  for node in snapshot.nodes() {
    if node.role() == @accessibility.Button {
      return node.token()
    }
  }
  abort("Ubuntu button projection omitted its button")
}

///|
test "Ubuntu Button test target links the private Linux raster ABI" {
  if @env.get_env_var("GPUI_UBUNTU_E2E") == Some("1") {
    assert_true(@linux_text.require_grayscale_raster() is Ok(_))
  }
}

///|
test "Ubuntu button adapter checks its live Host owner thread" {
  if @env.get_env_var("GPUI_UBUNTU_E2E") == Some("1") {
    let host = @native.Host::start().unwrap()
    assert_true(host.assert_owner_thread() is Ok(_))
    ignore(host.stop())
  }
}

///|
test "Ubuntu button adapter resolves live Invoke and retains the new demo" {
  if @env.get_env_var("GPUI_UBUNTU_E2E") == Some("1") {
    let host = @native.Host::start().unwrap()
    let original = @fixture.ButtonDemo::new(640.0, 240.0).unwrap()
    let session = UbuntuButtonAccessibilitySession::new(host, original).unwrap()
    let first_snapshot = session.snapshot().unwrap()
    let button = ubuntu_button_accessibility_token(first_snapshot)
    let mut button_count = 0
    for node in first_snapshot.nodes() {
      if node.role() == @accessibility.Button {
        button_count += 1
      }
    }
    assert_eq(button_count, 1)

    let loading_demo = session
      .current_demo()
      .unwrap()
      .with_loading(true)
      .unwrap()
    let loading_snapshot = session.publish(loading_demo).unwrap()
    assert_true(ubuntu_button_accessibility_token(loading_snapshot) == button)
    assert_true(
      session.invoke(button)
      is Err(ProjectionError(@native.ActionRejected(@accessibility.Loading))),
    )
    let ready_demo = session
      .current_demo()
      .unwrap()
      .with_loading(false)
      .unwrap()
    let ready_snapshot = session.publish(ready_demo).unwrap()
    assert_true(ubuntu_button_accessibility_token(ready_snapshot) == button)
    let preinvoke_demo = session.current_demo().unwrap()

    let after_first_invoke = session.invoke(button).unwrap()
    assert_eq(after_first_invoke.revision(), ready_snapshot.revision())
    assert_eq(session.current_demo().unwrap().activations(), 1)
    assert_true(
      session.publish(preinvoke_demo)
      is Err(FixtureError(@fixture.StaleFixtureState)),
    )
    assert_true(
      preinvoke_demo.with_loading(true) is Err(@fixture.StaleFixtureState),
    )

    // ActionIntent is a repeatable validation receipt; the adapter keeps the
    // same continuous node token and the latest returned demo accepts another.
    let after_second_invoke = session.invoke(button).unwrap()
    assert_eq(after_second_invoke.nodes().length(), 2)
    assert_eq(session.current_demo().unwrap().activations(), 2)

    let fresh_demo = session.current_demo().unwrap()
    let hidden_demo = fresh_demo.resize(100.0, 64.0).unwrap()
    let hidden = session.publish(hidden_demo).unwrap()
    assert_eq(hidden.nodes().length(), 1)
    assert_true(session.invoke(button) is Err(StaleAdapterToken))

    let restored = hidden_demo.resize(640.0, 240.0).unwrap()
    let reappeared = session.publish(restored).unwrap()
    let new_button = ubuntu_button_accessibility_token(reappeared)
    assert_true(new_button != button)
    assert_eq(session.current_demo().unwrap().activations(), 2)

    assert_true(session.close() is Ok(_))
    assert_true(session.invoke(new_button) is Err(SessionClosed))
    assert_true(host.stop() is Ok(_))
  }
}

///|
test "Ubuntu button adapter fails closed instead of reusing exhausted tokens" {
  if @env.get_env_var("GPUI_UBUNTU_E2E") == Some("1") {
    let host = @native.Host::start().unwrap()
    let demo = @fixture.ButtonDemo::new(640.0, 240.0).unwrap()
    let session = UbuntuButtonAccessibilitySession::new(host, demo).unwrap()
    let first = ubuntu_button_accessibility_token(session.snapshot().unwrap())
    let hidden = session.current_demo().unwrap().resize(100.0, 64.0).unwrap()
    let _ = session.publish(hidden).unwrap()

    let state = session.state.val
    session.state.val = {
      ..state,
      next_sequence: BUTTON_ADAPTER_MAX_SEQUENCE,
      sequence_exhausted: false,
    }
    let restored = hidden.resize(640.0, 240.0).unwrap()
    let last_available = session.publish(restored).unwrap()
    let final_token = ubuntu_button_accessibility_token(last_available)
    assert_true(final_token != first)

    let hidden_again = session
      .current_demo()
      .unwrap()
      .resize(100.0, 64.0)
      .unwrap()
    let _ = session.publish(hidden_again).unwrap()
    let restored_again = session
      .current_demo()
      .unwrap()
      .resize(640.0, 240.0)
      .unwrap()
    let (source_model, source_snapshot) = restored_again
      .accessibility_source()
      .unwrap()
    let source_button = source_snapshot.nodes()[1]
    let retained_request = @accessibility.ActionRequest::new(
      source_button.id(),
      @accessibility.Invoke,
    )
    assert_true(session.publish(restored_again) is Err(AdapterTokenExhausted))
    assert_true(session.snapshot() is Err(SessionClosed))
    assert_true(
      source_model.resolve_action(retained_request)
      is Err(@accessibility.ModelClosed),
    )
    assert_true(session.close() is Ok(_))
    assert_true(host.stop() is Ok(_))
  }
}

///|
test "Ubuntu button adapter rejects a token from another session" {
  if @env.get_env_var("GPUI_UBUNTU_E2E") == Some("1") {
    let host = @native.Host::start().unwrap()
    let first = UbuntuButtonAccessibilitySession::new(
      host,
      @fixture.ButtonDemo::new(640.0, 240.0).unwrap(),
    ).unwrap()
    let second = UbuntuButtonAccessibilitySession::new(
      host,
      @fixture.ButtonDemo::new(640.0, 240.0).unwrap(),
    ).unwrap()
    let foreign_demo = second.current_demo().unwrap()
    assert_true(
      first.publish(foreign_demo) is Err(ProjectionError(@native.ForeignOwner)),
    )
    assert_true(foreign_demo.with_loading(true) is Ok(_))
    let foreign = ubuntu_button_accessibility_token(first.snapshot().unwrap())
    assert_true(second.invoke(foreign) is Err(StaleAdapterToken))
    assert_true(first.close() is Ok(_))
    assert_true(second.close() is Ok(_))
    assert_true(host.stop() is Ok(_))
  }
}

///|
test "Ubuntu button adapter revokes a same-owner source after projection failure" {
  if @env.get_env_var("GPUI_UBUNTU_E2E") == Some("1") {
    let host = @native.Host::start().unwrap()
    let demo = @fixture.ButtonDemo::new(640.0, 240.0).unwrap()
    let session = UbuntuButtonAccessibilitySession::new(host, demo).unwrap()
    let current = session.current_demo().unwrap()
    let (source_model, source_snapshot) = current
      .accessibility_source()
      .unwrap()
    let retained_request = @accessibility.ActionRequest::new(
      source_snapshot.nodes()[1].id(),
      @accessibility.Invoke,
    )
    let latest = current.with_loading(true).unwrap()
    session.projection.close()
    assert_true(
      session.publish(latest) is Err(ProjectionError(@native.ProjectionClosed)),
    )
    assert_true(session.current_demo() is Err(SessionClosed))
    assert_true(
      source_model.resolve_action(retained_request)
      is Err(@accessibility.ModelClosed),
    )
    assert_true(host.stop() is Ok(_))
  }
}
