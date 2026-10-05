# Cooperative asynchronous capabilities

This is the portable semantic foundation of open packet 0016. It supplies
resumable work and in-process cancellation; it does **not** implement a wire
async driver, OS threads, promises, native/browser transports, or disconnect
protocols. Existing `TypedCapability` calls stay synchronous and never spin
until cooperative work completes.

## Define once, drive explicitly

`AsyncCapability[I, O]::new` takes the same `Descriptor`, decoder, encoder,
availability, policy, and typed domain validators used at the synchronous
semantic boundary, plus two explicit callbacks:

- `snapshot_input: (I) -> Result[I, FrameworkError]` captures owned input.
- `start: (I) -> Result[() -> WorkStep[O], FrameworkError]` creates a resumable
  operation. Its returned closure performs bounded work and returns `Pending`,
  `Complete(output)`, or `Fail(error)`.

`begin(origin, input)` authorizes, snapshots, and validates the input before
returning `Invocation[O]`. It does not run the factory or domain work. The GUI
binding has `begin(input)` and `is_enabled()` and uses the same operation with
origin `Gui`. `register_async` binds existing typed and GUI handles and queued
invocations to the same registry/owner lifetime as synchronous capabilities.
Registry ID and external-name collisions are shared across execution modes.

Each `poll()` executes at most **one** factory or work-step callback. The first
successful poll creates the closure and returns `Pending`; subsequent polls do
one work step each. A caller can round-robin multiple jobs without one poll
secretly driving another turn. Availability/policy/validation callbacks are
additional bounded semantic checks, not work steps. The application must keep
all callbacks bounded and nonblocking; this API cannot preempt an arbitrary
closure or prove its time/memory bound. There is no automatic executor, total
step limit, fairness guarantee, or background progress. A job that never
completes must be cancelled by its caller.

A real operation can, for example, validate/accumulate one item per work step,
commit once after the final item, then produce its result. The tests exercise
incremental state changes rather than a delay before a synchronous handler.

## Input and output ownership

`snapshot_input` is mandatory, has no identity default, and is never replaced by
an encode/decode round-trip. Its author must deep-copy every mutable part that
could alias caller or application storage, and not publish fresh aliases to the
snapshot. This is an application contract, not something generics can prove.
Immutable inputs may explicitly return themselves. The same snapshot callback
runs for GUI/direct inputs and decoded registry/adapter inputs: a decoder may
return application-owned nested mutable arrays even if its transport input was
already copied. Mutations to the original input after `begin` and between polls
must not alter admitted work. Applications must enforce domain-specific input
size limits in the snapshot/validation callback; arbitrary typed `I` has no
generic byte-size bound.

Erased calls own and schema-check the transport `Value`, authorize before the
decoder, normalize conversion failures, then snapshot and validate decoded `I`.
They use the same factory and steps, typed output validator, and boundary
encoder/schema validation. Encoded transport output is copied before delivery
so a mutable encoder-owned array cannot change a delivered result.

`Ready(O)` and `Failed(error)` are consumed by the poll that returns them; later
polls return `Consumed`. The framework retains no typed `O` or terminal error
for replay. Typed output ownership is ordinary application-defined ownership:
if the application returns a mutable reference it also retains, the caller sees
that reference. The framework promises no deep output snapshot for typed calls.

## Lifecycle and reentrancy

An optional `InvocationScope` can be passed to typed/GUI/registry begin. Its
`cancel()` is monotonic, cannot be reset, and may cancel multiple pending jobs.
Admission observes it after every callback, including availability, policy,
decode, snapshot, and input validation. Cancelled admission returns
`HostStopping`, with owner-stale errors taking precedence. Cancelling an
individual invocation does not cancel its siblings, and scope cancellation
after terminal delivery does not change an already consumed outcome.

Invocation `cancel()` returns `Cancelled`, `AlreadyCancelled`, or `TooLate`. Cancellation
before the first poll prevents the factory. Cancellation while a callback is
running cannot interrupt its body, but blocks later steps, output validators,
encoding, and disclosure. Cancellation after an effect commits keeps the effect
and rejects late completion. A step that commits and returns `Pending` can be
cancelled before its result turn. Once `Ready`/`Failed` is delivered,
cancellation is `TooLate`. No rollback or exactly-once guarantee is implied.

