# Review result

Target: WIP evidence archive only
Base: `7232061f83769214843a2ccfa18f1e1a4d989031` (PR #40 public HEAD)
Verdict: approve-with-nits for publishing the archive; no product acceptance or merge approval

## Summary

The primary agent performed three passes: source/result correctness; publication boundaries and failure/lifecycle records; maintenance/reproduction and integration checks. No subagent or independent reviewer was used for this manual task.

The diff adds only this evidence directory. The tested source delta is a serialized patch, not applied to product files. The pinned base plus patch reconstructs the exact tested tree. All copied scripts, logs, summaries, and PNGs match their local originals byte for byte. The report keeps the native/IME failure, pre-input diagnostic failure, SIGABRT exit, and unfinished acceptance items separate from successful checks.

## Findings

### minor: Executed wrappers are historical local snapshots

Location: `run_e2e.py`, `run_ime_trace.py`, `run_ime_with_activation.py`

These files contain the original absolute paths, clean-HEAD assertions, and one-shot output directories. They are not portable runners for this evidence branch. README documents the existing repository entrypoint and the pinned source patch. A future reusable runner should accept explicit paths and reserve a fresh output directory rather than altering these archived bytes.

### minor: Activation wrapper does not establish a general failure-lifecycle contract

Location: `run_ime_with_activation.py:OwnedAppPopen.__init__`

The wrapper was exercised for the recorded owned-PID activation path. It does not implement app-owned abort handling if the helper itself times out or fails to produce JSON after the app was spawned. The recorded run completed through the repository driver's cleanup path. Reuse as a canonical runner requires handling those helper-failure paths; this archive is not wired into CI or a product command.

## Tests reviewed

- Historical native actrun: six of seven stages passed; live IME acceptance failed.
- Historical `moon fmt --check`: passed.
- Recorded Return keyDown/keyUp receipts, `handleEvent=true`, commit0, and 200-iteration timeout inspected against raw app logs.
- Current publication checks: Python AST syntax, JSON parsing, helper clang syntax, repository contracts, copied byte hashes, pinned patch/tree reconstruction, and scoped staged-diff checks.
- Product acceptance was not rerun or represented as Green for this archive-only publication.

## Residual risks

Return commit/unmark is unresolved. Final pixels and later input operations remain incomplete. The source patch contains the earlier local diagnostic implementation and has not received new independent review in this task. The draft evidence PR is not a replacement for PR #40's outstanding runtime and review gates.
