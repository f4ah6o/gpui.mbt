## Implementation progress

Implemented in PR #12:

- deterministic transport-neutral external capability manifest
- deterministic external-name derivation with collision checks
- optional `mcp/` package above the portable capability layer
- generated tool inventory and unit-input query resources from external descriptors
- default-deny omission of non-external capabilities
- MCP tool/resource dispatch routed back through the common semantic registry
- distinct adapter error mapping for unknown input, invalid input, policy denial,
  unavailable/stale state, domain failure, and closed adapter lifecycle
- headless MCP-enabled fixture without renderer/window dependencies

Still required before this packet is complete:

- concrete MCP wire framing/transport host and protocol-version negotiation
- cancellation/disconnect handling around in-flight operations
- browser/native topology smoke for an actual MCP transport endpoint
- generated artifact drift policy beyond in-memory canonical snapshots

## In-process adapter and request replay update — 2026-10-04

The optional adapter now provides session-local `call_tool_with_request_id`
duplicate suppression. It fingerprints a validated owned input snapshot,
reserves IDs before synchronous handler execution, rejects conflicting and
reentrant duplicates, rechecks registry liveness/availability/policy before
every replay, and retains at most 128 outcomes with a 256 KiB result cap.
Large successful results keep a no-reexecution tombstone. Tests cover policy
revocation, teardown, mutable input aliasing, nested same-ID calls, close during
execution, and large outcomes. This is bounded in-process behavior; it does not
provide durable or cross-process exactly-once execution, and synchronous
handlers cannot be interrupted after starting.

Inventory/schema JSON remains transport-neutral metadata. The current adapter
does not implement MCP wire framing or negotiation; scalar capability schemas
must be wrapped into MCP's object-shaped wire inputs by a future host adapter.
Protocol framing, connection cancellation, actual MCP endpoint smoke, and
generated artifact drift checks remain open.

# Generated API and MCP adapters from semantic capabilities

Status: open
Parent: [0012-semantic-capability-model.md](0012-semantic-capability-model.md)
Related: [0009-browser-backend.md](0009-browser-backend.md), [0011-electron-tauri-migration.md](0011-electron-tauri-migration.md)
Updated: 2026-10-04
Child: [0016-mcp-endpoint-lifecycle-conformance.md](0016-mcp-endpoint-lifecycle-conformance.md)

## Current-head acceptance triage — 2026-10-04

Basis: merged main HEAD `1dea499e34a36a64927791c94f35965a91c305a2`; PR #13
head `d70b1255aa5dc1eaaea04a67a9ea748d29317cbd`.

- [x] Packet A: transport-neutral manifest generation, stable enumeration,
  deterministic external-name mapping, and collision checks are implemented
  in `capability/registry.mbt` and tested in `capability/capability_test.mbt`.
- [x] Packet B: the optional adapter derives a default-safe tools/resources
  inventory, omits unexposed capabilities, keeps prompts unadvertised, and
  serializes deterministic schema metadata; tests cover registration-order
  independence in `mcp/adapter_test.mbt`.
- [x] Packet C's in-process dispatch path routes through the shared registry;
  read/write, invalid input, policy denial, stale state, teardown, request
  conflicts, and bounded result retention have headless tests.
- [x] Packet D's portable capability layer and optional `mcp/` package remain
  separate; the browser fixture is headless-testable without a native window.
- [ ] At this audited head the adapter has no actual MCP wire endpoint. The
  0013 implementation follow-up owns the optional stdio host; 0016 tracks
  browser/native topology smoke and asynchronous cancellation/disconnect.
- [ ] Checked/reproducible generated-artifact drift checks are not present.
  Canonical in-memory serialization tests do not by themselves check a
  committed artifact against its source descriptors.

