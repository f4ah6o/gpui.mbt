///|
extern "C" fn next_owner_id_native() -> UInt64 = "gpui_accessibility_next_owner_id"

///|
fn next_owner_id() -> UInt64? {
  let owner = next_owner_id_native()
  if owner == 0UL {
    None
  } else {
    Some(owner)
  }
}
