///|
enum MacFieldOwnerError {
  StaleWindow
  StaleHost
  StaleEpoch
  ReplayedOrOldSequence
  RevisionMismatch
  UnsupportedReconversion
  UnsupportedStyle
  HiddenCursor
  UnsupportedInput
  UnsupportedMultiline
  UnsupportedBidi
  UnsupportedColorGlyph
  Field(@text_field.TextFieldError)
}

///|
struct MacTextOwner {
  window : @platform.WindowId
  host_epoch : Int64
  epoch : Int
  last_sequence : Int64
  revision : Int
  active : Bool
  entered : Bool
  forwarded_keys : Array[ForwardedKey]
}

///|
struct ForwardedKey {
  key_code : Int
  key : @primitives.Key
  modifiers : @primitives.Modifiers
}

///|
struct MacBatchTransition {
  field : @text_field.TextField
  owner : MacTextOwner
  commits : Int
  external_edit : Bool
  action : @text_field.TextFieldAction?
}

///|
struct MacCommitLedger {
  accepted : Int
  pending : Int
}

///|
fn mac_text_owner(
  window : @platform.WindowId,
  host_epoch : Int64,
  epoch : Int,
  revision : Int,
) -> MacTextOwner {
  {
    window,
    host_epoch,
    epoch,
    last_sequence: 0L,
    revision,
    active: true,
    // The constructor is used only after begin_text_session succeeds; that
    // native result is the entry acknowledgement, with no Entered callback.
    entered: true,
    forwarded_keys: [],
  }
}

///|
fn owner_batch_current(
  owner : MacTextOwner,
  window : @platform.WindowId,
  host_epoch : Int64,
  epoch : Int,
  sequence : Int64,
  owner_revision : Int64,
  field_revision : Int,
  geometry_revision_pending? : Bool = false,
) -> Bool {
  owner.active &&
  window == owner.window &&
  host_epoch == owner.host_epoch &&
  epoch == owner.epoch &&
  sequence > owner.last_sequence &&
  owner_revision == owner.revision.to_int64() &&
  // Resize can advance the local field revision while native still reports
  // the last acknowledged owner revision. The caller tracks that exact delta.
  (
    field_revision == owner.revision ||
    (geometry_revision_pending && field_revision > owner.revision)
  )
}

///|
fn mac_owner_geometry_revision_after_resize(
  owner : MacTextOwner,
  previous_field_revision : Int,
  next_field_revision : Int,
  pending_geometry_revision : Int?,
) -> Int? {
  if previous_field_revision == owner.revision ||
    pending_geometry_revision == Some(previous_field_revision) {
    Some(next_field_revision)
  } else {
    None
  }
}

///|
// AppKit may state the exact range that its current insertion replaces.
// Accept only the current visible target; all other ranges request broader
// reconversion/surrounding edits that this field does not support.
fn mac_replacement_range_supported(
  field : @text_field.TextField,
  replacement : @text.TextRange?,
) -> Bool {
  match replacement {
    None => true
    Some(range) =>
      match field.marked_range() {
        Some(marked) => range == marked
        None => range == field.selection().normalized_range()
      }
  }
}

///|
fn mac_text_error(error : @macos_text.MacTextError) -> MacFieldOwnerError {
  match error {
    @macos_text.UnsupportedBidi => UnsupportedBidi
    @macos_text.UnsupportedColor | @macos_text.UnsupportedGlyph =>
      UnsupportedColorGlyph
    @macos_text.UnsupportedMultiline => UnsupportedMultiline
    @macos_text.UnsupportedInput => UnsupportedInput
    _ => Field(@text_field.MeasurementFailed)
  }
}

///|
fn validate_mac_document(
  document : @text.TextDocument,
) -> Result[Unit, MacFieldOwnerError] {
  match @macos_text.measure(document, FIELD_FONT_FAMILY, FIELD_FONT_SIZE) {
    Ok(_) => Ok(())
    Err(error) => Err(mac_text_error(error))
  }
}

