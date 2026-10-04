## Implementation progress

Implemented in PR #12:

- three semantic lanes: GUI binding, direct typed API, and MCP adapter
- state/result/notification equivalence checks for one write capability
- MCP resource read-after-direct-mutation coverage
- invalid-input, remote-policy-denial, released-owner, and adapter-close tests
- deterministic inventory/manifest registration-order tests
- QuickCheck direct-vs-MCP semantic operation sequence parity

Still required before this packet is complete:

- broader generated schema round trips and reference operations beyond the one-document CRUD fixture
- host cancellation/disconnect timing matrix for a genuinely long-running operation
- rendered browser host smoke for the GUI/direct/MCP redraw path
- native endpoint topology and lifecycle smoke gates
- turtles mutation gate once the capability API stabilizes

## Normalized CRUD and request-lifecycle update — 2026-10-04

The test suite now compares a normalized trace for create, rename, and delete
from isolated GUI, direct, and MCP fixtures. It records semantic operation IDs,
initial/final state, results, entity revisions, notification count, and the
committed side-effect log; all three lanes produce the same trace. Availability
failure before document creation is also compared across all lanes, while
domain validation and erased input conversion have separate no-side-effect
checks.

Request-ID conformance additionally covers reauthorization of cached successes
before result disclosure, changed-policy and torn-down-registry rejection,
reentrant duplicate rejection, conflicting input, adapter close after a handler
may have committed, and oversized-result tombstones. The browser proof fixture
routes an External counter write through an in-process MCP adapter and uses the
same observable state as the rendered UI.

Long-running host cancellation/disconnect timing, broader generated schema
round trips, native endpoint topology, and a reviewed mutation baseline remain
pending. The browser fixture demonstrates in-process dispatch, not protocol
wire parity or MCP transport cancellation.

# GUI / API / MCP equivalence conformance suite

Status: open
Parent: [0012-semantic-capability-model.md](0012-semantic-capability-model.md)
Depends on: [0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md)
Related: [0003-testing-pbt-mutation-and-visual-validation.md](0003-testing-pbt-mutation-and-visual-validation.md)
Updated: 2026-10-04
Child: [0016-mcp-endpoint-lifecycle-conformance.md](0016-mcp-endpoint-lifecycle-conformance.md)

## Current-head acceptance triage — 2026-10-04

Basis: merged main HEAD `1dea499e34a36a64927791c94f35965a91c305a2`; PR #13
head `d70b1255aa5dc1eaaea04a67a9ea748d29317cbd`.

- [x] A normalized CRUD trace compares create, rename, and delete through GUI,
  direct, and MCP lanes, including state, result, revisions, notifications,
  and committed side-effect records.
- [x] Availability, invalid input, policy denial, stale owners, duplicate and
  conflicting request IDs, reentrant calls, teardown ambiguity, and oversized
  outcome behavior have negative/no-reexecution coverage.
- [x] A seeded direct-versus-MCP operation-sequence property and deterministic
  generated inventory/schema tests pass in the hosted
  [contracts/core run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649283).
- [x] Real Chromium smoke verifies GUI/direct/MCP mutations reach the same
  app-owned value and repaint the canvas; see the hosted
  [browser run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649282).
- [ ] Broad generated schema round-trips and reference operations beyond the
  current fixtures are incomplete.
- [ ] Cancellation/disconnect timing for a genuinely long-running request and
  browser/native endpoint topology smoke are split to packet 0016; no wire
  transport cancellation is proven by the in-process adapter tests.
- [ ] A reviewed capability-layer mutation baseline is still required after
  the API and adapter behavior settle.

The browser redraw gate is complete; the transport lifecycle, schema breadth,
and mutation gates keep this conformance packet open.

## Goal

Make the claim "GUI, API, and MCP are equivalent" measurable.

The project must not consider parity complete because all three surfaces happen
to exist. Conformance tests must prove that equivalent semantic operations share
the same validation, policy, domain execution, state transition, notifications,
side effects, result contract, and errors.

The core oracle is a normalized semantic trace, not pixels or transport bytes.

## Definition of equivalence

For a declared semantic capability, equivalent entry paths should agree on all
domain-observable behavior that is intended to be shared.

For a state-changing command, compare at least:

- resolved semantic capability ID
- accepted/rejected input
- availability decision
- authorization/policy decision at the semantic boundary
- domain validation outcome
- state before and after
- entity revisions where public/observable
- application notification sequence
- committed side-effect record where testable
- returned semantic result
- returned semantic/domain error
- lifecycle behavior when owners are released

Transport-specific framing, request IDs, connection metadata, GUI animation,
focus ring rendering, and pixel output are not part of semantic equality unless
a specific capability contract says otherwise.

## Normalized trace

Add a test-only semantic trace representation that can record externally
observable capability execution without exposing implementation internals to
production APIs.

Conceptually:

```text
InvocationStarted(document.save)
InputAccepted(...)
PolicyAccepted
DomainExecutionStarted
StateChanged(...)
Notification(...)
DomainExecutionCompleted
Result(...)
```

The exact events may differ, but the trace must be deterministic and normalized
so different entry paths can be compared.

Do not make tests depend on MCP wire formatting or renderer timing when the
property under test is domain parity.

## Three invocation lanes

A reference fixture must support:

### GUI lane

Invoke the capability through its semantic GUI binding.

Prefer direct framework event/action dispatch for deterministic headless tests.
Use real pointer/keyboard E2E only when the behavior being tested is genuinely
about input routing.

### Direct API lane

Invoke the capability through the typed capability API.

### MCP lane

Invoke through the MCP adapter using generated external schema/name metadata,
then normalize the protocol result back to the semantic result/error model.

