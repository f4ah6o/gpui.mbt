///|
priv struct OwnerSequence {
  next : UInt64
  exhausted : Bool
}

///|
let accessibility_owner_sequence : Ref[OwnerSequence] = Ref({
  next: 1UL,
  exhausted: false,
})

///|
fn next_owner_id() -> UInt64? {
  let (next_sequence, owner) = advance_owner_sequence(
    accessibility_owner_sequence.val,
  )
  accessibility_owner_sequence.val = next_sequence
  owner
}

///|
fn advance_owner_sequence(sequence : OwnerSequence) -> (OwnerSequence, UInt64?) {
  if sequence.exhausted {
    return (sequence, None)
  }
  let owner = sequence.next
  if owner == MAX_UINT64 {
    ({ next: owner, exhausted: true, }, Some(owner))
  } else {
    ({ next: owner + 1UL, exhausted: false, }, Some(owner))
  }
}
