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
