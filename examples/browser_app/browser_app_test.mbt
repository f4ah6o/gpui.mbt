///|
fn browser_test_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid browser demo point rejected")
  }
}

///|
fn create_browser_demo() -> @browser_app.BrowserDemo {
  match @browser_app.BrowserDemo::new() {
    Ok(demo) => demo
    Err(_) => abort("portable browser demo app failed to start")
  }
}

///|
fn enqueue_browser_inputs(
  demo : @browser_app.BrowserDemo,
  inputs : Array[@primitives.InputEvent],
) -> Unit {
  for input in inputs {
    match
      @browser_app.BrowserDemo::enqueue_event(demo, @platform.Input(input)) {
      Ok(_) => ()
      Err(_) => abort("portable browser demo input was rejected")
    }
  }
}

///|
fn browser_status_after_frame(demo : @browser_app.BrowserDemo) -> String {
  match @browser_app.BrowserDemo::render_frame(demo) {
    Ok(_) => @browser_app.BrowserDemo::status_json(demo)
    Err(_) => abort("portable browser demo frame failed to render")
  }
}

///|
fn counter_indicator_width(snapshot : @scene.SceneSnapshot) -> Double {
  let mut width = 0.0
  for item in snapshot.items() {
    if item.id() == 92 {
      match item {
        @scene.QuadItem(bounds~, ..) => width = bounds.size().width()
        @scene.TextItem(..) | @scene.TextRunItem(..) =>
          abort("counter indicator must remain a quad")
      }
    }
  }
  width
}

