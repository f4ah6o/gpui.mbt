# Capability registry owner lifecycle

Status: closed
Closed: 2026-10-04
Parent: [0012-semantic-capability-model.md](0012-semantic-capability-model.md)
Related: [0013-generated-api-and-mcp-adapters.md](../open/0013-generated-api-and-mcp-adapters.md), [0014-gui-api-mcp-equivalence-conformance.md](../open/0014-gui-api-mcp-equivalence-conformance.md)

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

- [x] Stopping or destroying the owning `App` invalidates its registry without
  requiring callers to separately remember `Registry::teardown`.
- [x] Direct, GUI, and MCP-originated calls all fail with a stable lifecycle
  error after owner shutdown; none executes the domain handler or commits a new
  side effect.
- [x] Cached request outcomes and late completions are rejected after shutdown.
- [x] Headless tests cover normal shutdown, repeated/reentrant teardown, stale
  handles, and calls from every invocation origin.
- [x] The owner-lifecycle contract remains in the portable capability/core
  layer and introduces no MCP or platform dependency.

## Non-goals

- Changing the protocol request-ID cache policy or promising exactly-once
  effects across process restarts.
- Replacing application-defined authorization or availability checks.


## Implementation and acceptance evidence — 2026-10-04

Closure takes effect with the verified merge of this implementation. The local
checks below establish the portable headless acceptance; hosted CI on the final
candidate commit must pass before merge. No hosted result is claimed here.

- `core/AppLifetime` provides read-only owner identity, liveness, and readiness.
  `request_stop` revokes it before cancellation or release callbacks, including
  `New -> Stopped`. The reserved `Failed` stop path also revokes it, but the
  public headless API does not currently produce `Failed`.
- `Registry::new_owned(app)` creates an owned registry; `attach_owner(app)`
  adopts existing registered capabilities and all their typed/GUI aliases.
  Configuration is allowed in `New`; invocation waits for `Running`.
- Registration binds a typed capability irreversibly to one registry. Repeated
  stop/teardown is harmless; cross-app adoption and cross-registry rebinding
  cannot resurrect stale handles.
- Shared checks reject every invocation origin with `StaleHandle` after stop.
  MCP reports `Stale`, including retained results, changed request arguments,
  active retries, and late handler results/errors. Each application callback
  boundary rechecks lifetime before another stage can run.
- `capability -> core + diagnostics` is an explicit one-way portable dependency.
  Core has no capability, MCP, or platform import; dependency tests reject
  reverse and transport/platform edges.

Headless coverage is in `core/core_test.mbt`,
`capability/owner_lifecycle_test.mbt`, and `mcp/owner_lifecycle_test.mbt`.
Availability closures deliberately return `Ok` in the ownership fixtures so
entity-specific availability cannot conceal missing owner wiring. Tests cover
normal stop, pre-start gating, adoption with an existing cached result,
repeated/reentrant teardown, deferred entity release, all invocation origins,
every user callback stage, and late success/error rejection.

Local checks with pinned `moonc v0.10.14+7d59c7ec9`:

- `moon fmt --check`: passed.
- `moon check --target all --deny-warn`: passed.
- `moon test --target js --deny-warn`: 144/144 passed.
- `moon test --target wasm --deny-warn`: 144/144 passed.
- `moon test --target wasm-gc --deny-warn`: 144/144 passed.
- Targeted native tests: core 9/9, capability 17/17, MCP 31/31 passed.
- Node stdio endpoint tests: 4/4 passed; generated inventory drift check passed.
- Python tests: 53/53 passed; `scripts/check_contracts.py` passed.
- Full `moon test --target all --deny-warn`: blocked locally before execution
  by missing generated `ubuntu/xdg-shell-protocol.c` and the Ubuntu native
  development prerequisites. This is not a full-native or full-CI pass.
  macOS/Windows/native GUI and browser end-to-end checks were not run locally.

See [the owner lifecycle contract](../../docs/capability-lifecycle.md) for the
public API and migration requirements. The supported app-disposal path is
explicit `request_stop` plus `run_ready`; no GC/finalizer destruction guarantee
is claimed. Synchronous handler bodies already running cannot be interrupted
or have committed effects rolled back. Their late completion is rejected;
true asynchronous endpoint lifetime remains in
[0016](../open/0016-mcp-endpoint-lifecycle-conformance.md).