The hosted [contracts/core run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649283)
and [browser run](https://github.com/f4ah6o/gpui.mbt/actions/runs/37195649282)
passed at PR #13 head. This packet remains open for the wire host and drift
gate.

## Goal

Generate machine-consumable API surfaces, including an MCP server adapter, from
the semantic capability registry defined in 0012 without duplicating domain
handlers.

The desired application architecture is:

```text
gpui.mbt application
  -> semantic capability registry
       -> GUI bindings
       -> direct MoonBit invocation
       -> deterministic API manifest
       -> MCP adapter
       -> optional future HTTP/CLI adapters
```

An application author should describe an operation once, opt it into the desired
exposure policy, and get protocol metadata plus dispatch glue automatically.

"Automatic" means generated from explicit semantic capability declarations. It
does not mean scanning pixels, guessing callback intent, exporting every public
function, or using unsafe runtime reflection.

## Dependency boundary

MCP support must not become a required runtime dependency for ordinary gpui.mbt
applications.

Keep:

- capability semantics in portable MoonBit packages
- transport-neutral schema/manifest generation in repository-owned code
- MCP protocol framing, connection state, and transport integration in an
  optional adapter/host package
- browser/native host specifics below the platform/adapter boundary

If protocol parsing or transport glue requires host FFI, keep that surface
narrow and do not leak host objects into application-facing capability APIs.

## Generated API manifest

Define a deterministic transport-neutral manifest before binding to MCP.

For each exposed capability include enough information to drive adapters:

- stable semantic ID
- stable external name
- title/description
- operation kind
- input schema
- output schema
- effect/idempotency metadata
- exposure/policy metadata that is safe to publish
- compatibility/version information where required

The manifest must be deterministic and reviewable as a generated artifact.

Do not publish secrets, authorization decisions, internal object identities, or
host handles merely because they exist in the in-process descriptor.

## Name mapping

External protocols may impose identifier restrictions that differ from
namespaced capability IDs.

Define a deterministic mapping, for example:

```text
document.save  -> document_save
workspace.search -> workspace_search
```

The exact encoding may differ, but it must:

- be reversible or traceable to the semantic ID
- detect collisions before serving requests
- remain stable across runs
- avoid depending on registration order
- have an explicit compatibility rule if renamed

Applications may opt into an explicit external name when protocol constraints or
long-term compatibility require it.

## MCP mapping

The initial MCP adapter should follow these semantic mappings:

### Tools

Commands map naturally to MCP tools when externally exposed.

A tool call must route back through the same capability invocation path used by
the GUI/direct API. The MCP handler must not contain a second implementation of
the domain operation.

### Resources

Stable readable application state may map to MCP resources when a resource model
is a good semantic fit.

Not every query must become a resource. A query with required parameters or
operation-like semantics may be more naturally represented as a read-only tool.
The adapter should make this mapping explicit and deterministic rather than
pretending the distinction does not exist.

### Prompts

Do not synthesize prompts from every GUI control.

Only explicit application workflows that have useful user-facing prompt
semantics should be eligible for prompt exposure.

### Capability negotiation

The adapter must advertise only protocol features it actually implements.
Optional MCP features must be gated by negotiated support rather than assumed.

The semantic capability model must remain valid if MCP protocol versions evolve;
version-specific details belong in the adapter.

## Dispatch

MCP dispatch should be conceptually:

```text
MCP request
  -> protocol validation
  -> external-name resolution
  -> connection/session policy
  -> semantic capability policy
  -> typed argument conversion
  -> common capability invocation
  -> typed result
  -> protocol result conversion
```

The common capability invocation boundary is mandatory. Adapters may add policy
but may not bypass application validation.

## Errors

Define deterministic mappings for at least:

- unknown capability/tool
- invalid input
- unsupported schema/value
- capability currently unavailable
- permission/policy denied
- stale/dead owning entity
- domain validation failure
- domain execution failure
- cancellation
- adapter/protocol failure

Transport errors and domain errors must remain distinguishable in diagnostics.

Do not flatten every failure into a successful text result.

## Side effects, retries, and idempotency

Remote invocation changes failure/retry semantics.

Required policy:

- the adapter must not silently retry a non-idempotent command
- idempotency metadata is descriptive unless backed by real implementation
- duplicate requests must not be assumed safe
- if request de-duplication is later supported, its key/lifetime/storage contract
  must be explicit and tested
- cancellation must not claim rollback after a side effect has already committed
- disconnecting a client must not corrupt application state

The capability registry remains the source of truth for whether an operation is
safe to repeat.

## Security and trust boundary

Auto-generation must be default-safe.

Required properties:

- internal capabilities are not externally exposed by default
- MCP exposure requires an explicit application policy
- transport authentication and semantic authorization are separate concerns
- authorization is enforced server-side, not only through descriptive metadata
- sensitive results may be redacted or rejected by policy
- destructive actions may require application-defined confirmation/approval
  semantics
- MCP annotations or client UI hints are never treated as authorization
- logs must avoid leaking secret inputs/results by default

A local stdio-style deployment and a remotely reachable server may use different
trust policies even though they expose the same semantic registry.

## State updates

An MCP-originated command that changes application state must update open GUI
windows through normal gpui.mbt observation/notification mechanisms.

Do not add MCP-specific state mirroring merely to refresh the UI.

For readable state, the adapter may expose snapshots and, where the negotiated
protocol supports it, change notifications/subscriptions. Polling or snapshot
reads remain valid when subscriptions are unavailable.

## Host topologies

The design must permit at least:

### In-process/local host

```text
desktop application
  -> capability registry
  -> MCP adapter
  -> local transport
```

### Browser/Electron/Tauri host

```text
gpui.mbt browser application
  -> capability registry
  -> host bridge
  -> MCP adapter/server process or permitted host endpoint
```

The browser backend must not gain unrestricted process/network privileges merely
to make MCP convenient. Browser security boundaries remain authoritative.

### Headless application

```text
gpui.mbt application model
  -> capability registry
  -> MCP adapter
```

A window server or renderer must not be required for headless semantic
operations.

## Generated artifacts

Provide deterministic development-time output suitable for review, such as:

- capability manifest
- external-name mapping
- input/output schemas
- MCP tool/resource inventory

Generated artifacts must either be reproducible and checked or intentionally
ephemeral with a CI drift check. Do not require developers to hand-maintain a
second schema file.

## Work packets

### A. Transport-neutral manifest

Generate and validate the manifest from 0012 descriptors.

Acceptance:

- stable ordering/output
- collision detection
- explicit unsupported-schema diagnostics
- no runtime dependency on MCP

### B. MCP inventory generation

Generate MCP-visible tool/resource/prompt metadata from explicitly exposed
capabilities.

Acceptance:

- no unexposed capability appears
- generated names are deterministic
- schemas match the capability descriptors
- unsupported protocol features are not advertised

### C. MCP request dispatch

Implement request routing into the common capability invocation path.

Acceptance:

- one tool call changes the same application state as its GUI control
- one read returns the same state observed by the GUI
- invalid input and policy denial are distinct typed failures internally and
  correctly represented at the protocol boundary
- teardown closes/invalidate adapter state cleanly

### D. Optional adapter packaging

Define supported host/transport packaging without making MCP mandatory.

Acceptance:

- a normal gpui.mbt GUI application builds without the MCP adapter
- a headless MCP-enabled fixture builds without a renderer/window
- browser builds do not accidentally receive privileged native transport APIs

## Acceptance gate

This packet is complete when a reference application can declare semantic
capabilities once and automatically obtain:

1. direct MoonBit invocation;
2. GUI binding;
3. deterministic external API manifest;
4. an MCP inventory generated from that manifest;
5. working MCP dispatch to the same domain handlers;
6. GUI refresh after an MCP-originated mutation;
7. default-deny external exposure for undeclared capabilities;
8. deterministic schema/name drift tests.

Future HTTP/OpenAPI or CLI adapters should consume the same manifest rather than
introducing a competing application API model.
