///|
const FIELD_FONT_FAMILY : String = "Segoe UI"

///|
const FIELD_FONT_SIZE : Double = 18.0

///|
const FIELD_OWNER_GENERATION : Int = 2

///|
fn palette_measure(
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, @text_field.TextFieldError] {
  match @windows_text.measure(document, FIELD_FONT_FAMILY, FIELD_FONT_SIZE) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.MeasurementFailed)
  }
}

///|
fn palette_admit(
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @text_field.TextFieldError] {
  let (origin, clip_rect) = match
    @text_field.scene_text_run_geometry(measurement) {
    Ok(value) => value
    Err(_) => return Err(@text_field.UnsupportedLayout)
  }
  match
    @windows_text.admit_scene_text_run_at(
      document,
      FIELD_FONT_SIZE,
      origin,
      clip_rect,
    ) {
    Ok(_) => Ok(())
    Err(_) => Err(@text_field.AdmissionFailed)
  }
}

///|
fn palette_hit(
  document : @text.TextDocument,
  point : @primitives.Point,
) -> Result[@text_layout.TextHit, @text_field.TextFieldError] {
  match
    @windows_text.hit_test(document, FIELD_FONT_FAMILY, FIELD_FONT_SIZE, point) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.HitTestFailed)
  }
}

///|
fn palette_field(
  bounds : @primitives.Rect,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let document = match @text.TextDocument::new("") {
    Ok(value) => value
    Err(_) => return Err(@text_field.MalformedText)
  }
  @text_field.TextField::new(
    FIELD_OWNER_GENERATION.to_uint64(),
    bounds,
    FIELD_FONT_SIZE,
    document,
    palette_measure,
    palette_admit,
  )
}

///|
fn windows_palette_caret_rect(
  field : @text_field.TextField,
) -> Result[@primitives.Rect, @diagnostics.FrameworkError] {
  let caret = match field.caret_rect() {
    Ok(value) => value
    Err(_) =>
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "palette_caret_rect",
        ),
      )
  }
  let left = caret.left().floor()
  let top = caret.top().floor()
  let right = caret.right().ceil()
  let bottom = caret.bottom().ceil()
  for value in [left, top, right, bottom] {
    if value.is_nan() ||
      value.is_inf() ||
      value < -2147483648.0 ||
      value > 2147483647.0 {
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "palette_caret_rect",
        ),
      )
    }
  }
  let width = right - left
  let height = bottom - top
  if width < 1.0 ||
    height < 1.0 ||
    width > 2147483647.0 ||
    height > 2147483647.0 {
    return Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.InvalidInput,
        "palette_caret_rect",
      ),
    )
  }
  match @primitives.Rect::new(left, top, width, height) {
    Ok(value) => Ok(value)
    Err(_) =>
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "palette_caret_rect",
        ),
      )
  }
}

///|
struct PaletteNativeComposition {
  original : @text_field.TextField
  replacement_range : @text.TextRange
}

///|
struct PaletteNativeOwner {
  owner_generation : Int
  open_epoch : Int
  epoch : Int
  sequence : Int64
  composition : PaletteNativeComposition?
}

///|
enum PaletteNativeKeyDisposition {
  SharedFieldKey
  NativeImeKey
  CancelNativeComposition
} derive(Eq)

///|
/// Holds an invisible-composition Enter/Escape press until the matching native
/// release is observed, even if its owner or palette epoch changes first.
enum PaletteNativeKeyGuard {
  GuardEnter
  GuardEscape
} derive(Eq)

///|
fn palette_native_guard_for_key(
  key : @primitives.Key,
) -> PaletteNativeKeyGuard? {
  match key {
    @primitives.Enter => Some(GuardEnter)
    @primitives.Escape => Some(GuardEscape)
    _ => None
  }
}

///|
fn palette_native_guard_for_press(
  event : @primitives.InputEvent,
) -> PaletteNativeKeyGuard? {
  match event {
    @primitives.KeyPressed(key~, ..) => palette_native_guard_for_key(key)
    _ => None
  }
}

