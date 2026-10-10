///|
fn call(
  _op : Int,
  _token : Int64,
  _x : Double,
  _y : Double,
  _bytes : Bytes,
  _length : Int,
) -> Int {
  9
}

///|
fn integer(_field : Int) -> Int64 {
  0
}

///|
fn number(_field : Int) -> Double {
  0.0
}

///|
fn accessibility_publish(
  _window : Int64,
  _binding : Int64,
  _payload : Bytes,
  _length : Int,
  _output : FixedArray[Int64],
) -> Int {
  9
}

///|
fn accessibility_revoke(_window : Int64, _binding : Int64) -> Int {
  9
}

///|
fn accessibility_take_request(
  _window : Int64,
  _output : FixedArray[Int64],
) -> Int {
  9
}
