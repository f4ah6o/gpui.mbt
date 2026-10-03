///|
/// Invalid diagnostic sink capacity.
pub(all) enum SinkConfigError {
  CapacityOutOfRange(Int)
}

///|
/// One recorded error. The sink preserves chronological insertion order and
/// does not add timestamps or thread-dependent metadata.
pub struct Diagnostic {
  priv error : FrameworkError
}

///|
pub fn Diagnostic::error(self : Diagnostic) -> FrameworkError {
  self.error
}

///|
/// Bounded FIFO diagnostic sink. A sink has one logical owner; callers
/// serialize writes on that owner's event loop.
pub struct DiagnosticSink {
  priv entries : Array[Diagnostic?]
  priv mut oldest : Int
  priv mut length : Int
  priv counts : Map[String, UInt64]
  priv mut total : UInt64
  priv mut dropped : UInt64
}

///|
/// Create a sink with capacity from 1 through 256 records.
pub fn DiagnosticSink::new(
  capacity : Int,
) -> Result[DiagnosticSink, SinkConfigError] {
  if capacity < 1 || capacity > 256 {
    Err(SinkConfigError::CapacityOutOfRange(capacity))
  } else {
    let entries : Array[Diagnostic?] = Array::make(capacity, None)
    let counts : Map[String, UInt64] = Map([], capacity=20)
    Ok({ entries, oldest: 0, length: 0, counts, total: 0, dropped: 0, })
  }
}

///|
/// Record an error, evicting the oldest record when the sink is full.
/// Per-code and total counters include evicted records and saturate at UInt64 max.
pub fn DiagnosticSink::record(
  self : DiagnosticSink,
  error : FrameworkError,
) -> Unit {
  let capacity = self.entries.length()
  if self.length < capacity {
    let index = (self.oldest + self.length) % capacity
    self.entries[index] = Some(Diagnostic::{ error, })
    self.length += 1
  } else {
    self.entries[self.oldest] = Some(Diagnostic::{ error, })
    self.oldest = (self.oldest + 1) % capacity
    self.dropped = increment_saturated(self.dropped)
  }
  let code_label = error.code().label()
  let previous_count = self.counts.get_or_default(code_label, 0)
  self.counts[code_label] = increment_saturated(previous_count)
  self.total = increment_saturated(self.total)
}

///|
/// Return a detached snapshot ordered oldest to newest.
pub fn DiagnosticSink::snapshot(self : DiagnosticSink) -> Array[Diagnostic] {
  let result : Array[Diagnostic] = []
  let capacity = self.entries.length()
  for offset in 0..<self.length {
    let index = (self.oldest + offset) % capacity
    match self.entries.get(index) {
      Some(Some(diagnostic)) => result.push(diagnostic)
      _ => ()
    }
  }
  result
}

///|
/// Return the lifetime count for one error code, including evicted records.
pub fn DiagnosticSink::count(self : DiagnosticSink, code : ErrorCode) -> UInt64 {
  self.counts.get_or_default(code.label(), 0)
}

///|
pub fn DiagnosticSink::total_count(self : DiagnosticSink) -> UInt64 {
  self.total
}

///|
/// Number of older records evicted to keep the sink within its capacity.
pub fn DiagnosticSink::dropped_count(self : DiagnosticSink) -> UInt64 {
  self.dropped
}

///|
fn increment_saturated(value : UInt64) -> UInt64 {
  let max_uint64 : UInt64 = 0xffff_ffff_ffff_ffff
  if value == max_uint64 {
    value
  } else {
    value + 1
  }
}
