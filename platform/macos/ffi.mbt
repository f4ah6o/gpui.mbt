///|
#borrow(bytes)
extern "C" fn call(
  op : Int,
  token : Int64,
  x : Double,
  y : Double,
  bytes : Bytes,
  length : Int,
) -> Int = "gpui_call"

///|
extern "C" fn integer(field : Int) -> Int64 = "gpui_integer"

///|
extern "C" fn number(field : Int) -> Double = "gpui_number"

///|
#borrow(metrics)
extern "C" fn frame_metrics(
  window : Int64,
  metrics : FixedArray[Double],
) -> Int = "gpui_macos_frame_metrics"

///|
#borrow(output)
extern "C" fn frame_copy(
  window : Int64,
  output : FixedArray[Byte],
  capacity : Int,
) -> Int = "gpui_macos_frame_copy"

///|
extern "C" fn test_post_click(window : Int64, x : Double, y : Double) -> Int = "gpui_macos_test_post_click"

///|
extern "C" fn test_post_escape(window : Int64) -> Int = "gpui_macos_test_post_escape"