///|
test "portable browser app preserves logical dimensions across DPR changes" {
  let demo = create_browser_demo()
  assert_true(
    @browser_app.BrowserDemo::set_viewport(demo, 820.0, 492.0, 2.0) is Ok(_),
  )
  assert_true(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.PointerMoved(position=browser_test_point(120.0, 238.0)),
      ),
    )
    is Ok(_),
  )

  let snapshot = match @browser_app.BrowserDemo::render_frame(demo) {
    Ok(value) => value
    Err(_) => abort("portable demo scene failed to render")
  }
  assert_true(snapshot.viewport().size().width() == 820.0)
  assert_true(snapshot.viewport().size().height() == 492.0)
  assert_true(snapshot.scale() == 2.0)
  let items = snapshot.items()
  assert_true(items.length() >= 10)
  assert_true(items[0].clip_chain_id() == Some(0))
  let clips = snapshot.clip_chains()
  assert_true(clips.length() == 1)
  assert_true(clips[0].rects()[0].size().width() == 820.0)
  assert_true(clips[0].rects()[0].size().height() == 492.0)
  let mut transformed_quad_is_clipped = false
  for item in items {
    match item {
      @scene.TextItem(..) | @scene.TextRunItem(..) =>
        fail("legacy fixture must remain quad-only")
      @scene.QuadItem(id~, transform~, clip_chain_id~, ..) =>
        if id == 4 {
          assert_true(clip_chain_id == Some(0))
          assert_true(transform.tx() == 2.0 && transform.ty() == -2.0)
          transformed_quad_is_clipped = true
        }
    }
  }
  assert_true(transformed_quad_is_clipped)
  assert_true(items[8].id() == 90)
  match items[8] {
    @scene.QuadItem(transform~, ..) => assert_true(transform.tx() == 114.0)
    @scene.TextItem(..) | @scene.TextRunItem(..) =>
      fail("pointer marker must remain a quad")
  }

  let status = @browser_app.BrowserDemo::status_json(demo)
  assert_true(status.contains("\"logicalWidth\":820"))
  assert_true(status.contains("\"logicalHeight\":492"))
  assert_true(status.contains("\"dpr\":2"))
  assert_true(status.contains("\"hover\":4"))
  assert_true(status.contains("\"cursor\":\"pointing-hand\""))
  assert_true(status.contains("\"events\":4"))
  assert_true(status.contains("\"lastSequence\":5"))
  assert_true(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.PointerMoved(position=browser_test_point(20.0, 20.0)),
      ),
    )
    is Ok(_),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains("\"cursor\":\"arrow\""),
  )
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "browser resize refreshes cursor without another pointer move" {
  let demo = create_browser_demo()
  assert_true(
    @browser_app.BrowserDemo::set_viewport(demo, 820.0, 492.0, 1.0) is Ok(_),
  )
  assert_true(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.PointerMoved(position=browser_test_point(120.0, 238.0)),
      ),
    )
    is Ok(_),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  let hovered = @browser_app.BrowserDemo::status_json(demo)
  assert_true(hovered.contains("\"hover\":4"))
  assert_true(hovered.contains("\"cursor\":\"pointing-hand\""))

  assert_true(
    @browser_app.BrowserDemo::set_viewport(demo, 820.0, 180.0, 1.0) is Ok(_),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  let resized = @browser_app.BrowserDemo::status_json(demo)
  assert_true(resized.contains("\"logicalHeight\":180"))
  assert_true(resized.contains("\"hover\":null"))
  assert_true(resized.contains("\"cursor\":\"arrow\""))
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "browser GUI direct and MCP adapter calls share one observed capability" {
  let demo = create_browser_demo()
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains(
      "\"capabilityValue\":0",
    ),
  )

  assert_true(@browser_app.BrowserDemo::invoke_counter_direct(demo, 3) is Ok(3))
  assert_true(@browser_app.BrowserDemo::query_counter(demo) is Ok(3))
  let direct_frame = match @browser_app.BrowserDemo::render_frame(demo) {
    Ok(value) => value
    Err(_) => abort("direct counter update failed to build a scene")
  }
  assert_true(counter_indicator_width(direct_frame) == 20.0)
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains(
      "\"capabilityValue\":3",
    ),
  )

  assert_true(@browser_app.BrowserDemo::invoke_counter_mcp(demo, 2) is Ok(5))
  assert_true(@browser_app.BrowserDemo::query_counter(demo) is Ok(5))
  let mcp_frame = match @browser_app.BrowserDemo::render_frame(demo) {
    Ok(value) => value
    Err(_) => abort("MCP counter update failed to build a scene")
  }
  assert_true(counter_indicator_width(mcp_frame) == 28.0)
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains(
      "\"capabilityValue\":5",
    ),
  )

  ignore(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.PointerButtonPressed(
          position=browser_test_point(120.0, 238.0),
          button=@primitives.Primary,
          modifiers=@primitives.Modifiers::none(),
        ),
      ),
    ),
  )
  let frame = match @browser_app.BrowserDemo::render_frame(demo) {
    Ok(value) => value
    Err(_) => abort("semantic capability GUI action failed to render")
  }
  assert_true(@browser_app.BrowserDemo::query_counter(demo) is Ok(6))
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains(
      "\"capabilityValue\":6",
    ),
  )
  assert_true(counter_indicator_width(frame) == 32.0)
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "browser host layout exposes semantics and a measured legacy island" {
  let demo = create_browser_demo()
  let layout = @browser_app.BrowserDemo::host_layout_json(demo)
  assert_true(layout.contains("\"role\":\"button\""))
  assert_true(layout.contains("Alpine cyan action"))
  assert_true(layout.contains("\"kind\":\"legacy-island\""))
  assert_true(layout.contains("\"id\":8"))

  assert_true(
    @browser_app.BrowserDemo::focus_semantic_node(demo, 7, false) is Ok(_),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains("\"focus\":7"),
  )
  assert_true(
    @browser_app.BrowserDemo::focus_semantic_node(demo, 4, true) is Ok(_),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains("\"focus\":4"),
  )
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "portable keyboard model honors reverse tab and focused activation" {
  let demo = create_browser_demo()
  let shift = @primitives.Modifiers::new(
    shift=true,
    control=false,
    alt=false,
    meta=false,
  )
  let none = @primitives.Modifiers::none()
  ignore(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.KeyPressed(
          key=@primitives.Tab,
          modifiers=shift,
          repeat=false,
        ),
      ),
    ),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains("\"focus\":7"),
  )

  ignore(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.KeyPressed(
          key=@primitives.Tab,
          modifiers=none,
          repeat=false,
        ),
      ),
    ),
  )
  ignore(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.KeyPressed(
          key=@primitives.Enter,
          modifiers=none,
          repeat=false,
        ),
      ),
    ),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  let status = @browser_app.BrowserDemo::status_json(demo)
  assert_true(status.contains("\"focus\":4"))
  assert_true(status.contains("\"clicks\":1"))
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "status strings remain valid JSON for punctuation and line breaks" {
  assert_eq(
    @browser_app.json_quote("quote: \" slash: \\ line:\n"),
    "\"quote: \\\" slash: \\\\ line:\\n\"",
  )

  let demo = create_browser_demo()
  let modifiers = @primitives.Modifiers::none()
  ignore(
    @browser_app.BrowserDemo::enqueue_event(
      demo,
      @platform.Input(
        @primitives.KeyPressed(
          key=@primitives.Character("\"\\"),
          modifiers~,
          repeat=false,
        ),
      ),
    ),
  )
  ignore(@browser_app.BrowserDemo::render_frame(demo))
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains(
      "\"lastKey\":\"Character\"",
    ),
  )
  let encoded_key = @browser_app.json_quote("\"\\")
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains(
      "\"pressedKeys\":[\{encoded_key}]",
    ),
  )
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "demo teardown is idempotent and rejects later size changes" {
  let demo = create_browser_demo()
  @browser_app.BrowserDemo::dispose(demo)
  @browser_app.BrowserDemo::dispose(demo)
  assert_true(@browser_app.BrowserDemo::is_stopped(demo))
  assert_true(
    @browser_app.BrowserDemo::set_viewport(demo, 800.0, 480.0, 1.0)
    is Err(@browser_app.Stopped),
  )
  assert_true(
    @browser_app.BrowserDemo::render_frame(demo) is Err(@browser_app.Stopped),
  )
}

