///|
/// A copied macOS projection for one custom Button AX element.
///
/// This carries attributes only. The MoonBit owner retains the semantic
/// `NodeId` and `ActionRequest`; AppKit receives a revocable transport token.
pub struct ButtonAccessibilitySnapshot {
  name : String
  bounds : @primitives.Rect
  enabled : Bool
  loading : Bool
  focused : Bool
  activations : Int
}

///|
pub fn ButtonAccessibilitySnapshot::new(
  name : String,
  bounds : @primitives.Rect,
  enabled : Bool,
  loading : Bool,
  focused : Bool,
  activations : Int,
) -> ButtonAccessibilitySnapshot {
  { name, bounds, enabled, loading, focused, activations, }
}

///|
struct MacAXButtonPayload {
  version : Int
  role : String
  name : String
  left : Double
  top : Double
  width : Double
  height : Double
  enabled : Bool
  loading : Bool
  focused : Bool
  activations : Int
  actions : Array[String]
} derive(ToJson)

///|
pub extend MacAXButtonPayload with ToJson::{to_json}

///|
fn macos_ax_payload(snapshot : ButtonAccessibilitySnapshot) -> Bytes {
  let size = snapshot.bounds.size()
  let value = MacAXButtonPayload::{
    version: 1,
    role: "button",
    name: snapshot.name,
    left: snapshot.bounds.left(),
    top: snapshot.bounds.top(),
    width: size.width(),
    height: size.height(),
    enabled: snapshot.enabled,
    loading: snapshot.loading,
    focused: snapshot.focused,
    activations: snapshot.activations,
    actions: ["Invoke"],
  }
  @utf8.encode(@json.to_json(value).stringify())
}

///|
/// Publish the copied Button attributes to AppKit and return their current
/// revocable transport binding. Pass zero to create a new binding; pass the
/// existing binding to update attributes for the same live semantic node.
pub fn Host::publish_button_accessibility(
  self : Host,
  window : @platform.WindowId,
  existing_binding : Int64,
  snapshot : ButtonAccessibilitySnapshot,
) -> Result[Int64, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let bytes = macos_ax_payload(snapshot)
  let output : FixedArray[Int64] = FixedArray::make(1, Int64::from_int(0))
  let result = accessibility_publish(
    window.value(),
    existing_binding,
    bytes,
    bytes.length(),
    output,
  )
  match status(result, "publish_button_accessibility") {
    Err(error) => Err(error)
    Ok(_) =>
      if output[0] > 0 {
        Ok(output[0])
      } else {
        Err(error(@diagnostics.NativeFailure, "publish_button_accessibility"))
      }
  }
}

///|
/// Revoke the current native Button element and discard requests queued for its
/// binding. A zero binding revokes any current element for this window.
pub fn Host::revoke_button_accessibility(
  self : Host,
  window : @platform.WindowId,
  binding : Int64,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  status(
    accessibility_revoke(window.value(), binding),
    "revoke_button_accessibility",
  )
}

///|
/// Take one native semantic request. The result is only the opaque transport
/// token; the caller must map it to its retained full NodeId request and ask
/// the live fixture to validate and dispatch that request immediately.
pub fn Host::take_button_accessibility_request(
  self : Host,
  window : @platform.WindowId,
) -> Result[Int64?, @diagnostics.FrameworkError] {
  match self.check() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let output : FixedArray[Int64] = FixedArray::make(1, Int64::from_int(0))
  match accessibility_take_request(window.value(), output) {
    0 => Ok(None)
    1 =>
      if output[0] > 0 {
        Ok(Some(output[0]))
      } else {
        Err(
          error(@diagnostics.NativeFailure, "take_button_accessibility_request"),
        )
      }
    result =>
      match status(result, "take_button_accessibility_request") {
        Err(error) => Err(error)
        Ok(_) =>
          Err(
            error(
              @diagnostics.NativeFailure,
              "take_button_accessibility_request",
            ),
          )
      }
  }
}