///|
fn validate_field_replacement(
  field : @text_field.TextField,
  text : String,
  composition_target? : Bool = false,
) -> Result[Unit, MacFieldOwnerError] {
  let base = if composition_target {
    field.committed_document()
  } else {
    field.document()
  }
  let candidate = match base.replace_selection(text) {
    Ok(value) => value
    Err(_) => return Err(Field(@text_field.InvalidSelection))
  }
  validate_mac_document(candidate)
}

///|
fn mac_preedit_styles_supported(
  text : String,
  styles : Array[@macos.TextSessionStyle],
) -> Bool {
  if styles.length() == 0 {
    return true
  }
  if styles.length() != 1 {
    return false
  }
  let document = match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => return false
  }
  let utf16_length = document.utf16_length()
  let style = styles[0]
  style.style == 5 &&
  style.range.start() == 0 &&
  style.range.end() == utf16_length
}

///|
fn mac_apply_preedit(
  field : @text_field.TextField,
  text : String,
  fallback : String,
  cursor_utf16 : Int?,
  styles : Array[@macos.TextSessionStyle],
  replacement_range : @text.TextRange?,
) -> Result[@text_field.TextField, MacFieldOwnerError] {
  if fallback.length() != 0 {
    return Err(UnsupportedInput)
  }
  if !mac_replacement_range_supported(field, replacement_range) {
    return Err(UnsupportedReconversion)
  }
  if !mac_preedit_styles_supported(text, styles) {
    return Err(UnsupportedStyle)
  }
  if text.length() == 0 {
    return match field.cancel_composition(measure, admit) {
      Ok(value) => Ok(value)
      Err(error) => Err(Field(error))
    }
  }
  let cursor = match cursor_utf16 {
    Some(value) => value
    None => return Err(HiddenCursor)
  }
  let preedit_document = match @text.TextDocument::new(text) {
    Ok(value) => value
    Err(_) => return Err(UnsupportedInput)
  }
  if preedit_document.utf8_length() is Err(_) {
    return Err(UnsupportedInput)
  }
  let selection = match @text.TextSelection::new(cursor, cursor) {
    Ok(value) => value
    Err(_) => return Err(HiddenCursor)
  }
  match preedit_document.with_selection(selection) {
    Ok(_) => ()
    Err(_) => return Err(HiddenCursor)
  }
  match validate_field_replacement(field, text, composition_target=true) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let candidate = match
    field.update_composition(text, selection, measure, admit) {
    Ok(value) => value
    Err(error) => return Err(Field(error))
  }
  let absolute_cursor = candidate.selection().head()
  let caret = match candidate.measurement().caret_at(absolute_cursor) {
    Ok(value) => value
    Err(_) => return Err(HiddenCursor)
  }
  if !caret.is_cursor_position() {
    return Err(HiddenCursor)
  }
  match validate_mac_document(candidate.document()) {
    Ok(_) => Ok(candidate)
    Err(error) => Err(error)
  }
}

///|
fn mac_apply_commit(
  field : @text_field.TextField,
  text : String,
  replacement_range : @text.TextRange?,
) -> Result[@text_field.TextField, MacFieldOwnerError] {
  if !mac_replacement_range_supported(field, replacement_range) {
    return Err(UnsupportedReconversion)
  }
  let base = field.committed_document()
  let candidate_document = match base.replace_selection(text) {
    Ok(value) => value
    Err(_) => return Err(UnsupportedInput)
  }
  match validate_mac_document(candidate_document) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let result = if field.is_composing() {
    field.commit_composition(text, measure, admit)
  } else {
    field.replace_selection(text, measure, admit)
  }
  match result {
    Ok(value) => Ok(value)
    Err(error) => Err(Field(error))
  }
}