///|
/// The guard is retired only by the corresponding platform release. Palette
/// close, native composition end, and reopen deliberately do not clear it.
fn palette_native_guard_event(
  key_guard : PaletteNativeKeyGuard?,
  event : @primitives.InputEvent,
) -> (Bool, PaletteNativeKeyGuard?) {
  match key_guard {
    None => (false, None)
    Some(expected) =>
      match event {
        @primitives.KeyPressed(key~, ..) if palette_native_guard_for_key(key) ==
          Some(expected) => (true, key_guard)
        @primitives.KeyReleased(key~, ..) if palette_native_guard_for_key(key) ==
          Some(expected) => (true, None)
        _ => (false, key_guard)
      }
  }
}

///|
/// Before the first nonempty IMM mark, the native owner already has a
/// composition transaction while the shared TextField has no visible mark.
/// Keep Enter in the IME and let Escape cancel that transaction first.
fn palette_native_key_disposition(
  owner : PaletteNativeOwner?,
  field : @text_field.TextField,
  event : @primitives.InputEvent,
) -> PaletteNativeKeyDisposition {
  match owner {
    Some(active) if active.composition is Some(_) && !field.is_composing() =>
      match event {
        @primitives.KeyPressed(key=@primitives.Escape, repeat=false, ..) =>
          CancelNativeComposition
        @primitives.KeyPressed(key=@primitives.Enter | @primitives.Escape, ..) =>
          NativeImeKey
        _ => SharedFieldKey
      }
    _ => SharedFieldKey
  }
}

///|
fn palette_native_owner(
  owner_generation : Int,
  open_epoch : Int,
  epoch : Int,
) -> PaletteNativeOwner {
  { owner_generation, open_epoch, epoch, sequence: 0L, composition: None, }
}

///|
fn palette_native_owner_after_update(
  owner : PaletteNativeOwner,
  epoch : Int,
) -> PaletteNativeOwner {
  if owner.epoch == epoch {
    owner
  } else {
    palette_native_owner(owner.owner_generation, owner.open_epoch, epoch)
  }
}

///|
fn palette_native_target_current(
  palette : @palette.CommandPalette,
  owner : PaletteNativeOwner,
  window : @platform.WindowId,
  target : @native.TextSessionTarget,
) -> Bool {
  palette.is_open() &&
  owner.open_epoch == palette.open_epoch() &&
  owner.owner_generation == FIELD_OWNER_GENERATION &&
  owner.epoch > 0 &&
  target.window == window &&
  target.owner_generation == owner.owner_generation &&
  target.epoch == owner.epoch &&
  target.sequence > owner.sequence
}

///|
fn palette_native_accept_event(
  owner : PaletteNativeOwner,
  target : @native.TextSessionTarget,
) -> PaletteNativeOwner {
  { ..owner, sequence: target.sequence, }
}

///|
fn palette_begin_native_owner(
  host : @native.Host,
  window : @platform.WindowId,
  palette : @palette.CommandPalette,
) -> Result[PaletteNativeOwner, @diagnostics.FrameworkError] {
  let caret = match windows_palette_caret_rect(palette.field()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    host.begin_text_session(
      window,
      FIELD_OWNER_GENERATION,
      palette.field().committed_document(),
      caret,
    ) {
    Ok(epoch) =>
      Ok(
        palette_native_owner(
          FIELD_OWNER_GENERATION,
          palette.open_epoch(),
          epoch,
        ),
      )
    Err(error) => Err(error)
  }
}

///|
fn palette_update_native_owner(
  host : @native.Host,
  window : @platform.WindowId,
  palette : @palette.CommandPalette,
  owner : PaletteNativeOwner,
  external_edit : Bool,
) -> Result[PaletteNativeOwner, @diagnostics.FrameworkError] {
  if owner.open_epoch != palette.open_epoch() || !palette.is_open() {
    return Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.StaleHandle,
        "palette_owner_open_epoch",
      ),
    )
  }
  let caret = match windows_palette_caret_rect(palette.field()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    host.update_text_session(
      window,
      owner.epoch,
      owner.owner_generation,
      palette.field().committed_document(),
      caret,
      external_edit~,
    ) {
    Ok(epoch) => Ok(palette_native_owner_after_update(owner, epoch))
    Err(error) => Err(error)
  }
}

