# Capability registry owner lifecycle

Status: open
Parent: [0012-semantic-capability-model.md](../closed/0012-semantic-capability-model.md)
Related: [0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md), [0014-gui-api-mcp-equivalence-conformance.md](0014-gui-api-mcp-equivalence-conformance.md)

## Goal

Bind a capability registry to its application lifetime so shutting down an
application automatically makes every capability owned by it unavailable. The
current API supports explicit registry teardown and tests stale-owner rejection;
this packet covers lifecycle wiring for arbitrary application-owned registries.

## Scope

- Define how an `App` creates or adopts a capability registry and how the owner
  relationship is represented without exposing transport-specific types.
- Invalidate direct, GUI-bound, and adapter-backed invocation when the owner
  begins shutdown.
- Ensure adapter caches and in-flight completion state cannot disclose a
  retained result or invoke a handler after owner teardown.
- Keep teardown idempotent and safe when disposal is reentrant or repeated.

## Acceptance

- [ ] Stopping or destroying the owning `App` invalidates its registry without
  requiring callers to separately remember `Registry::teardown`.
- [ ] Direct, GUI, and MCP-originated calls all fail with a stable lifecycle
  error after owner shutdown; none executes the domain handler or commits a new
  side effect.
- [ ] Cached request outcomes and late completions are rejected after shutdown.
- [ ] Headless tests cover normal shutdown, repeated/reentrant teardown, stale
  handles, and calls from every invocation origin.
- [ ] The owner-lifecycle contract remains in the portable capability/core
  layer and introduces no MCP or platform dependency.

## Non-goals

- Changing the protocol request-ID cache policy or promising exactly-once
  effects across process restarts.
- Replacing application-defined authorization or availability checks.
