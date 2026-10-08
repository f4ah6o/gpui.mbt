# Shared accessibility tree foundation

This document describes the first portable semantic-tree slice in
`accessibility/`. It is a headless contract for Linux AT-SPI, macOS AX, and
Windows UIA projections to share. It does not implement or qualify any native
accessibility bridge.

## Ownership and relationship to existing packages

`AccessibilityModel` owns the live semantic tree and is confined to one UI-owner
thread. Its copied handle values share one revocable `Ref`-backed owner state.
Every model receives an opaque process-local owner identity; every newly
admitted node receives a monotonically increasing generation token. A
caller-owned `NodeSpec.key` is only a continuity lookup key. It is never
treated as a generation, native handle, pointer, or authority by itself.
`NodeId::key()` is a read-only convenience for mapping a live semantic node
back to its caller-owned control; action APIs still require the opaque full ID.

An ID remains stable while its key is present in adjacent commits. Removal,
`reset`, or model `close` invalidates prior IDs. Re-admitting the same key uses
a fresh generation. Replacing a semantic target while keeping its key in the
next commit deliberately preserves identity; callers must remove it for a
commit, reset, or choose a different key when they mean a new target. Model
`close` is explicit and is not automatically tied to an app or window lifetime.
Identity and revision counters reject exhaustion instead of wrapping. An
exhausted revision blocks further ordinary commits and reset;
terminal `close` still revokes all handles and clears the tree, and a future
adapter must treat that as teardown rather than an ordinary commit at a
saturated revision. Owner identity prevents a token from one model from
targeting a node in another model.

This tree is semantic state, separate from `element.ElementTree`. The latter
owns layout/hit-test records and an opaque `FocusOwner` for one focus acquisition
within one element-tree lineage. An application may map a Button's or other
element's caller-owned `UInt64` to `NodeSpec.key`, then synchronize semantic
focus/state from its owning control and element tree. The accessibility layer
does not replace element hit-testing, layout, focus acquisition, or the
application's authority over actions.

Action validation is likewise separate from `capability/`. `Invoke` produces
only a typed effect/request value for immediate dispatch by the application
owner to its existing handler. It does not duplicate a capability registry,
policy layer, callback store, or MCP exposure. For deferred work, queue an
`ActionRequest` (node ID plus action) and resolve it against the live model only
when consumed. Do not queue or replay a previously returned `ActionIntent`;
that value is a validation receipt, not a one-shot token or executable
capability. Re-resolving the same live request may return another receipt.
Exactly-once domain effects remain the responsibility of the application
owner's existing action/GUI-binding path.

## Snapshot and commit contract

Callers provide a complete flat pre-order array of `NodeSpec` values. There is
exactly one root. Each non-root node names an earlier ancestor as its parent,
so cycles, forward references, and non-contiguous parent subtrees are rejected.
The resulting immutable snapshot preserves preorder, parent links, and ordered
child IDs.

`publish` first copies and validates the complete candidate. It then assigns
IDs, commits one new snapshot revision, and returns that committed snapshot. A
failure leaves the previous snapshot, revision, and identity sequence intact.
A platform adapter can issue its operating-system notification only after
`publish` returns; no notification callback or OS adapter is included here.
Reading or retaining an older snapshot is observational only and does not
grant action authority.

The current semantic fields are role, name, logical-point bounds, enabled,
loading, focused, supported actions, parent, and ordered children. This first
slice omits values, text ranges/selections/caret, live event notifications,
native role mapping, and platform-specific state. Those can be added through
compatible portable fields after separate design review.

## Bounds and action rules

The bounded contract is:

- at most 4,096 live nodes
- at most 256 levels, with the root counted as level 1
- at most 4,096 MoonBit string units per name
- at most 1,048,576 name units across one snapshot
- at most one supported action per node in this slice

Only `Invoke` is implemented. Action support is distinct from current
availability: a node may advertise Invoke while disabled or loading, but
`resolve_action` returns a typed `Disabled` or `Loading` rejection. At most one
node may be focused. A disabled node cannot be focused; a loading node may
remain focused. Action errors also distinguish a foreign owner, removed or
replaced stale node, unsupported action, and closed model.

## Existing and missing evidence

This package's headless tests define the portable model contract only. They do
not establish AT-SPI, macOS AX, Windows UIA, screen-reader behavior, OS-level
event ordering, or visual accessibility. Weekboard's existing DOM projection
remains a bounded browser-specific adapter and does not consume this general
tree until a separate integration is designed.