///|
fn mac_apply_batch(
  field : @text_field.TextField,
  owner : MacTextOwner,
  batch : @macos.EditorBatch,
  width : Double,
  height : Double,
) -> Result[MacBatchTransition, MacFieldOwnerError] {
  let mut candidate = field
  let mut next_owner = owner
  let mut commits = 0
  let mut external_edit = false
  let mut action : @text_field.TextFieldAction? = None
  for event in batch.events() {
    match event {
      @macos.Preedit(
        text~,
        fallback~,
        cursor_utf16~,
        styles~,
        replacement_range~
      ) =>
        candidate = match
          mac_apply_preedit(
            candidate, text, fallback, cursor_utf16, styles, replacement_range,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      // Empty preedit restores the saved selection in this same native
      // batch. It must be ACKed as IME cancellation, not fenced as an
      // unrelated external edit.
      @macos.Commit(text~, replacement_range~) => {
        candidate = match mac_apply_commit(candidate, text, replacement_range) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        commits += 1
      }
      @macos.Entered => next_owner = { ..next_owner, entered: true, }
      @macos.Left => {
        if candidate.is_composing() {
          candidate = match candidate.cancel_composition(measure, admit) {
            Ok(value) => value
            Err(error) => return Err(Field(error))
          }
          external_edit = true
        }
        candidate = match candidate.with_focus(false) {
          Ok(value) => value
          Err(error) => return Err(Field(error))
        }
        next_owner = owner_ended(next_owner)
      }
      @macos.Cancelled =>
        if candidate.is_composing() {
          candidate = match candidate.cancel_composition(measure, admit) {
            Ok(value) => value
            Err(error) => return Err(Field(error))
          }
        }
      // Cancelled is generated by the current IME batch. Its restored
      // committed document is ACKed below so forwarded key-up can pair.
      @macos.ForwardedPressed(key_code~, key~, modifiers~) => {
        let (pressed_owner, input) = mac_forwarded_press(
          next_owner, key_code, key, modifiers,
        )
        next_owner = pressed_owner
        match input {
          None => ()
          Some(input) =>
            match input {
              @primitives.KeyPressed(key=@primitives.Enter, ..) if candidate.is_composing() =>
                ()
              @primitives.KeyPressed(key=@primitives.Escape, ..) if candidate.is_composing() =>
                candidate = match candidate.cancel_composition(measure, admit) {
                  Ok(value) => value
                  Err(error) => return Err(Field(error))
                }
              // Escape cancellation belongs to this input sequence and is
              // acknowledged with its forwarded key-up.
              _ => {
                if candidate.is_composing() &&
                  input is @primitives.KeyPressed(..) {
                  candidate = match
                    candidate.cancel_composition(measure, admit) {
                    Ok(value) => value
                    Err(error) => return Err(Field(error))
                  }
                  external_edit = true
                }
                let before = candidate.committed_document().text()
                let (next, next_action) = match
                  route_input(candidate, input, width, height) {
                  Ok(value) => value
                  Err(error) => return Err(Field(error))
                }
                candidate = next
                if candidate.committed_document().text() != before {
                  external_edit = true
                }
                if next_action is Some(_) {
                  action = next_action
                }
              }
            }
        }
      }
      @macos.ForwardedReleased(key_code~, key=_, modifiers=_) => {
        let (released_owner, input) = mac_forwarded_release(
          next_owner, key_code,
        )
        next_owner = released_owner
        match input {
          Some(input) =>
            match route_input(candidate, input, width, height) {
              Ok(value) => {
                candidate = value.0
                if value.1 is Some(_) {
                  action = value.1
                }
              }
              Err(error) => return Err(Field(error))
            }
          None => ()
        }
      }
    }
  }
  Ok({ field: candidate, owner: next_owner, commits, external_edit, action, })
}

///|
fn mac_restore_rejected_field(
  submitted : @text_field.TextField,
  pending : @text_field.TextField,
) -> Result[@text_field.TextField, @text_field.TextFieldError] {
  let restored = match submitted.with_bounds(pending.bounds()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let restored = match restored.with_focus(pending.is_focused()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  restored.cancel_composition(measure, admit)
}

///|
fn mac_same_visible_field(
  left : @text_field.TextField,
  right : @text_field.TextField,
) -> Bool {
  left.document() == right.document() &&
  left.selection() == right.selection() &&
  left.is_focused() == right.is_focused() &&
  left.is_composing() == right.is_composing() &&
  left.marked_range() == right.marked_range() &&
  left.bounds() == right.bounds() &&
  left.scroll_offset() == right.scroll_offset() &&
  left.can_undo() == right.can_undo() &&
  left.can_redo() == right.can_redo()
}

///|
fn mac_direct_rearm_is_safe(
  ime_mode : Bool,
  has_accepted_frame : Bool,
  restored : @text_field.TextField,
  shown : @text_field.TextField,
) -> Bool {
  !ime_mode &&
  has_accepted_frame &&
  restored.is_focused() &&
  mac_same_visible_field(restored, shown)
}

///|
fn mac_ime_begin_ready(
  pending : Bool,
  field_focused : Bool,
  ime_mode : Bool,
  native_window_focused : Bool,
) -> Bool {
  pending && field_focused && ime_mode && native_window_focused
}

///|
fn mac_global_exit_requested(event : @platform.Event) -> Bool {
  event.kind() is @platform.ExitRequested
}

///|
fn mac_commit_ledger() -> MacCommitLedger {
  { accepted: 0, pending: 0, }
}

///|
fn mac_stage_commits(ledger : MacCommitLedger, count : Int) -> MacCommitLedger {
  { ..ledger, pending: ledger.pending + count, }
}

///|
fn mac_accept_commits(ledger : MacCommitLedger) -> MacCommitLedger {
  { accepted: ledger.accepted + ledger.pending, pending: 0, }
}

///|
fn mac_reject_commits(ledger : MacCommitLedger) -> MacCommitLedger {
  { ..ledger, pending: 0, }
}

///|
fn mac_caret_rect(
  field : @text_field.TextField,
) -> Result[@primitives.Rect, @text_field.TextFieldError] {
  let caret = match field.caret_rect() {
    Ok(value) => value
    Err(_) => return Err(@text_field.UnsupportedLayout)
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
      return Err(@text_field.InvalidBounds)
    }
  }
  let width = right - left
  let height = bottom - top
  if width < 1.0 ||
    height < 1.0 ||
    width > 2147483647.0 ||
    height > 2147483647.0 {
    return Err(@text_field.InvalidBounds)
  }
  match @primitives.Rect::new(left, top, width, height) {
    Ok(value) => Ok(value)
    Err(_) => Err(@text_field.InvalidBounds)
  }
}

///|
enum MacFieldFrameDecision {
  Accepted
  BusyPending
  RecoverPending
  RejectPending
} derive(Eq)

///|
fn classify_field_frame(
  result : Result[Unit, @diagnostics.FrameworkError],
) -> MacFieldFrameDecision {
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
fn mac_begin_owner(
  host : @macos.Host,
  window : @platform.WindowId,
  field : @text_field.TextField,
) -> Result[MacTextOwner, @diagnostics.FrameworkError] {
  match host.set_direct_keyboard_text(window, false) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let host_epoch = match host.generation() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let caret = match mac_caret_rect(field) {
    Ok(value) => value
    Err(_) =>
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "mac_caret_rect",
        ),
      )
  }
  match
    host.begin_text_session(
      window,
      field.committed_document(),
      caret,
      owner_revision=field.revision().to_int64(),
    ) {
    Ok(epoch) => Ok(mac_text_owner(window, host_epoch, epoch, field.revision()))
    Err(error) => Err(error)
  }
}

///|
fn mac_sync_owner(
  host : @macos.Host,
  field : @text_field.TextField,
  owner : MacTextOwner,
  external_edit : Bool,
  acknowledged_sequence : Int64?,
) -> Result[MacTextOwner, @diagnostics.FrameworkError] {
  let caret = match mac_caret_rect(field) {
    Ok(value) => value
    Err(_) =>
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.InvalidInput,
          "mac_caret_rect",
        ),
      )
  }
  let epoch = match
    host.update_text_session(
      owner.window,
      owner.epoch,
      field.committed_document(),
      caret,
      external_edit~,
      acknowledged_sequence~,
      owner_revision=field.revision().to_int64(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if external_edit {
    if epoch == owner.epoch {
      return Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.NativeFailure,
          "mac_sync_owner_external_epoch",
        ),
      )
    }
    Ok(owner_rearmed(owner, epoch, field.revision()))
  } else if epoch != owner.epoch {
    Ok(owner_rearmed(owner, epoch, field.revision()))
  } else {
    match acknowledged_sequence {
      Some(sequence) => Ok(owner_ack(owner, sequence, field.revision()))
      None => Ok({ ..owner, revision: field.revision(), })
    }
  }
}

