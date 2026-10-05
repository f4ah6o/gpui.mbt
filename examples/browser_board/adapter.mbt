///|
/// Thin JS-target exports: domain behavior lives in the portable task_board
/// package. Success envelopes wrap mutations and scene frames; status/layout
/// are raw JSON DTOs. No DOM or browser references enter the model.
let runtime : Ref[@task_board.BoardDemo?] = Ref(None)

///|
fn ok(value : String) -> String {
  "{\"ok\":true,\"value\":\{value}}"
}

///|
fn error(value : @task_board.BoardError) -> String {
  "{\"ok\":false,\"error\":{\"code\":\{@task_board.json_quote(value.code())},\"operation\":\"task_board\",\"message\":\{@task_board.json_quote(value.message())}}}"
}

///|
fn invoke(
  action : (@task_board.BoardDemo) -> Result[Unit, @task_board.BoardError],
) -> String {
  match runtime.val {
    None => error(@task_board.Stopped)
    Some(board) =>
      match action(board) {
        Ok(_) => ok("true")
        Err(value) => error(value)
      }
  }
}

///|
#export_name("gpui_board_start")
pub fn start() -> String {
  match runtime.val {
    Some(_) => ok("true")
    None =>
      match @task_board.BoardDemo::new() {
        Ok(board) => {
          runtime.val = Some(board)
          ok("true")
        }
        Err(value) => error(value)
      }
  }
}

///|
#export_name("gpui_board_set_viewport")
pub fn set_viewport(width : Double, height : Double, scale : Double) -> String {
  invoke(board => board.set_viewport(width, height, scale))
}

///|
#export_name("gpui_board_pointer_move")
pub fn pointer_move(x : Double, y : Double) -> String {
  invoke(board => board.pointer_move(x, y))
}

///|
#export_name("gpui_board_pointer_button")
pub fn pointer_button(x : Double, y : Double, pressed : Bool) -> String {
  invoke(board => board.pointer_button(x, y, pressed))
}

///|
#export_name("gpui_board_scroll")
pub fn scroll(x : Double, y : Double, dx : Double, dy : Double) -> String {
  invoke(board => board.scroll(x, y, dx, dy))
}

///|
#export_name("gpui_board_key")
pub fn key(
  key : String,
  shift : Bool,
  control : Bool,
  alt : Bool,
  meta : Bool,
) -> String {
  invoke(board => board.key(key, shift, control, alt, meta))
}

///|
#export_name("gpui_board_focus")
pub fn focus(value : Bool) -> String {
  invoke(board => board.focus(value))
}

///|
#export_name("gpui_board_visible")
pub fn visible(value : Bool) -> String {
  invoke(board => board.visible(value))
}

///|
#export_name("gpui_board_cancel")
pub fn cancel() -> String {
  invoke(board => board.cancel())
}

///|
#export_name("gpui_board_command")
pub fn command(kind : String, id : Int, value : String) -> String {
  invoke(board => board.command(kind, id, value))
}

///|
#export_name("gpui_board_render_frame")
pub fn render_frame() -> String {
  match runtime.val {
    None => error(@task_board.Stopped)
    Some(board) =>
      match board.render_frame() {
        Ok(scene) => ok(scene.canonical_json())
        Err(value) => error(value)
      }
  }
}

///|
#export_name("gpui_board_status")
pub fn status() -> String {
  match runtime.val {
    Some(board) => board.status_json()
    None => "{\"active\":false}"
  }
}

///|
#export_name("gpui_board_host_layout")
pub fn host_layout() -> String {
  match runtime.val {
    Some(board) => board.host_layout_json()
    None => "{\"version\":1,\"mobile\":false,\"lanes\":[],\"nodes\":[]}"
  }
}

///|
#export_name("gpui_board_dispose")
pub fn dispose() -> String {
  match runtime.val {
    Some(board) => {
      board.dispose()
      runtime.val = None
    }
    None => ()
  }
  ok("true")
}