The lanes must start from equivalent application state and use isolated fixture
instances unless a test intentionally exercises sequential interoperability.

## Reference scenarios

The initial suite should include at least:

- read current document/state
- edit a normal scalar/string field
- create an item
- rename an item
- delete an item
- command unavailable because current state does not permit it
- invalid input
- permission denied
- owning entity released before invocation
- domain operation returns an error
- MCP client disconnect/cancellation around a long-running test operation

These should use a small repository-owned fixture application rather than a
large production app.

## Sequence/model-based testing

Single calls are insufficient. Extend the 0003 model-based PBT strategy to
generate semantic operation sequences.

Example generated operations:

```text
create
rename
read
select
rename
delete
read
```

Run equivalent sequences through direct API and another semantic entry lane,
then compare normalized model state and trace invariants.

Useful properties:

- equivalent accepted sequences converge to equivalent application state
- rejected operations do not mutate semantic state
- notification ordering is deterministic
- released entities never become callable again
- GUI and MCP mutations are immediately visible to subsequent direct reads
- direct/API mutations are immediately visible to GUI-bound queries
- external name/schema generation does not depend on registration order

Shrunk counterexamples should become permanent regression tests when useful.

## Retry and duplicate tests

Remote clients introduce ambiguity that GUI callbacks normally do not.

Test explicitly:

- duplicate invocation of an idempotent command
- duplicate invocation of a non-idempotent command
- adapter receives the same request twice where de-duplication is enabled
- transport failure before domain execution
- transport failure after domain commit
- cancellation before execution
- cancellation during execution
- cancellation after commit

The adapter must never claim exactly-once execution unless an implemented,
tested contract provides it.

A non-idempotent command must not be silently retried by the framework merely to
make an MCP request appear successful.

## Permission tests

The same domain operation may have different entry-path trust requirements.

Parity therefore does not mean bypassing adapter policy.

Test:

- GUI allowed, remote MCP denied by policy
- local automation allowed, remote automation denied
- capability omitted from external inventory
- capability visible but temporarily unavailable
- sensitive output rejected/redacted by explicit policy

After entry-path policy accepts an invocation, all lanes must converge on the
same domain validation and execution implementation.

## Schema conformance

For every externally exposed capability:

- generated input schema accepts all supported externally representable valid
  values used by the semantic contract
- generated schema rejects structurally invalid values before domain execution
  where possible
- conversion preserves supported values without undocumented coercion
- output conversion round-trips the supported semantic value domain
- unsupported values fail explicitly
- schema output is deterministic

Use QuickCheck generators for the supported transport-value subset.

## State/notification oracle

Do not compare only final state.

Two implementations can reach the same final value while emitting different
notifications or executing a side effect twice.

Where applicable compare:

- state snapshot
- revision/version changes
- notification order/count
- side-effect fake/recording backend
- result/error

Provide test doubles for filesystem/network-like side effects rather than using
real external services in semantic conformance tests.

## GUI redraw integration

Add an integration test proving that a mutation entered through direct API or
MCP causes a GUI-bound view to observe the new state through ordinary gpui.mbt
reactivity.

This should verify state-to-view invalidation, not pixel aesthetics.

Visual output remains covered by the renderer/golden/vlmkit layers in 0003.

## Browser/native coverage

Most parity tests should run headlessly and on every supported MoonBit target
where practical.

Add only thin host E2E checks to prove adapter wiring in browser/native
topologies. Do not duplicate the entire semantic suite for every renderer if the
same portable capability layer is used.

For browser hosts, respect the browser privilege boundary described in 0009.
For native hosts, keep protocol/transport lifecycle tests separate from semantic
parity tests.

## Mutation-testing expectations

Once the capability layer stabilizes, add turtles mutation coverage for code
that can cause false parity, especially:

- external-name resolution
- policy checks
- argument conversion
- schema required/optional handling
- invocation routing
- error mapping
- notification dispatch
- idempotency/retry guards

A surviving mutant that allows the API/MCP path to bypass semantic validation is
release-significant.

## CI gates

Introduce gates incrementally:

### Gate 1: manifest determinism

- capability manifest snapshot
- generated name/schema snapshots
- no registration-order drift

### Gate 2: headless lane parity

- GUI semantic binding vs direct API
- direct API vs MCP dispatch
- state + trace comparison

### Gate 3: model-based sequences

- deterministic seeds
- shrinking enabled
- retained regression witnesses

### Gate 4: adapter lifecycle

- connection startup/shutdown
- application teardown
- stale handle rejection
- cancellation/disconnect behavior

### Gate 5: host smoke

- one supported native host
- browser host where applicable
- no semantic divergence from headless fixture

## Release-blocking failures

Treat these as release-blocking once the capability feature is advertised as
stable:

- MCP/API path reaches a different domain handler from the GUI binding
- externally exposed capability bypasses semantic authorization/validation
- the same accepted input causes divergent semantic state
- hidden/internal capability appears in generated external inventory
- schema drift occurs nondeterministically
- one path executes a non-idempotent side effect more times than another without
  an explicit contract
- dead application/entity state remains remotely callable
- MCP-originated state change does not reach normal GUI observation

## Acceptance gate

This packet is complete when CI can take one reference application, derive its
capability manifest, and prove across GUI semantic binding, direct API, and MCP
lanes that:

1. successful commands converge on the same semantic state and result;
2. rejected commands preserve state and report equivalent domain failures after
   entry-path policy;
3. notification/side-effect traces satisfy the same invariants;
4. generated schemas and external names are deterministic;
5. random operation sequences preserve the model;
6. adapter retry/cancellation behavior is explicit and tested;
7. GUI redraw observes mutations initiated outside the GUI;
8. parity tests remain headless-first and do not depend on pixel comparison.