///|
fn palette_cancel_native_owner(
  host : @native.Host,
  window : @platform.WindowId,
  owner : PaletteNativeOwner,
) -> Result[PaletteNativeOwner, @diagnostics.FrameworkError] {
  match host.cancel_text_session(window, owner.epoch, owner.owner_generation) {
    Ok(epoch) => Ok(palette_native_owner_after_update(owner, epoch))
    Err(error) => Err(error)
  }
}

///|
fn palette_end_native_owner(
  host : @native.Host,
  window : @platform.WindowId,
  owner : PaletteNativeOwner?,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match owner {
    None => Ok(())
    Some(active) =>
      host.end_text_session(window, active.epoch, active.owner_generation)
  }
}

///|
/// External edits must synchronously fence the prior native snapshot before
/// another platform/native event can be consumed. The native external-edit
/// contract returns a fresh epoch; retaining the old one is a failed fence.
fn palette_sync_external_edit_owner(
  owner : PaletteNativeOwner?,
  sync : (PaletteNativeOwner) -> Result[
    PaletteNativeOwner,
    @diagnostics.FrameworkError,
  ],
) -> Result[PaletteNativeOwner?, @diagnostics.FrameworkError] {
  match owner {
    None => Ok(None)
    Some(active) =>
      match sync(active) {
        Err(error) => Err(error)
        Ok(next) if next.epoch != active.epoch => Ok(Some(next))
        Ok(_) =>
          Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.StaleHandle,
              "palette_external_edit_epoch",
            ),
          )
      }
  }
}

///|
/// Restore a rejected native transaction and synchronously revoke its session
/// before another record can arrive. A malformed/unadmitted candidate is never
/// allowed to leave a marked field paired with an owner that has no transaction.
fn palette_reject_native_edit(
  palette : @palette.CommandPalette,
  owner : PaletteNativeOwner,
  cancel : (PaletteNativeOwner) -> Result[
    PaletteNativeOwner,
    @diagnostics.FrameworkError,
  ],
) -> Result[PaletteNativeOwner, @diagnostics.FrameworkError] {
  let (restored, cleared) = palette_native_cancel_composition(owner)
  match restored {
    Some(candidate) =>
      match palette.install_field_at(owner.open_epoch, candidate) {
        Ok(_) => ()
        Err(_) =>
          return Err(
            @diagnostics.FrameworkError::new(
              @diagnostics.InvalidInput,
              "palette_restore_rejected_native_edit",
            ),
          )
      }
    None => ()
  }
  match cancel(cleared) {
    Err(error) => Err(error)
    Ok(next) if next.epoch != owner.epoch => Ok(next)
    Ok(_) =>
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.StaleHandle,
          "palette_reject_native_epoch",
        ),
      )
  }
}

///|
fn palette_replacement_target_matches(
  field : @text_field.TextField,
  replacement : @text.TextRange,
) -> Bool {
  let selection = if field.is_composing() {
    field.committed_document().selection().normalized_range()
  } else {
    field.selection().normalized_range()
  }
  replacement == selection
}

///|
fn palette_native_start_composition(
  owner : PaletteNativeOwner,
  field : @text_field.TextField,
  replacement : @text.TextRange,
) -> PaletteNativeOwner? {
  if !field.is_focused() ||
    field.is_composing() ||
    !palette_replacement_target_matches(field, replacement) {
    None
  } else {
    Some({
      ..owner,
      composition: Some({ original: field, replacement_range: replacement, }),
    })
  }
}

