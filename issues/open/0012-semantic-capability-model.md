# Semantic capability model for GUI / API / MCP parity

Status: open
Parent: [0001-product-charter-and-compatibility.md](0001-product-charter-and-compatibility.md)
Related: [0003-testing-pbt-mutation-and-visual-validation.md](0003-testing-pbt-mutation-and-visual-validation.md), [0009-browser-backend.md](0009-browser-backend.md)
Updated: 2026-10-04

## Goal

Define one application-facing semantic capability model from which gpui.mbt GUI
surfaces, programmatic APIs, and automation adapters can invoke the same domain
operations and observe the same application state.

The architectural direction is:

```text
                  -> gpui.mbt GUI
capability model  -> direct MoonBit API
                  -> external API adapters
                  -> MCP adapter
```

The capability model is the source of truth. The GUI must not be scraped or
reverse-engineered to discover behavior after the fact.

"Equivalent" means that a GUI action and its API/MCP counterpart reach the same
domain operation, validation, permission check, state transition, side effect,
and error contract. It does not mean that every pointer movement, hover,
animation, scroll operation, or rendering detail becomes a public API.

## Why this belongs in the framework

gpui.mbt already owns application state, actions, event dispatch, focus, and
platform-neutral UI semantics. If an application separately implements GUI
callbacks, an HTTP API, and MCP tools, those surfaces will drift.

A stable semantic capability layer allows applications to bind all surfaces to
one operation registry while keeping transport-specific details below the
application boundary.

This also makes automation testable headlessly: a test can invoke the same
capability used by a button without synthesizing a mouse click merely to reach
domain behavior.

## Implementation progress

Implemented in PR #12:

- portable typed `TypedCapability[I, O]` descriptors and one common invocation path
- stable semantic IDs, collision diagnostics, registry lookup, teardown invalidation,
  and deterministic public enumeration
- framework-owned deterministic `Value` / `Schema` projection for the initial
  transport-safe subset
- explicit `Internal` / `Local` / `External` exposure and per-origin policy hooks
- semantic `GuiBinding` that calls the same typed handler as direct invocation
- headless state/notification tests for GUI, direct, and erased registry invocation

Still required before this packet is complete:

- broader schema coverage for optional/record/tagged values in application fixtures
- application-owner teardown wiring beyond explicit registry teardown
- an observed browser host smoke proving rendered redraw for GUI, direct, and MCP fixture calls
- release/compatibility evidence for the final public API

## Shared typed-domain validation update — 2026-10-04

`TypedCapability::new_with_validation` now supplies input and output domain
validators used by GUI, direct, and erased registry calls. Typed invocation
does not project opaque application values through `Value`; schema and
transport checks remain at the erased boundary. `Value::validate_transport`
rejects non-finite numbers, duplicate object keys, cycles/depth over 32,
graphs over 10,000 nodes, and canonical JSON over 1 MiB before schema walks or
copies. The checked serializer counts UTF-16 code units and has exact boundary
coverage.

The browser fixture now renders one observed counter capability through GUI,
direct, and in-process MCP dispatch over the same app state; the JavaScript
host remains below the portable fixture. MCP dispatch here is a conformance
seam, not a network protocol. Registry-owner lifecycle wiring, broader record
and tagged-value application fixtures, compatibility review, and a real browser
host run remain open.


## Non-goals

- infer reliable domain semantics from arbitrary rendered pixels
- convert every widget callback into a remotely callable operation
- expose application internals automatically without an explicit policy
- make MCP, HTTP, JSON, or JavaScript types part of the portable core
- replace accessibility semantics with automation semantics
- promise parity for presentation-only interactions
- require runtime reflection that MoonBit does not provide

The first implementation should prefer explicit typed descriptors over magical
reflection or code generation that cannot be validated statically.

## Core concepts

### Capability registry

An application may register stable, namespaced capabilities such as:

```text
document.open
document.save
document.rename
document.current
selection.current
workspace.search
```

Capability IDs are public semantic identifiers once exposed outside one module.
They must therefore have deterministic naming, collision checks, and a documented
compatibility policy.

The registry must be independent from window IDs, element IDs, DOM nodes,
renderer objects, native handles, or MCP connection state.

### Commands

A command represents an operation that may change application state or cause a
side effect.

A command descriptor should be able to state:

- stable capability ID
- human-readable title and description
- typed input
- typed output
- effect class
- whether repeated execution is safe/idempotent
- availability predicate where required
- permission/policy metadata
- optional presentation metadata used by GUI surfaces
- transport schema projection when the value is externally serializable

Effect metadata is descriptive and useful for policy/UI, but it must never be
the only enforcement mechanism for authorization.

### Queries and observable state

A query represents a read of application state. A query must use the same
application model as the GUI rather than a transport-owned shadow state.

Observable state may later support subscriptions, but the core contract must
first define deterministic snapshot/version behavior without depending on a
particular transport.

### Workflows