///|
// Fence stale native callbacks before rollback or an external edit. The
// replacement session receives its mirror only after that state is presented.
fn mac_fence_owner(
  host : @macos.Host,
  owner : MacTextOwner,
  revision : Int,
) -> Result[MacTextOwner, @diagnostics.FrameworkError] {
  match host.cancel_text_session(owner.window, owner.epoch) {
    Ok(epoch) => Ok(owner_rearmed(owner, epoch, revision))
    Err(error) => Err(error)
  }
}

///|
fn mac_target_current(
  owner : MacTextOwner,
  batch : @macos.EditorBatch,
  field : @text_field.TextField,
  geometry_revision_pending? : Bool = false,
) -> Bool {
  mac_validate_batch_target(owner, batch, field, geometry_revision_pending~)
  is Ok(_)
}

///|
fn mac_validate_batch_target(
  owner : MacTextOwner,
  batch : @macos.EditorBatch,
  field : @text_field.TextField,
  geometry_revision_pending? : Bool = false,
) -> Result[Unit, MacFieldOwnerError] {
  let target = batch.target()
  if !owner.active {
    return Err(StaleEpoch)
  }
  if target.window() != owner.window {
    return Err(StaleWindow)
  }
  if target.host_epoch() != owner.host_epoch {
    return Err(StaleHost)
  }
  if target.epoch() != owner.epoch {
    return Err(StaleEpoch)
  }
  if target.sequence() <= owner.last_sequence {
    return Err(ReplayedOrOldSequence)
  }
  if !owner_batch_current(
      owner,
      target.window(),
      target.host_epoch(),
      target.epoch(),
      target.sequence(),
      target.owner_revision(),
      field.revision(),
      geometry_revision_pending~,
    ) {
    return Err(RevisionMismatch)
  }
  let mut has_entered = false
  for event in batch.events() {
    if event is @macos.Entered {
      has_entered = true
    }
  }
  if !owner.entered && !has_entered {
    return Err(StaleEpoch)
  }
  Ok(())
}

