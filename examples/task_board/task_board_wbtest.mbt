///|
fn test_board() -> BoardDemo {
  match BoardDemo::new() {
    Ok(value) => value
    Err(_) => abort("board should start")
  }
}

///|
fn frame(board : BoardDemo) -> BoardModel {
  match board.render_frame() {
    Ok(_) => ()
    Err(_) => abort("board frame should render")
  }
  match board.current_board() {
    Ok(value) => value
    Err(_) => abort("board model should be readable")
  }
}

///|
fn test_lane(model : BoardModel, id : Int) -> Int {
  match find_task(model, id) {
    Some(task) => task.lane
    None => -1
  }
}

///|
fn test_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(value) => value
    Err(_) => abort("valid test point")
  }
}

///|
fn repeat_text(count : Int) -> String {
  let builder = StringBuilder()
  for _ in 0..<count {
    builder.write_string("a")
  }
  builder.to_string()
}

///|
test "commands and input preserve ingress order and stay deferred until a frame" {
  let board = test_board()
  assert_true(board.command("move", 1, "1") is Ok(_))
  assert_true(board.focus(true) is Ok(_))
  assert_true(board.key("ArrowRight", false, false, true, false) is Ok(_))
  let before = match board.current_board() {
    Ok(value) => value
    Err(_) => abort("model")
  }
  assert_eq(test_lane(before, 1), 0)
  assert_eq(before.events, 0)
  let after = frame(board)
  assert_eq(test_lane(after, 1), 2)
  assert_eq(after.history.length(), 2)
  assert_eq(after.events, 3)
  assert_eq(after.last_sequence, 3L)
  assert_eq(board.commands.length(), 0)
  ignore(board.command("undo", 0, ""))
  assert_eq(test_lane(frame(board), 1), 1)
  ignore(board.command("undo", 0, ""))
  assert_eq(test_lane(frame(board), 1), 0)
  board.dispose()
}

///|
test "query reconciles selection and rejects hidden card selection" {
  let board = test_board()
  ignore(board.command("query", 0, "SIGNUP"))
  let model = frame(board)
  assert_eq(model.selected, Some(2))
  assert_eq(filtered_tasks(model).length(), 1)
  ignore(board.command("select", 1, ""))
  assert_eq(frame(board).selected, Some(2))
  ignore(board.command("query", 0, "no task matches this"))
  let empty = frame(board)
  assert_eq(empty.selected, None)
  assert_eq(filtered_tasks(empty).length(), 0)
  ignore(board.focus(true))
  ignore(board.key("End", false, false, false, false))
  assert_eq(frame(board).selected, None)
  ignore(board.command("query", 0, "日本語"))
  assert_eq(frame(board).selected, Some(3))
  board.dispose()
}

///|
test "add is bounded normalized and undo restores selection without reusing ids" {
  let board = test_board()
  assert_true(board.command("add", 0, "   ") is Err(InvalidInput))
  assert_true(board.command("add", 0, repeat_text(81)) is Err(InvalidInput))
  assert_true(board.command("add", 0, "line\nbreak") is Err(InvalidInput))
  assert_true(board.command("add", 0, "task\u0000") is Err(InvalidInput))
  ignore(board.command("select", 8, ""))
  ignore(board.command("query", 0, "overview"))
  ignore(board.command("add", 0, "  Confirm “launch” & <signup>  "))
  let model = frame(board)
  assert_eq(model.tasks.length(), 13)
  assert_eq(model.query, "")
  assert_eq(model.selected, Some(13))
  assert_eq(model.active_lane, 0)
  assert_eq(model.tasks[12].title, "Confirm “launch” & <signup>")
  assert_eq(model.scrolls[0].offset().y(), model.scrolls[0].max_offset().y())
  ignore(board.command("undo", 0, ""))
  let restored = frame(board)
  assert_eq(restored.tasks.length(), 12)
  assert_eq(restored.selected, Some(8))
  assert_eq(restored.active_lane, 1)
  ignore(board.command("add", 0, repeat_text(80)))
  assert_eq(frame(board).selected, Some(14))
  board.dispose()
}

