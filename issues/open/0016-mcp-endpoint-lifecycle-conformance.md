# MCP endpoint topology and asynchronous lifecycle conformance

Status: open
Parent: [0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md)
Depends on: [0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md)
Related: [0014-gui-api-mcp-equivalence-conformance.md](0014-gui-api-mcp-equivalence-conformance.md), [0009-browser-backend.md](0009-browser-backend.md), [0011-electron-tauri-migration.md](0011-electron-tauri-migration.md)

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

- [ ] A headless reference app can serve and close the 0013 adapter through its
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