///|
fn mac_owner_error_label(error : MacFieldOwnerError) -> String {
  match error {
    StaleWindow => "StaleWindow"
    StaleHost => "StaleHost"
    StaleEpoch => "StaleEpoch"
    ReplayedOrOldSequence => "ReplayedOrOldSequence"
    RevisionMismatch => "RevisionMismatch"
    UnsupportedReconversion => "UnsupportedReconversion"
    UnsupportedStyle => "UnsupportedStyle"
    HiddenCursor => "HiddenCursor"
    UnsupportedInput => "UnsupportedInput"
    UnsupportedMultiline => "UnsupportedMultiline"
    UnsupportedBidi => "UnsupportedBidi"
    UnsupportedColorGlyph => "UnsupportedColorGlyph"
    Field(error) => mac_text_field_error_label(error)
  }
}

///|
fn mac_text_field_error_label(error : @text_field.TextFieldError) -> String {
  match error {
    @text_field.InvalidFontSize => "InvalidFontSize"
    @text_field.InvalidBounds => "InvalidBounds"
    @text_field.MalformedText => "MalformedText"
    @text_field.ForbiddenInput => "ForbiddenInput"
    @text_field.TextTooLarge => "TextTooLarge"
    @text_field.UnsupportedLayout => "UnsupportedLayout"
    @text_field.InvalidSelection => "InvalidSelection"
    @text_field.MeasurementFailed => "MeasurementFailed"
    @text_field.AdmissionFailed => "AdmissionFailed"
    @text_field.HitTestFailed => "HitTestFailed"
    @text_field.InvalidHitResult => "InvalidHitResult"
    @text_field.RevisionExhausted => "RevisionExhausted"
    @text_field.CompositionActive => "CompositionActive"
    @text_field.NoComposition => "NoComposition"
  }
}

///|
fn owner_ack(
  owner : MacTextOwner,
  sequence : Int64,
  revision : Int,
) -> MacTextOwner {
  { ..owner, last_sequence: sequence, revision, }
}

///|
fn owner_rearmed(
  owner : MacTextOwner,
  epoch : Int,
  revision : Int,
) -> MacTextOwner {
  {
    ..owner,
    epoch,
    last_sequence: 0L,
    revision,
    // cancel/update has already succeeded and returned this replacement epoch.
    entered: true,
    forwarded_keys: [],
  }
}

