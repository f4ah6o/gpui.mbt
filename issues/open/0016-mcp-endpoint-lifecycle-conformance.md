# MCP endpoint topology and asynchronous lifecycle conformance

Status: open
Parent: [0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md)
Depends on: [0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md)
Related: [0014-gui-api-mcp-equivalence-conformance.md](../closed/0014-gui-api-mcp-equivalence-conformance.md), [0009-browser-backend.md](0009-browser-backend.md), [0011-electron-tauri-migration.md](0011-electron-tauri-migration.md)

## Progress — 2026-10-04

The headless endpoint acceptance is complete in implementation commit
`60aabcd19c5d3326965f9f4dcee3e820f51638c5`. The compiled MoonBit fixture is
served by a real Node stdio process; the endpoint suite passes 4/4 and checks
request framing bounds, malformed UTF-8 recovery, no-response notifications,
shared semantic state, and shutdown on stdin EOF. The remaining acceptance is
native/browser topology, genuinely asynchronous cancellation/disconnect, and
CI-retained lifecycle artifacts.

The bounded semantic packet 0014 has reviewed capability/MCP mutation baselines
and closes on verified merge after its final-head stability/CI gates. That review does not satisfy or
close this packet's asynchronous cancellation, hosted parity, or native/browser
endpoint acceptance. Parent 0013 remains open until this work and its parent
close review are complete.

## Portable cooperative foundation (local implementation, review pending)

The first semantic slice adds `AsyncCapability`, explicit owned input snapshots,
bounded per-poll work, single-consumption typed outcomes, cancellation, owner
revocation, and dynamic authorization through the existing registry contracts.
The in-process adapter has a separate cooperative inventory and bounded active
calls; legacy wire inventory omits operations it cannot drive. See the
[cooperative contract](../../docs/cooperative-capabilities.md).

This does not complete any remaining endpoint acceptance checkbox. No wire
async driver, disconnect protocol, native/browser endpoint topology, rollback,
or exactly-once promise is implemented. Local portable tests pass 219/219 on JS, Wasm and Wasm GC; targeted native
core/capability/MCP tests, stdio regression and Python contracts pass. The
[contract evidence](../../docs/cooperative-capabilities.md#local-evidence)
records the exact scope. Semantic mutation execution, independent review and
hosted final-head validation are still required before publication.

## Goal

Prove that the adapter supplied by 0013 can be hosted in the supported
headless/native/browser topologies and that cancellation, disconnect, and
teardown preserve the semantic invocation contract for long-running operations.
This packet starts after the selected wire host exists; it owns topology
integration and lifecycle conformance, not a second protocol implementation.

## Scope

- Exercise a real headless endpoint and the documented native/browser host
  bridges using the same capability registry and handler.
- Keep browser builds inside the browser privilege boundary; native-only
  transports must not leak into portable or browser packages.
- Define and test cancellation before execution, during an asynchronous
  operation, after a side effect commits, and client disconnect during work.
- Ensure teardown rejects stale requests and drops late completions without
  reporting rollback or exactly-once behavior that was not implemented.
- Compare normalized semantic state, result/error, notification, and
  side-effect traces across in-process and hosted MCP invocation.

The optional stdio host and its protocol framing/negotiation are owned by 0013;
this packet must exercise that host rather than add another framing layer.

## Acceptance

- [x] A headless reference app can serve and close the 0013 adapter through its
  documented endpoint, with bounded request and shutdown behavior.
- [ ] At least one native topology and the browser topology are exercised end
  to end; each routes through the shared capability registry and respects
  default-deny exposure and the host privilege boundary.
- [ ] A genuinely asynchronous fixture proves cancellation before start,
  cancellation while running, disconnect before/after commit, and teardown
  with a pending request. The tests assert whether a side effect occurred and
  never claim rollback after commit.
- [ ] GUI, direct API, in-process MCP, and hosted MCP produce the same
  normalized semantic outcome where policy permits; transport failures remain
  distinct from domain failures.
- [ ] CI retains the endpoint, lifecycle, and failure artifacts needed to
  diagnose a regression without a local reproduction.

## Non-goals

- Exactly-once execution across process failure or uncoordinated clients.
- Making MCP transport mandatory for ordinary GUI applications.
- Duplicating 0014's full semantic reference-model suite for every renderer.