///|
test "history and total tasks have independent bounded limits" {
  let board = test_board()
  for index in 0..<40 {
    ignore(board.command("move", 1, if index % 2 == 0 { "1" } else { "2" }))
  }
  let moved = frame(board)
  assert_eq(moved.history.length(), 32)
  for _ in 0..<32 {
    ignore(board.command("undo", 0, ""))
  }
  let restored = frame(board)
  assert_eq(test_lane(restored, 1), 2)
  assert_eq(restored.history.length(), 0)
  for index in 0..<95 {
    ignore(board.command("add", 0, "Task \{index}"))
  }
  let full = frame(board)
  assert_eq(full.tasks.length(), 100)
  assert_eq(full.history.length(), 32)
  assert_eq(full.next_id, 101)
  ignore(board.command("undo", 0, ""))
  ignore(board.command("add", 0, "A replacement task"))
  let replaced = frame(board)
  assert_eq(replaced.tasks.length(), 100)
  assert_eq(replaced.selected, Some(101))
  board.dispose()
}

///|
test "lane scroll uses clipped element hit targets and never scrolls another lane" {
  let board = test_board()
  let initial = frame(board)
  assert_eq(initial.scrolls[0].max_offset().y(), 268.0)
  assert_eq(hit_card(initial, test_point(40.0, 80.0)), Some(1))
  ignore(board.scroll(40.0, 100.0, 0.0, 100.0))
  let scrolled = frame(board)
  assert_eq(scrolled.scrolls[0].offset().y(), 100.0)
  assert_eq(scrolled.scrolls[1].offset().y(), 0.0)
  assert_eq(hit_card(scrolled, test_point(40.0, 50.0)), None)
  assert_eq(hit_card(scrolled, test_point(40.0, 80.0)), Some(2))
  assert_eq(hit_card(scrolled, test_point(330.0, 80.0)), None)
  ignore(board.scroll(-10.0, 80.0, 0.0, 100.0))
  assert_eq(frame(board).scrolls[0].offset().y(), 100.0)
  ignore(board.scroll(40.0, 100.0, 0.0, 1_000_000.0))
  let bottom = frame(board)
  assert_eq(bottom.scrolls[0].offset().y(), 268.0)
  let lanes = match board_lanes(bottom) {
    Ok(value) => value
    Err(_) => abort("lanes")
  }
  for lane in lanes {
    for card in board_cards(bottom, lane) {
      assert_true(lane.viewport.contains_rect(card.visible_bounds))
      assert_true(card.visible_bounds.size().height() > 0.0)
    }
  }
  board.dispose()
}

///|
test "keyboard and semantic selection reveal cards through shared ScrollState" {
  let board = test_board()
  ignore(board.command("select", 7, ""))
  let last = frame(board)
  assert_eq(last.selected, Some(7))
  assert_eq(last.scrolls[0].offset().y(), 268.0)
  ignore(board.focus(true))
  ignore(board.key("Home", false, false, false, false))
  let first = frame(board)
  assert_eq(first.selected, Some(1))
  assert_eq(first.scrolls[0].offset().y(), 0.0)
  ignore(board.key("ArrowDown", false, false, false, false))
  assert_eq(frame(board).selected, Some(2))
  ignore(board.key("End", false, false, false, false))
  assert_eq(frame(board).selected, Some(12))
  board.dispose()
}

///|
test "stationary pointer hover follows keyboard reveal move and undo" {
  let board = test_board()
  ignore(board.pointer_move(40.0, 80.0))
  ignore(board.focus(true))
  for _ in 0..<6 {
    ignore(board.key("ArrowDown", false, false, false, false))
  }
  let revealed = frame(board)
  assert_eq(revealed.selected, Some(7))
  assert_eq(revealed.scrolls[0].offset().y(), 268.0)
  assert_eq(revealed.hover, Some(3))
  assert_true(board.status_json().contains("\"hoverId\":3"))
  ignore(board.key("ArrowRight", false, false, true, false))
  let moved = frame(board)
  assert_eq(test_lane(moved, 7), 1)
  assert_eq(moved.scrolls[0].offset().y(), 166.0)
  assert_eq(moved.hover, Some(2))
  ignore(board.key("z", false, true, false, false))
  let restored = frame(board)
  assert_eq(test_lane(restored, 7), 0)
  assert_eq(restored.scrolls[0].offset().y(), 268.0)
  assert_eq(restored.hover, Some(3))
  ignore(board.key("Home", false, false, false, false))
  let first = frame(board)
  assert_eq(first.scrolls[0].offset().y(), 0.0)
  assert_eq(first.hover, Some(1))
  board.dispose()
}

