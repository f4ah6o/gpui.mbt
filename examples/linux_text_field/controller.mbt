///|
/// The display transaction keeps admitted edits pending across Busy. A native
/// preflight failure restores the last submitted document; the owner then
/// re-arms its native epoch before accepting another editor event.
enum FieldFrameDecision {
  Accepted
  BusyPending
  RecoverPending
  RejectPending
} derive(Eq)

///|
fn classify_field_frame(
  result : Result[Unit, @diagnostics.FrameworkError],
) -> FieldFrameDecision {
  match result {
    Ok(_) => Accepted
    Err(error) =>
      match error.code() {
        @diagnostics.Busy => BusyPending
        @diagnostics.SurfaceLost | @diagnostics.DeviceLost => RecoverPending
        _ => RejectPending
      }
  }
}

///|
fn restore_submitted_field(
  submitted : @text_field.TextField,
  pending : @text_field.TextField,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  // Restore submitted document/selection while retaining current owner bounds.
  match submitted.with_bounds(pending.bounds()) {
    Ok(value) => value.with_focus(pending.is_focused())
    Err(error) => Err(error)
  }
}

///|
enum OwnerBlurError {
  Native(@diagnostics.FrameworkError)
  Field(@text_field.TextFieldError)
}

///|
fn apply_owner_blur(
  field : @text_field.TextField,
  disarmed : Result[Unit, @diagnostics.FrameworkError],
) -> Result[@text_field.TextField, OwnerBlurError] {
  match disarmed {
    Err(error) => Err(Native(error))
    Ok(_) =>
      match field.with_focus(false) {
        Ok(value) => Ok(value)
        Err(error) => Err(Field(error))
      }
  }
}

///|
fn cut_after_write(
  previous : @text_field.TextField,
  candidate : @text_field.TextField,
  write : Result[Unit, @diagnostics.FrameworkError],
) -> @text_field.TextField {
  match write {
    Ok(_) => candidate
    Err(_) => previous
  }
}

///|
fn paste_if_current(
  field : @text_field.TextField,
  revision : Int,
  epoch_before : Result[Int, @diagnostics.FrameworkError],
  epoch_after : Result[Int, @diagnostics.FrameworkError],
  text : String,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let current = match (epoch_before, epoch_after) {
    (Ok(before), Ok(after)) =>
      before == after && field.revision() == revision && field.is_focused()
    _ => false
  }
  if current {
    field.replace_selection(text, measure, admit)
  } else {
    Ok(field)
  }
}
