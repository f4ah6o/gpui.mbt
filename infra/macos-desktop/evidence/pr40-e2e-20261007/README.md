# WIP: macOS IME E2E scripts and failed Return evidence

This archive records the 2026-10-07 direct script run for [PR #40](https://github.com/gpui-mbt/gpui.mbt/pull/40). **Acceptance failed; product Green was not achieved.** Return keyDown and keyUp reached the app, but no commit callback arrived within the existing 200-iteration limit.

The evidence branch is based on PR #40's public branch `codex/feat/20261006-macos-text-ime-quality`, pinned at `7232061f83769214843a2ccfa18f1e1a4d989031`. The actual run tested local commit `c7e6cae99ffd218320d0377a53ea3cd5218421b4`, tree `49af3730fac01fe35f07cf644a58811babb1ef3c`. Its exact delta from the public base is preserved in [tested-source.diff](tested-source.diff). Product files on this branch stay at the public base; the patch is an archived dependency snapshot.

## Scripts and results

- [run_e2e.py](run_e2e.py): actual actrun/native invocation and process/exit recorder.
- [run_ime_trace.py](run_ime_trace.py): diagnostics-only retry that stopped before input because the owned key window was not ready.
- [run_ime_with_activation.py](run_ime_with_activation.py) and [activate_owned_app.m](activate_owned_app.m): actual owned-PID activation wrapper and public AppKit helper. They do not send external key or mouse events; the unchanged repository IME driver generates app-local input and captures its own window.
- [RESULT.md](RESULT.md): full report at the time of execution; historical “no push” statements describe that execution, before this archive was published.
- [verification.json](verification.json): actrun 6/7 passed, fmt passed, Return delivery complete, commit callbacks zero, and cleanup acknowledgements.
- [return-diagnostics.json](return-diagnostics.json): frozen/current dispatch9/keycode36 receipts, input-context route, and timeout state.
- [ime-activated/summary.json](ime-activated/summary.json) and [ime-activated/app.stdout.log](ime-activated/app.stdout.log): final diagnostic run. Other run summaries and stage logs are also retained.

The scripts are exact historical snapshots containing local absolute paths and one-shot output directories. They are not installed as portable runners or wired into CI. The original repository entrypoint was:

```sh
python3 infra/macos-desktop/actrun-feedback.py --root /private/tmp/gpui-macos-quality-profile --mode native --run-dir <new-external-evidence-directory>
/private/tmp/gpui-macos-quality-profile/moon/bin/moon fmt --check
```

To reproduce the tested implementation, reconstruct the archived patch in a separate checkout of the pinned public base and verify its tree against `archive-manifest.json` before running the repository entrypoint with a qualified Apple Silicon macOS profile. A new commit/replay will have a different commit identity. Running the public base alone is not a replay of this report.

## Outcome and remaining work

The host was macOS 26.5.2 (25F84), arm64 / Apple M4, Xcode 26.6 (17F113), macOS SDK 26.5. Actrun completed six of seven required stages successfully. Live Kotoeri acceptance reached `Hello 日本語`, including owned-window pixel evidence, then failed waiting for Return commit. Final pixels and later Escape/cancellation acceptance remain uncompleted.

The final diagnostic run verified Return down/up dispatch, `handleEvent=true`, no interpret fallback, focused/composing state still true, accepted sequence11, no pending batch, and commit count0 at the limit. The root cause remains undetermined. Input-source restoration and session-close ACKs were received; the failure path then panicked with SIGABRT (-6). This is not a normal app exit or a passing acceptance result. No owned app process remained after the runs.

The archive was self-reviewed for publication by the primary agent. No independent subagent review was performed for this manual run. Helper compilation, Python syntax, repository diff hygiene, byte-for-byte archive checks, and patch/tree reconstruction are publication checks; they do not turn the failed runtime result Green.

Compiled executables, toolchains, and profile archives are omitted. The original `evidence-sha256.json` describes the original run and includes some omitted binaries. `published-files-sha256.json` covers the files included here, excluding itself. Screenshot PNGs contain the owned synthetic fixture window only. No credentials or complete process environment are archived.

The directory's `.gitattributes` disables whitespace checks only for `tested-source.diff`, whose serialized context lines include intentional single-space empty lines. The patch bytes are preserved and reconstruction verifies the tested tree. [SELF-REVIEW.md](SELF-REVIEW.md) records the archive review and limitations of the historical wrappers.

This remains WIP and draft while the Return commit issue and the original PR's required acceptance gates are unresolved.
