///|
// This example-only observer cannot edit the field or invoke input callbacks.
fn field_state_enabled(value : String?) -> Bool {
  value == Some("1")
}

///|
fn field_state_json(
  presentation : Int,
  text : String,
  anchor : Int,
  head : Int,
  focused : Bool,
  revision : Int,
) -> String {
  let escaped = @json.to_json(text).stringify()
  "{\"version\":1,\"presentation\":\{presentation},\"text\":\{escaped},\"selection\":{\"anchor\":\{anchor},\"head\":\{head}},\"focused\":\{focused},\"revision\":\{revision}}"
}

///|
fn field_state_line(
  presentation : Int,
  field : @text_field.TextField,
) -> String {
  let selection = field.selection()
  "GPUI_FIELD_STATE \{field_state_json(presentation, field.document().text(), selection.anchor(), selection.head(), field.is_focused(), field.revision())}"
}

///|
// MoonBit native println uses buffered stdio. Flush only opt-in observer output
// so a live E2E consumer can see a checkpoint before the application exits.
extern "C" fn field_state_flush_stdout() -> Unit = "gpui_field_state_flush_stdout"