///|
test "keyboard hover refresh preserves blur visibility and explicit cancel" {
  let board = test_board()
  ignore(board.pointer_move(40.0, 80.0))
  ignore(board.focus(true))
  ignore(board.focus(false))
  ignore(board.key("End", false, false, false, false))
  let blurred = frame(board)
  assert_eq(blurred.selected, Some(1))
  assert_eq(blurred.hover, None)
  ignore(board.focus(true))
  ignore(board.visible(false))
  ignore(board.key("End", false, false, false, false))
  let hidden = frame(board)
  assert_eq(hidden.selected, Some(1))
  assert_eq(hidden.hover, None)
  ignore(board.visible(true))
  ignore(board.cancel())
  ignore(board.key("End", false, false, false, false))
  let cancelled = frame(board)
  assert_eq(cancelled.selected, Some(12))
  assert_true(cancelled.pointer is None)
  assert_eq(cancelled.hover, None)
  board.dispose()
}

///|
test "drag threshold and release move exactly one task with undo" {
  let board = test_board()
  ignore(board.pointer_button(40.0, 80.0, true))
  ignore(board.pointer_move(44.0, 80.0))
  let pending = frame(board)
  assert_true(pending.drag.is_pending())
  assert_true(!pending.drag.is_dragging())
  ignore(board.pointer_button(44.0, 80.0, false))
  assert_eq(frame(board).history.length(), 0)
  ignore(board.pointer_button(40.0, 80.0, true))
  ignore(board.pointer_move(45.0, 80.0))
  assert_true(frame(board).drag.is_dragging())
  ignore(board.pointer_move(380.0, 100.0))
  assert_eq(frame(board).drop_lane, Some(1))
  ignore(board.pointer_button(380.0, 100.0, false))
  let dropped = frame(board)
  assert_eq(test_lane(dropped, 1), 1)
  assert_eq(dropped.history.length(), 1)
  assert_true(!dropped.drag.is_dragging())
  assert_eq(dropped.drop_lane, None)
  // A duplicate release is not a second move.
  ignore(board.pointer_button(730.0, 100.0, false))
  assert_eq(test_lane(frame(board), 1), 1)
  ignore(board.command("undo", 0, ""))
  assert_eq(test_lane(frame(board), 1), 0)
  board.dispose()
}

///|
test "outside release and each cancellation path cannot commit a later drop" {
  for cancellation in 0..<6 {
    let board = test_board()
    ignore(board.pointer_button(40.0, 80.0, true))
    ignore(board.pointer_move(380.0, 100.0))
    assert_true(frame(board).drag.is_dragging())
    match cancellation {
      0 => ignore(board.cancel())
      1 => ignore(board.focus(false))
      2 => {
        ignore(board.visible(false))
        ignore(board.visible(true))
      }
      3 => ignore(board.set_viewport(900.0, 520.0, 1.0))
      4 => ignore(board.key("Escape", false, false, false, false))
      _ => ignore(board.pointer_button(-50.0, 100.0, false))
    }
    ignore(board.pointer_button(730.0, 100.0, false))
    let cancelled = frame(board)
    assert_eq(test_lane(cancelled, 1), 0)
    assert_eq(cancelled.history.length(), 0)
    assert_true(!cancelled.drag.is_dragging())
    assert_true(!cancelled.drag.is_pending())
    board.dispose()
  }
}

///|
test "filter commands cannot resurrect a queued drag source" {
  let board = test_board()
  ignore(board.pointer_button(40.0, 80.0, true))
  ignore(board.pointer_move(380.0, 100.0))
  ignore(board.command("query", 0, "guide"))
  ignore(board.pointer_button(730.0, 100.0, false))
  let model = frame(board)
  assert_eq(test_lane(model, 1), 0)
  assert_eq(model.selected, Some(10))
  assert_true(!model.drag.is_dragging())
  assert_eq(model.history.length(), 0)
  board.dispose()
}

///|
test "a semantic focus confirmation preserves only the same card gesture" {
  let board = test_board()
  ignore(board.pointer_button(40.0, 80.0, true))
  ignore(board.command("select", 1, ""))
  ignore(board.pointer_move(380.0, 100.0))
  assert_true(frame(board).drag.is_dragging())
  ignore(board.command("select", 2, ""))
  ignore(board.pointer_button(730.0, 100.0, false))
  let model = frame(board)
  assert_eq(model.selected, Some(2))
  assert_eq(test_lane(model, 1), 0)
  assert_true(!model.drag.is_dragging())
  board.dispose()
}