///|
fn owner_ended(owner : MacTextOwner) -> MacTextOwner {
  { ..owner, active: false, entered: false, forwarded_keys: [], }
}

///|
// Only native command/navigation meaning crosses from a physical key record.
// AppKit Commit/Preedit is the sole source of inserted text.
fn mac_editor_command_key(
  key : @primitives.Key?,
  modifiers : @primitives.Modifiers,
) -> @primitives.Key? {
  if modifiers.meta() {
    if modifiers.alt() || modifiers.control() {
      return None
    }
    match key {
      Some(@primitives.Character("a")) | Some(@primitives.Character("A")) =>
        return Some(@primitives.Character("a"))
      Some(@primitives.Character("c")) | Some(@primitives.Character("C")) =>
        return Some(@primitives.Character("c"))
      Some(@primitives.Character("x")) | Some(@primitives.Character("X")) =>
        return Some(@primitives.Character("x"))
      Some(@primitives.Character("v")) | Some(@primitives.Character("V")) =>
        return Some(@primitives.Character("v"))
      Some(@primitives.Character("z")) | Some(@primitives.Character("Z")) =>
        return Some(@primitives.Character("z"))
      _ => return None
    }
  }
  if modifiers.control() || modifiers.alt() {
    return None
  }
  match key {
    Some(@primitives.ArrowLeft)
    | Some(@primitives.ArrowRight)
    | Some(@primitives.Home)
    | Some(@primitives.End)
    | Some(@primitives.Backspace)
    | Some(@primitives.Delete)
    | Some(@primitives.Enter)
    | Some(@primitives.Escape) => key
    _ => None
  }
}

///|
fn forwarded_key_index(keys : Array[ForwardedKey], key_code : Int) -> Int? {
  for index, item in keys {
    if item.key_code == key_code {
      return Some(index)
    }
  }
  None
}

///|
fn remove_forwarded_key(
  keys : Array[ForwardedKey],
  key_code : Int,
) -> Array[ForwardedKey] {
  let remaining = []
  for item in keys {
    if item.key_code != key_code {
      remaining.push(item)
    }
  }
  remaining
}

///|
fn mac_forwarded_press(
  owner : MacTextOwner,
  key_code : Int,
  key : @primitives.Key?,
  modifiers : @primitives.Modifiers,
) -> (MacTextOwner, @primitives.InputEvent?) {
  let repeat = forwarded_key_index(owner.forwarded_keys, key_code) is Some(_)
  match mac_editor_command_key(key, modifiers) {
    None => (owner, None)
    Some(key) => {
      let keys = if repeat {
        owner.forwarded_keys
      } else {
        let expanded = []
        for saved in owner.forwarded_keys {
          expanded.push(saved)
        }
        expanded.push({ key_code, key, modifiers, })
        expanded
      }
      (
        { ..owner, forwarded_keys: keys, },
        Some(@primitives.KeyPressed(key~, modifiers~, repeat~)),
      )
    }
  }
}

///|
fn mac_forwarded_release(
  owner : MacTextOwner,
  key_code : Int,
) -> (MacTextOwner, @primitives.InputEvent?) {
  match forwarded_key_index(owner.forwarded_keys, key_code) {
    None => (owner, None)
    Some(index) => {
      let saved = owner.forwarded_keys[index]
      (
        {
          ..owner,
          forwarded_keys: remove_forwarded_key(owner.forwarded_keys, key_code),
        },
        Some(@primitives.KeyReleased(key=saved.key, modifiers=saved.modifiers)),
      )
    }
  }
}

///|
fn mac_platform_input_allowed(
  input : @primitives.InputEvent,
  ime_session_active : Bool,
) -> Bool {
  if !ime_session_active {
    return true
  }
  match input {
    // Active IME sessions route every physical key through the batch FIFO.
    // This is a defensive drop for accidental duplicate platform records.
    @primitives.TextInput(..)
    | @primitives.KeyPressed(..)
    | @primitives.KeyReleased(..) => false
    _ => true
  }
}
