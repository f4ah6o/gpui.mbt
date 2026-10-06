///|
fn state_observer_enabled(value : String?) -> Bool {
  value == Some("1")
}

///|
fn json_string(value : String?) -> String {
  match value {
    Some(text) => @json.to_json(text).stringify()
    None => "null"
  }
}

///|
fn marked_json(field : @text_field.TextField) -> String {
  match field.marked_range() {
    Some(value) => "{\"start\":\{value.start()},\"end\":\{value.end()}}"
    None => "null"
  }
}

///|
fn caret_json(field : @text_field.TextField) -> String {
  match field.caret_rect() {
    Ok(value) => {
      let left = value.left().floor()
      let top = value.top().floor()
      let right = value.right().ceil()
      let bottom = value.bottom().ceil()
      let values = [left, top, right, bottom]
      for coordinate in values {
        if coordinate.is_nan() ||
          coordinate.is_inf() ||
          coordinate < -2147483648.0 ||
          coordinate > 2147483647.0 {
          return "null"
        }
      }
      let width = right - left
      let height = bottom - top
      if width < 1.0 ||
        height < 1.0 ||
        width > 2147483647.0 ||
        height > 2147483647.0 {
        return "null"
      }
      "{\"x\":\{left.to_int()},\"y\":\{top.to_int()},\"width\":\{width.to_int()},\"height\":\{height.to_int()}}"
    }
    Err(_) => "null"
  }
}

///|
/// Bounds in logical content-view coordinates with a top-left origin, matching
/// the SceneSnapshot viewport and TextField bounds. These remain accepted-frame
/// metadata and are not multiplied by the backing scale.
fn field_bounds_json(field : @text_field.TextField) -> String {
  let bounds = field.bounds()
  let x = bounds.left()
  let y = bounds.top()
  let width = bounds.right() - x
  let height = bounds.bottom() - y
  for value in [x, y, width, height] {
    if value.is_nan() || value.is_inf() {
      return "null"
    }
  }
  if width <= 0.0 || height <= 0.0 {
    return "null"
  }
  "{\"x\":\{@json.to_json(x).stringify()},\"y\":\{@json.to_json(y).stringify()},\"width\":\{@json.to_json(width).stringify()},\"height\":\{@json.to_json(height).stringify()}}"
}

///|
fn state_json(
  presentation : Int,
  field : @text_field.TextField,
  session_epoch : Int,
  commit_count : Int,
) -> String {
  let selection = field.selection()
  let source_revision = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_REVISION"),
  )
  let source_tree = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_SOURCE_TREE"),
  )
  let binary_sha256 = json_string(
    @env.get_env_var("GPUI_FIELD_MACOS_BINARY_SHA256"),
  )
  let committed = @json.to_json(field.committed_document().text()).stringify()
  let preview = @json.to_json(field.document().text()).stringify()
  "{\"version\":1,\"presentation\":\{presentation},\"text\":\{preview},\"committed\":\{committed},\"selection\":{\"anchor\":\{selection.anchor()},\"head\":\{selection.head()}},\"focused\":\{field.is_focused()},\"revision\":\{field.revision()},\"composing\":\{field.is_composing()},\"marked\":\{marked_json(field)},\"caret\":\{caret_json(field)},\"field_bounds\":\{field_bounds_json(field)},\"session_epoch\":\{session_epoch},\"commit_count\":\{commit_count},\"source_revision\":\{source_revision},\"source_tree\":\{source_tree},\"binary_sha256\":\{binary_sha256}}"
}

///|
fn state_line(
  presentation : Int,
  field : @text_field.TextField,
  session_epoch : Int,
  commit_count : Int,
) -> String {
  "GPUI_FIELD_MACOS_STATE \{state_json(presentation, field, session_epoch, commit_count)}"
}

///|
extern "C" fn state_flush_stdout() -> Unit = "gpui_macos_field_flush_stdout"

///|
/// @test_only
extern "C" fn acceptance_wait_command() -> Int = "gpui_macos_field_wait_command"

///|
/// @test_only
extern "C" fn acceptance_poll_abort() -> Int = "gpui_macos_field_poll_abort"