///|
fn palette_native_append_result(
  owner : PaletteNativeOwner,
  field : @text_field.TextField,
  text : String,
  replacement : @text.TextRange,
) -> Result[
  (@text_field.TextField, PaletteNativeOwner),
  @text_field.TextFieldError,
] {
  match owner.composition {
    None =>
      if !palette_replacement_target_matches(field, replacement) {
        Err(@text_field.InvalidSelection)
      } else {
        match field.replace_selection(text, palette_measure, palette_admit) {
          Ok(value) => Ok((value, owner))
          Err(error) => Err(error)
        }
      }
    Some(transaction) => {
      if transaction.replacement_range != replacement {
        return Err(@text_field.InvalidSelection)
      }
      match
        transaction.original.replace_selection(
          text, palette_measure, palette_admit,
        ) {
        Ok(value) => Ok((value, { ..owner, composition: None, }))
        Err(error) => Err(error)
      }
    }
  }
}

///|
fn palette_native_update_mark(
  owner : PaletteNativeOwner,
  text : String,
  cursor_utf16 : Int?,
  attributes : Array[Int],
  replacement : @text.TextRange,
) -> Result[
  (@text_field.TextField, PaletteNativeOwner),
  @text_field.TextFieldError,
] {
  let transaction = match owner.composition {
    Some(value) if value.replacement_range == replacement => value
    _ => return Err(@text_field.InvalidSelection)
  }
  let mark_document = match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => return Err(@text_field.MalformedText)
  }
  if attributes.length() != 0 &&
    attributes.length() != mark_document.utf16_length() {
    return Err(@text_field.InvalidSelection)
  }
  for attribute in attributes {
    if attribute < 0 || attribute > 5 {
      return Err(@text_field.InvalidSelection)
    }
  }
  let cursor = match cursor_utf16 {
    Some(value) => value
    None if mark_document.utf16_length() == 0 => 0
    None => return Err(@text_field.InvalidSelection)
  }
  if cursor < 0 || cursor > mark_document.utf16_length() {
    return Err(@text_field.InvalidSelection)
  }
  let selection = match @text.TextSelection::new(cursor, cursor) {
    Ok(value) => value
    Err(_) => return Err(@text_field.InvalidSelection)
  }
  match mark_document.with_selection(selection) {
    Err(_) => return Err(@text_field.InvalidSelection)
    Ok(_) => ()
  }
  match
    transaction.original.update_composition(
      text, selection, palette_measure, palette_admit,
    ) {
    Ok(field) => Ok((field, owner))
    Err(error) => Err(error)
  }
}

///|
fn palette_native_end_composition(
  owner : PaletteNativeOwner,
) -> (@text_field.TextField?, PaletteNativeOwner) {
  match owner.composition {
    None => (None, owner)
    Some(transaction) =>
      (Some(transaction.original), { ..owner, composition: None, })
  }
}

///|
fn palette_native_cancel_composition(
  owner : PaletteNativeOwner,
) -> (@text_field.TextField?, PaletteNativeOwner) {
  match owner.composition {
    None => (None, owner)
    Some(transaction) =>
      (Some(transaction.original), { ..owner, composition: None, })
  }
}

///|
enum PaletteFrameDecision {
  Accepted
  BusyPending
  RecoverPending
  RejectPending
} derive(Eq)

///|
fn classify_palette_frame(
  result : Result[Unit, @diagnostics.FrameworkError],
) -> PaletteFrameDecision {
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
/// A failed native close fence must not finish the terminal or run a command.
fn palette_finish_close_after_fence(
  palette : @palette.CommandPalette,
  epoch : Int,
  tree : Ref[@element.ElementTree],
  fenced : Bool,
) -> Result[Unit, @palette.PaletteError] {
  if fenced {
    palette.finish_close(epoch, tree)
  } else {
    Ok(())
  }
}
