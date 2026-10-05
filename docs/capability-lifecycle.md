# Capability owner lifecycle

Application-owned capabilities use `Registry::new_owned(app)`, or
`registry.attach_owner(app)` to adopt a previously standalone registry. Both
return a `Result`. Adoption applies to capabilities already registered, including
copied typed handles and GUI bindings created before registration or adoption.
`Registry::new()` remains available for deliberately standalone registries.

`core/` exposes a read-only `AppLifetime` token through `app.lifetime()`. The token
contains only the logical app identity and shared lifetime/readiness flags; it
does not retain the app, its entities, or callbacks. `capability/` consumes this
portable contract through a one-way dependency on `core/`. Neither package
imports MCP, a platform package, or a native/transport handle.

## State and ownership

- `New`: owner lifetime is valid, so registries may be created/adopted and
  capabilities registered. Invocation returns `AppNotRunning`; GUI bindings are
  disabled. Inventory/schema inspection is allowed during configuration.
- `Running`: the same handles become callable, subject to the usual exposure,
  availability, policy, and validation checks.
- At the beginning of `request_stop`: all owner tokens are permanently revoked,
  before task cancellation or entity-release callbacks. Invocation returns
  `StaleHandle`, even while the app is still `Stopping` and entity release is
  deferred. The optional MCP adapter maps this error to `Stale`.
- Repeated stop and registry teardown are harmless. Stopping a `New` app also
  revokes its registries. Other apps and their registries are unaffected.

An app may own multiple registries. A registry may adopt only one app;
reattaching the same live app is idempotent. It cannot transfer to another app
or be revived after teardown. A typed capability may be registered in only one
registry, because its direct and GUI handles share that registry's lifetime.
Use a fresh typed capability instance when building independent registries.
Failed registration leaves both the existing owner and the rejected registry
unchanged. Unregistered typed capabilities remain explicitly standalone.

App disposal in this headless API means `request_stop` followed by draining
pending work with `run_ready`. Dropping a MoonBit reference does not provide an
application-destructor/finalizer guarantee and is not a substitute for stop.
Explicit `Registry::teardown` remains useful for ending a registry before its
app; it revokes typed and GUI handles as well as registry/adapter calls.

## Reentrant callbacks and late results

The common semantic path checks owner readiness before invoking application
callbacks and rechecks it after availability, policy, decode, input validation,
the handler, output validation, and encode. If any callback stops the owner,
no later stage runs and neither its successful result nor a late application
error is disclosed. GUI enablement uses the same owner check.

Request-ID dispatch checks owner liveness before request validation, conflict
checks, or retained-result replay, and again after a request completes. Replay
authorization also rechecks lifetime after application callbacks. A stopped
owner therefore yields `Stale` for old IDs, changed arguments, active retries,
and fresh requests. Retained/in-flight adapter state is cleared when a stopped
owner is observed; it is never reused to execute another handler or expose a
cached result. Uncached tool calls and resource reads use the same semantic
completion checks.

`TypedCapability` handlers are synchronous. Stop cannot interrupt the body of a handler already
running or roll back a side effect it already committed. It rejects that
handler's late completion and every later invocation. Code that performs
external effects inside a running handler remains responsible for its own
cooperative cancellation and transaction boundaries. The additive [cooperative API](cooperative-capabilities.md) supports bounded
resumable semantic work and in-process cancellation. True asynchronous wire-host
completion/cancellation remains outside the owner-lifecycle slice.

## Evidence

- `core/core_test.mbt`: shared read-only tokens, readiness, immediate revocation
  before deferred entity release, `New` stop, repeated stop, and unrelated apps.
- `capability/owner_lifecycle_test.mbt`: creation/adoption, pre-registration
  handles, every invocation origin, pre-start gating, no resurrection or
  competing registry owners, standalone/reentrant teardown, every callback
  boundary, and no handler calls after shutdown with always-available closures.
- `mcp/owner_lifecycle_test.mbt`: tools/resources, cached replay, changed request
  IDs/arguments, shutdown during replay authorization, in-flight nested calls,
  rejection of late success and late domain errors, and `New -> Running`
  gating for both new calls and cached replay after adoption.
- `tests/test_check_contracts.py`: approved capability-to-core edge and rejected
  reverse, MCP, and platform edges.