A higher-level workflow may compose commands and queries. Workflows are
explicitly declared semantic operations; they must not be inferred merely
because several controls appear close together in a view.

A future MCP prompt mapping may use explicit workflows, but prompt generation is
not required for every command.

## Typed invocation contract

The portable core should expose a typed invocation path conceptually equivalent
to:

```text
resolve capability
  -> validate availability and policy
  -> validate/convert typed arguments
  -> invoke application operation
  -> commit application state
  -> emit normal application notifications
  -> return typed result or typed error
```

GUI and automation entry points must converge before domain execution. They must
not each reimplement validation or side effects.

The exact MoonBit API should fit the language's type system and avoid forcing
all internal values through a JSON-like dynamic representation.

## Schema boundary

External adapters need machine-readable schemas, while portable application code
should remain strongly typed.

Define a small framework-owned schema vocabulary sufficient to project exposed
inputs/outputs into transport schemas. The initial externally serializable value
set should be deliberately constrained and deterministic, for example:

- null/unit
- boolean
- integer/number with documented range semantics
- string
- arrays
- records/objects
- tagged variants where the projection is unambiguous
- optional values

Unsupported values must fail capability registration or adapter exposure with a
clear diagnostic. Do not silently stringify opaque application objects,
entities, native handles, callbacks, resources, or cycles.

Schema generation must be deterministic so generated manifests can be snapshotted
and reviewed.

## UI binding contract

A semantic GUI binding should reference a capability rather than duplicate its
domain handler.

Conceptually:

```text
Button("Save")
  -> capability document.save
  -> application operation
  -> application state notification
  -> normal gpui.mbt redraw
```

The binding layer may provide GUI-only argument construction, enabled/disabled
state, labels, icons, shortcuts, confirmation UI, and result presentation.

GUI-only callbacks remain valid. A control is not automatically public merely
because it exists.

Canvas gestures and complex interactions must bind to semantic operations at the
point where application meaning is known. For example, "move node to position"
is a useful capability; "pointer moved by 17 pixels" usually is not.

## Capability semantics vs accessibility semantics

Accessibility and automation are related but distinct.

Accessibility semantics describe perceivable UI structure, roles, names, values,
focus, and supported assistive actions.

Capability semantics describe application operations and queryable state.

The two may share labels and stable semantic identifiers where useful, but one
must not be implemented as an accidental substitute for the other.

## Exposure policy

Registration does not imply remote exposure.

The model must support an application policy that can distinguish at least:

- internal-only capability
- local programmatic/automation capability
- externally exposable capability

Destructive or sensitive operations need explicit policy hooks. The portable
core must not assume that a remote MCP client has the same trust level as an
in-process GUI.

Policy evaluation must occur on every invocation path that crosses the relevant
trust boundary.

## Determinism and lifecycle

Capability behavior must integrate with the normal App/Entity/Context lifecycle.

Required properties:

- invocation ordering is deterministic under the documented scheduler model
- dead/released entities cannot be revived through a capability handle
- capability availability changes when its owning application state changes
- teardown invalidates adapter-facing handles cleanly
- callbacks cannot re-enter mutable application state in an undocumented way
- direct and adapter invocation produce the same normal notifications
- failures do not leave a second transport-owned state machine

## Work packets

### A. Capability identifiers and registry

Implement stable IDs, registration, lookup, collision diagnostics, lifecycle,
and deterministic enumeration.

Acceptance:

- duplicate IDs fail deterministically
- registry enumeration is stable
- teardown leaves no live callable capability owned by a dead application
- no platform/transport type leaks into the public registry contract

### B. Typed command/query invocation

Implement typed command and query descriptors plus one common invocation path.

Acceptance:

- a headless fixture invokes one read and one write capability
- invalid arguments/policy failures are typed errors
- GUI bindings and direct calls share the same domain handler
- command execution emits the same application notifications as ordinary
  in-process domain execution

### C. External schema projection

Implement deterministic schema projection for the initial supported value set.

Acceptance:

- schema snapshots are byte-stable for unchanged definitions
- unsupported values fail explicitly
- equivalent declarations do not produce order-dependent output
- schema code does not become a third-party runtime dependency

### D. Semantic GUI bindings

Add minimal binding primitives for controls/actions to reference capabilities.

Acceptance:

- a button can bind to a command without duplicating its implementation
- enabled/available state can be derived without transport coupling
- GUI-only actions remain possible and remain unexposed by default
- a state change caused by non-GUI invocation redraws the GUI through the normal
  state/update path

## Acceptance gate

This packet is complete when one headless example and one real GUI example prove:

1. one semantic write operation is registered once;
2. a GUI control invokes it;
3. direct MoonBit code invokes it through the capability API;
4. both paths produce the same normalized state transition and notification
   trace;
5. one semantic query reads the resulting state;
6. the exposed schema is deterministic;
7. transport-specific types are absent from portable application APIs.

The MCP/remote adapter itself is tracked separately so the core model is not
coupled to one protocol.