An invocation locks before any policy/factory/step callback. A reentrant poll of
that invocation returns `Busy`, even if a callback is simultaneously revoking
it. The outer poll observes revocation before disclosure; later polls do no
work. Reentrant cancellation is safe and repeated cancellation is harmless.
Application callbacks can still call other jobs; the framework does not drive
or promise fairness among that application-created recursion.

Owner stop or registry teardown invalidates queued, running, completed, and
cancelled handles immediately. A poll observing the revocation returns
`Failed(StaleHandle)` in preference to any late success or domain error,
including a previously consumed or cancelled job. Owner adoption applies to
jobs created before registration/adoption. An adopted owner in `New` rejects
polls with `AppNotRunning`; starting the app enables fresh admission. A rejected
poll is terminal, so an old failed job is not resurrected by starting the app.

Policy/exposure are rechecked before every resumed work step and before result
or error disclosure, with lifetime checks after callbacks. Availability is
checked at admission and just before first factory execution. It is not rerun
after work starts: a successful commit is allowed to make its own operation
unavailable without hiding its successful result. Domain errors are suppressed
when cancellation, lifetime revocation, or policy revocation takes precedence.

## Retention and hosting

A typed invocation holds at most one captured input/factory or resumable work
closure and one fixed callback bundle. `cancel`, terminal consumption, and a
poll observing lifecycle failure clear these references. Only shared lightweight
lifetime metadata and state flags remain in a terminal typed handle. Stop
invalidates a caller-held job immediately, but does not synchronously visit or
reclaim every caller-held closure; it is cleared when that job is next polled,
cancelled, or dropped. The registry retains registrations, not a global queue
of typed jobs. The application controls the number of direct jobs it retains.

The optional in-process adapter supplies `cooperative_inventory`, `begin_tool`,
`begin_resource`, and `CooperativeCall::poll/cancel`. It retains at most 128
admission/active slots, reserving before callbacks to bound reentrant admission.
Cancelling or consuming a call releases its slot. Closing the adapter cancels
all admitted jobs; observing an owner stop does the same. Begin callbacks are
synchronous: each reserved slot has a cancellation scope, so close during
admission prevents all later application callbacks and rejects the new call
before its factory can run. No cooperative results or request IDs are cached, and no idempotency or
retry suppression is inferred from the descriptor. A new begin is a new call.

The semantic registry's descriptor/manifest discovery remains complete.
`Registry::is_async(id)` identifies execution mode. The legacy synchronous
adapter inventory omits cooperative entries, so the current `ProtocolServer`
and stdio host never advertise an async operation they cannot drive. Their
existing synchronous calls fail explicitly rather than block on async work.
The separate cooperative inventory derives from the same registered
Descriptors, with unit-input queries represented as resources. Wire driving,
wire cancellation/disconnect, native/browser endpoint parity and retained CI
lifecycle artifacts remain open in 0016 and parent 0013.

## Local evidence

The cooperative suite adds 26 black-box capability groups, a white-box callback
retention group, and seven in-process adapter groups. The occurrence-index
matrices cancel or stop at every callback occurrence, testing both successful
and failed callback returns across GUI/direct/local/remote origins. They assert
that no later callback or result escapes; nested caller/decoder aliases,
transport input/output aliases, same-scope sibling isolation, reentrant polls,
128-slot admission bounds, and commit-before-cancel effects are covered.

On the pinned `0.10.14+7d59c7ec9` toolchain, local validation passed:

- formatter check and all-target check with warnings denied;
- full portable module tests: 219/219 each on JS, Wasm and Wasm GC;
- targeted native tests: core 9/9, capability 67/67, MCP 56/56;
- real Node stdio regression 4/4 and compiled inventory drift check;
- Python contracts 60/60 and contract-document validation.

Official turtles 0.3.0 parser discovery, using unchanged five-operator full
package scope configs, found 358 capability and 294 MCP mutations without
parser skips. This is **discovery only**, not mutation execution or ratchet
approval. Full native GUI, browser endpoint parity, hosted CI, and semantic
mutation execution/review are separate gates, not claimed by these local runs.