///|
test "responsive one-lane layout and lane selection stay in portable state" {
  let board = test_board()
  ignore(board.set_viewport(360.0, 520.0, 2.0))
  let mobile = frame(board)
  assert_eq(mobile.scale, 2.0)
  let lanes = match board_lanes(mobile) {
    Ok(value) => value
    Err(_) => abort("lanes")
  }
  assert_eq(lanes.length(), 1)
  assert_eq(lanes[0].lane, 0)
  assert_eq(lanes[0].bounds.size().width(), 336.0)
  ignore(board.command("lane", 1, ""))
  let second = frame(board)
  assert_eq(second.active_lane, 1)
  assert_eq(second.selected, Some(8))
  assert_eq(hit_card(second, test_point(40.0, 80.0)), Some(8))
  ignore(board.focus(true))
  ignore(board.key("End", false, false, false, false))
  assert_eq(frame(board).selected, Some(10))
  ignore(board.key("ArrowRight", false, false, true, false))
  let moved = frame(board)
  assert_eq(moved.active_lane, 2)
  assert_eq(test_lane(moved, 10), 2)
  ignore(board.set_viewport(700.0, 520.0, 1.0))
  let desktop = frame(board)
  assert_eq(
    match board_lanes(desktop) {
      Ok(value) => value.length()
      Err(_) => 0
    },
    3,
  )
  board.dispose()
}

///|
test "scene text and semantic DTO retain task ids and full titles" {
  let board = test_board()
  let scene = match board.render_frame() {
    Ok(value) => value
    Err(_) => abort("scene")
  }
  let mut japanese = false
  let mut lane_label = false
  for item in scene.items() {
    match item {
      @scene.TextItem(text~, clip_chain_id~, ..) => {
        if text == "日本語の案内を確認する" {
          japanese = true
          assert_eq(clip_chain_id, Some(1))
        }
        if text == "In progress" {
          lane_label = true
        }
      }
      _ => ()
    }
  }
  assert_true(japanese)
  assert_true(lane_label)
  assert_eq(scene.clip_chains().length(), 4)
  let status = board.status_json()
  assert_true(status.contains("\"total\":12,\"done\":2"))
  assert_true(status.contains("\"selectedId\":1"))
  let dto = board.host_layout_json()
  assert_true(
    dto.contains(
      "\"id\":3,\"role\":\"button\",\"name\":\"日本語の案内を確認する\"",
    ),
  )
  assert_true(!dto.contains("\"id\":7,\"role\":\"button\""))
  ignore(board.command("select", 7, ""))
  ignore(frame(board))
  assert_true(board.host_layout_json().contains("\"id\":7,\"role\":\"button\""))
  board.dispose()
}

///|
test "bounded ingress rejects invalid values and disposal clears queued work" {
  let board = test_board()
  assert_true(board.command("unknown", 0, "") is Err(InvalidCommand))
  assert_true(board.command("move", 1, "9") is Err(InvalidCommand))
  assert_true(board.command("select", -1, "") is Err(InvalidCommand))
  assert_true(board.command("query", 0, repeat_text(81)) is Err(InvalidInput))
  assert_true(board.set_viewport(0.0, 520.0, 1.0) is Err(InvalidViewport))
  assert_true(board.set_viewport(1000.0, 520.0, 9.0) is Err(InvalidViewport))
  assert_true(board.pointer_move(1_000_001.0, 0.0) is Err(InvalidInput))
  assert_true(
    board.key(repeat_text(33), false, false, false, false) is Err(InvalidInput),
  )
  for _ in 0..<1024 {
    assert_true(board.pointer_move(0.0, 0.0) is Ok(_))
  }
  assert_true(board.cancel() is Err(QueueFull))
  assert_true(board.command("undo", 0, "") is Err(QueueFull))
  let model = frame(board)
  assert_eq(model.events, 1024)
  assert_true(board.cancel() is Ok(_))
  board.dispose()
  board.dispose()
  assert_eq(board.ingress.pending_count(), 0)
  assert_eq(board.commands.length(), 0)
  assert_true(board.render_frame() is Err(Stopped))
  assert_true(board.command("add", 0, "after disposal") is Err(Stopped))
}

///|
test "finite tiny and maximum viewports render without invalid geometry" {
  let board = test_board()
  for
    (width, height, scale) in [
      (1.0, 1.0, 0.1),
      (360.0, 100.0, 1.0),
      (8192.0, 8192.0, 8.0),
    ] {
    assert_true(board.set_viewport(width, height, scale) is Ok(_))
    let scene = match board.render_frame() {
      Ok(value) => value
      Err(_) => abort("bounded viewport renders")
    }
    assert_eq(scene.viewport().size().width(), width)
    assert_eq(scene.viewport().size().height(), height)
    assert_eq(scene.scale(), scale)
  }
  board.dispose()
}
