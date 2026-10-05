# Issue 0016 WIP snapshot — 2026-10-05

Paused, incomplete, and **not merge-ready**. This branch preserves the cooperative
async capability work from main `35aae36e79588c47c030093bf64eaf54b15f715a`.
Publication is a backup snapshot, not acceptance or completion of issues 0016/0013.

## Included

Additive async capabilities with owned input snapshots, cooperative polling,
one-shot outcomes, cancellation/lifetime checks, and a bounded in-process MCP
adapter. The existing synchronous adapter remains separate. No async wire driver,
Node async endpoint, or native/browser endpoint topology is implemented here.

## Unresolved blocking review findings

1. In `capability/async.mbt`, typed/GUI admission invokes availability and policy
   callbacks before input snapshotting. A callback can mutate caller-owned input,
   giving different snapshot semantics from erased `Registry::begin`, which copies
   transport input before those callbacks. Existing tests miss this ordering case.
2. Admission failure handling checks lifetime/cancellation but does not consistently
   re-check current policy before disclosing decoder/snapshot/validator errors.
   A callback that revokes policy and fails can expose its error rather than
   `PermissionDenied`. Add regression coverage and reconcile the implementation
   with the documented error-disclosure contract before considering a merge.

A smaller review note: encoder-triggered cancellation still allows subsequent
transport/schema validation and copying, although it does not disclose the result.
No review findings were fixed as part of publishing this snapshot.

## Validation already run on the preserved implementation

- Formatting and all-target check: passed.
- JS, wasm, wasm-gc: 219/219 tests passed on each target.
- Native focused suites: core 9/9, capability 67/67, MCP 56/56.
- Node MCP stdio conformance: 4/4, plus compiled fixture inventory check.
- Python contract/audit suites: 60/60, plus dependency contracts.
- Pinned turtles 0.3.0 discovery only: capability 358, MCP 294 mutants;
  no parser skips/warnings observed.

Full mutation execution and reviewed replacement baselines have **not** been run
for this WIP. Hosted CI and production native/browser integration validation have
not been established for this snapshot. Passing local tests do not resolve the
blocking findings above. Only this status document was added for publication;
implementation work remains paused.