///|
test "committed inserts remain queued until the portable model drains input" {
  let demo = create_browser_demo()
  let initial = @browser_app.BrowserDemo::status_json(demo)
  assert_true(initial.contains("\"textCommitCount\":0"))
  assert_true(initial.contains("\"lastCommittedText\":\"\""))
  assert_true(
    @browser_app.BrowserDemo::enqueue_text_input(demo, "Latin") is Ok(_),
  )
  let text = "日本語 👩🏽‍💻 e\u0301 שלום العربية \" \\ \n\r\t\u0000\u0008\u000c\u001f"
  assert_true(@browser_app.BrowserDemo::enqueue_text_input(demo, text) is Ok(_))
  assert_eq(@browser_app.BrowserDemo::status_json(demo), initial)
  assert_true(@browser_app.BrowserDemo::render_frame(demo) is Ok(_))
  let status = @browser_app.BrowserDemo::status_json(demo)
  assert_true(status.contains("\"textCommitCount\":2"))
  assert_true(
    status.contains("\"lastCommittedText\":\{@browser_app.json_quote(text)}"),
  )
  assert_true(status.contains("\"lastEvent\":\"text input\""))
  assert_true(status.contains("\"lastKey\":\"—\""))
  assert_true(status.contains("\"clicks\":0"))
  assert_true(status.contains("\\u0000\\u0008\\u000c\\u001f"))
  assert_true(@browser_app.BrowserDemo::render_frame(demo) is Ok(_))
  assert_eq(@browser_app.BrowserDemo::status_json(demo), status)
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "committed insert bounds count UTF-16 units without truncation" {
  let demo = create_browser_demo()
  assert_eq("😀".length(), 2)
  let boundary = "😀".repeat(32_768)
  assert_eq(boundary.length(), 65_536)
  assert_true(
    @browser_app.BrowserDemo::enqueue_text_input(demo, "")
    is Err(@browser_app.InvalidTextInput),
  )
  assert_true(
    @browser_app.BrowserDemo::enqueue_text_input(demo, boundary + "x")
    is Err(@browser_app.InvalidTextInput),
  )
  assert_true(
    @browser_app.BrowserDemo::enqueue_text_input(demo, boundary) is Ok(_),
  )
  assert_true(@browser_app.BrowserDemo::render_frame(demo) is Ok(_))
  let status = @browser_app.BrowserDemo::status_json(demo)
  assert_true(status.contains("\"textCommitCount\":1"))
  assert_true(
    status.contains(
      "\"lastCommittedText\":\{@browser_app.json_quote(boundary)}",
    ),
  )
  @browser_app.BrowserDemo::dispose(demo)
  assert_true(
    @browser_app.BrowserDemo::enqueue_text_input(demo, "late")
    is Err(@browser_app.Stopped),
  )
}

///|
test "queued input downs and compensating releases drain without held state" {
  let demo = create_browser_demo()
  let initial = @browser_app.BrowserDemo::status_json(demo)
  let modifiers = @primitives.Modifiers::none()
  enqueue_browser_inputs(demo, [
    @primitives.PointerButtonPressed(
      position=browser_test_point(120.0, 238.0),
      button=@primitives.Primary,
      modifiers~,
    ),
    @primitives.PointerButtonPressed(
      position=browser_test_point(-20.0, -20.0),
      button=@primitives.Secondary,
      modifiers~,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("K"),
      modifiers~,
      repeat=false,
    ),
    @primitives.PointerButtonReleased(
      position=browser_test_point(20.0, 20.0),
      button=@primitives.Primary,
      modifiers~,
    ),
    @primitives.PointerButtonReleased(
      position=browser_test_point(20.0, 20.0),
      button=@primitives.Secondary,
      modifiers~,
    ),
    @primitives.KeyReleased(key=@primitives.Character("K"), modifiers~),
  ])
  assert_eq(@browser_app.BrowserDemo::status_json(demo), initial)
  let status = browser_status_after_frame(demo)
  assert_true(
    status.contains(
      "\"inputState\":{\"pressedButtons\":[],\"pressedKeys\":[],\"pointerDowns\":2,\"pointerUps\":2,\"keyDowns\":1,\"keyUps\":1,\"keyRepeats\":0,\"unmatchedPointerUps\":0,\"unmatchedKeyUps\":0,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  assert_true(status.contains("\"clicks\":1"))
  assert_true(@browser_app.BrowserDemo::query_counter(demo) is Ok(1))
  assert_eq(browser_status_after_frame(demo), status)
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "drained input holds remain observable until typed releases are drained" {
  let demo = create_browser_demo()
  let modifiers = @primitives.Modifiers::none()
  let position = browser_test_point(-20.0, -20.0)
  let buttons = [
    @primitives.Primary,
    @primitives.Middle,
    @primitives.Secondary,
    @primitives.Back,
    @primitives.Forward,
  ]
  for button in buttons {
    enqueue_browser_inputs(demo, [
      @primitives.PointerButtonPressed(position~, button~, modifiers~),
    ])
  }
  enqueue_browser_inputs(demo, [
    @primitives.KeyPressed(
      key=@primitives.Character("q"),
      modifiers~,
      repeat=false,
    ),
    @primitives.KeyPressed(key=@primitives.Space, modifiers~, repeat=false),
  ])
  let held = browser_status_after_frame(demo)
  assert_true(
    held.contains(
      "\"inputState\":{\"pressedButtons\":[0,1,2,3,4],\"pressedKeys\":[\"q\",\" \"],\"pointerDowns\":5,\"pointerUps\":0,\"keyDowns\":2,\"keyUps\":0,\"keyRepeats\":0,\"unmatchedPointerUps\":0,\"unmatchedKeyUps\":0,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  for button in buttons {
    enqueue_browser_inputs(demo, [
      @primitives.PointerButtonReleased(position~, button~, modifiers~),
    ])
  }
  enqueue_browser_inputs(demo, [
    @primitives.KeyReleased(key=@primitives.Character("q"), modifiers~),
    @primitives.KeyReleased(key=@primitives.Space, modifiers~),
  ])
  assert_eq(@browser_app.BrowserDemo::status_json(demo), held)
  let released = browser_status_after_frame(demo)
  assert_true(
    released.contains(
      "\"inputState\":{\"pressedButtons\":[],\"pressedKeys\":[],\"pointerDowns\":5,\"pointerUps\":5,\"keyDowns\":2,\"keyUps\":2,\"keyRepeats\":0,\"unmatchedPointerUps\":0,\"unmatchedKeyUps\":0,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  assert_true(released.contains("\"clicks\":0"))
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "input aliases require distinct releases while repeats add no holds" {
  let demo = create_browser_demo()
  let modifiers = @primitives.Modifiers::none()
  let shift = @primitives.Modifiers::new(
    shift=true,
    control=false,
    alt=false,
    meta=false,
  )
  let position = browser_test_point(-20.0, -20.0)
  enqueue_browser_inputs(demo, [
    @primitives.PointerButtonPressed(
      position~,
      button=@primitives.Primary,
      modifiers~,
    ),
    @primitives.PointerButtonPressed(
      position~,
      button=@primitives.Primary,
      modifiers~,
    ),
    @primitives.PointerButtonReleased(
      position~,
      button=@primitives.Primary,
      modifiers~,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("Shift"),
      modifiers=shift,
      repeat=false,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("Shift"),
      modifiers=shift,
      repeat=false,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("K"),
      modifiers=shift,
      repeat=false,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("K"),
      modifiers=shift,
      repeat=true,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("K"),
      modifiers=shift,
      repeat=true,
    ),
    @primitives.KeyPressed(
      key=@primitives.Character("unheld"),
      modifiers~,
      repeat=true,
    ),
  ])
  let held = browser_status_after_frame(demo)
  assert_true(
    held.contains(
      "\"inputState\":{\"pressedButtons\":[0],\"pressedKeys\":[\"Shift\",\"Shift\",\"K\"],\"pointerDowns\":2,\"pointerUps\":1,\"keyDowns\":3,\"keyUps\":0,\"keyRepeats\":3,\"unmatchedPointerUps\":0,\"unmatchedKeyUps\":0,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  enqueue_browser_inputs(demo, [
    @primitives.KeyReleased(key=@primitives.Character("Shift"), modifiers=shift),
    @primitives.KeyReleased(key=@primitives.Character("k"), modifiers~),
    @primitives.PointerButtonReleased(
      position~,
      button=@primitives.Secondary,
      modifiers~,
    ),
  ])
  let partly_released = browser_status_after_frame(demo)
  assert_true(
    partly_released.contains(
      "\"inputState\":{\"pressedButtons\":[0],\"pressedKeys\":[\"Shift\",\"K\"],\"pointerDowns\":2,\"pointerUps\":2,\"keyDowns\":3,\"keyUps\":2,\"keyRepeats\":3,\"unmatchedPointerUps\":1,\"unmatchedKeyUps\":1,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  enqueue_browser_inputs(demo, [
    @primitives.KeyReleased(key=@primitives.Character("Shift"), modifiers~),
    @primitives.KeyReleased(key=@primitives.Character("K"), modifiers~),
    @primitives.PointerButtonReleased(
      position~,
      button=@primitives.Primary,
      modifiers~,
    ),
  ])
  let released = browser_status_after_frame(demo)
  assert_true(
    released.contains(
      "\"inputState\":{\"pressedButtons\":[],\"pressedKeys\":[],\"pointerDowns\":2,\"pointerUps\":3,\"keyDowns\":3,\"keyUps\":4,\"keyRepeats\":3,\"unmatchedPointerUps\":1,\"unmatchedKeyUps\":1,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "semantic focus and activation queue balanced keyboard taps" {
  let demo = create_browser_demo()
  let initial = @browser_app.BrowserDemo::status_json(demo)
  assert_true(
    @browser_app.BrowserDemo::focus_semantic_node(demo, 7, false) is Ok(_),
  )
  assert_true(
    @browser_app.BrowserDemo::focus_semantic_node(demo, 4, true) is Ok(_),
  )
  assert_true(
    @browser_app.BrowserDemo::activate_semantic_node(demo, 4) is Ok(_),
  )
  assert_true(
    @browser_app.BrowserDemo::activate_semantic_node(demo, 6) is Ok(_),
  )
  assert_eq(@browser_app.BrowserDemo::status_json(demo), initial)
  let status = browser_status_after_frame(demo)
  assert_true(
    status.contains(
      "\"inputState\":{\"pressedButtons\":[],\"pressedKeys\":[],\"pointerDowns\":0,\"pointerUps\":0,\"keyDowns\":11,\"keyUps\":11,\"keyRepeats\":0,\"unmatchedPointerUps\":0,\"unmatchedKeyUps\":0,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  assert_true(status.contains("\"focus\":6"))
  assert_true(status.contains("\"clicks\":2"))
  assert_true(status.contains("\"lastKey\":\"Enter\""))
  assert_true(status.contains("\"lastEvent\":\"key up\""))
  assert_true(@browser_app.BrowserDemo::query_counter(demo) is Ok(1))
  assert_true(
    @browser_app.BrowserDemo::focus_semantic_node(demo, 6, false) is Ok(_),
  )
  assert_eq(browser_status_after_frame(demo), status)
  assert_true(
    @browser_app.BrowserDemo::activate_semantic_node(demo, 6) is Ok(_),
  )
  let activated_again = browser_status_after_frame(demo)
  assert_true(
    activated_again.contains(
      "\"inputState\":{\"pressedButtons\":[],\"pressedKeys\":[],\"pointerDowns\":0,\"pointerUps\":0,\"keyDowns\":12,\"keyUps\":12,\"keyRepeats\":0,\"unmatchedPointerUps\":0,\"unmatchedKeyUps\":0,\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}}",
    ),
  )
  assert_true(activated_again.contains("\"clicks\":3"))
  assert_true(@browser_app.BrowserDemo::query_counter(demo) is Ok(1))
  @browser_app.BrowserDemo::dispose(demo)
}

///|
test "typed neutral releases clear the latest pointer and key modifiers" {
  let demo = create_browser_demo()
  let modified = @primitives.Modifiers::new(
    shift=true,
    control=true,
    alt=true,
    meta=true,
  )
  let neutral = @primitives.Modifiers::none()
  let position = browser_test_point(-20.0, -20.0)
  let all_pressed = "\"lastModifiers\":{\"shift\":true,\"control\":true,\"alt\":true,\"meta\":true}"
  let all_released = "\"lastModifiers\":{\"shift\":false,\"control\":false,\"alt\":false,\"meta\":false}"
  assert_true(
    @browser_app.BrowserDemo::status_json(demo).contains(all_released),
  )
  enqueue_browser_inputs(demo, [
    @primitives.PointerButtonPressed(
      position~,
      button=@primitives.Primary,
      modifiers=modified,
    ),
  ])
  let pointer_held = browser_status_after_frame(demo)
  assert_true(pointer_held.contains("\"pressedButtons\":[0]"))
  assert_true(pointer_held.contains(all_pressed))
  enqueue_browser_inputs(demo, [
    @primitives.PointerButtonReleased(
      position~,
      button=@primitives.Primary,
      modifiers=neutral,
    ),
  ])
  assert_eq(@browser_app.BrowserDemo::status_json(demo), pointer_held)
  let pointer_released = browser_status_after_frame(demo)
  assert_true(pointer_released.contains("\"pressedButtons\":[]"))
  assert_true(pointer_released.contains(all_released))
  enqueue_browser_inputs(demo, [
    @primitives.KeyPressed(
      key=@primitives.Character("A"),
      modifiers=modified,
      repeat=false,
    ),
  ])
  let key_held = browser_status_after_frame(demo)
  assert_true(key_held.contains("\"pressedKeys\":[\"A\"]"))
  assert_true(key_held.contains(all_pressed))
  enqueue_browser_inputs(demo, [
    @primitives.KeyReleased(key=@primitives.Character("A"), modifiers=neutral),
  ])
  assert_eq(@browser_app.BrowserDemo::status_json(demo), key_held)
  let key_released = browser_status_after_frame(demo)
  assert_true(key_released.contains("\"pressedKeys\":[]"))
  assert_true(key_released.contains(all_released))
  assert_true(key_released.contains("\"pointerDowns\":1,\"pointerUps\":1"))
  assert_true(key_released.contains("\"keyDowns\":1,\"keyUps\":1"))
  assert_true(
    key_released.contains("\"unmatchedPointerUps\":0,\"unmatchedKeyUps\":0"),
  )
  @browser_app.BrowserDemo::dispose(demo)
}
