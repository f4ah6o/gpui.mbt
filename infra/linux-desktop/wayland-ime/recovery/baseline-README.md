# New native IME recovery baseline utilities

`baseline_utilities.py` is a new, minimal implementation of read-only
APIs used by the published native Wayland IME probes. It is not the
lost historical helper and does not claim its old SHA-256 or qualification.
Its complete source has no private absolute build-path dependency.

- `MOZC_CONFIG`: private active-on-launch Hiragana `mozc-jp` engine config.
- `stat_identity(pid)`: checked current-effective-user UID/PID, Linux starttime, and executable
  identity; repeat reads reject PID, executable, or ownership races.
- `ipc_pid(bytes)`: complete pinned Linux Mozc `IPCPathInfo` writer record.
- `capture_task_owner()` / `verify_task_owner(owner)`: stable current native
  caller UID/PID/starttime/executable captured before any private runtime or
  child exists, then checked against that same caller at each live operation.
- `require_fresh_peer(pid, owner, expected_exe=None)`: launched root, UI or IPC
  peer must have the caller UID and a birth tick at or after the caller. The
  caller itself cannot be its own descendant; preexisting services cannot be
  adopted.
- `private_processes(token, home, config, owner, audit=None)`: exact nonce and
  private HOME/config matches within this new task's birth scope. It reads
  identities only; the caller retains pidfd-only signaling decisions.
- `validate_task_owner_receipt(root, report, require_cleanup=True)`: pure
  snapshot/report/hash, peer-ledger and scoped-census replay. It never checks
  current PIDs. The pre-cleanup phase explicitly uses `require_cleanup=False`;
  a passing final receipt requires the complete task-scoped cleanup census.

The IPC grammar is independently derived from the verified official source
package for Mozc `2.29.5160.102+dfsg-1.4`: `src/ipc/ipc.proto`,
`src/ipc/ipc_path_manager.cc::SavePathName`, `src/ipc/ipc.h` (protocol 3), and
`src/base/process_mutex.cc` (raw message write). All five optional fields are
explicitly written by that exact server. This bounded recovery profile rejects
missing, duplicate, unknown, malformed, overlong, oversized, or wrong-wire fields,
and requires the exact pinned product version, protocol 3, Linux thread ID 0,
valid lowercase-hex IPC key, and a nonzero positive Linux PID. It neither
implements an IPC connection nor changes Mozc's executable-identity checks.

Process scanning is restricted to the current effective user and returns only
the exact token plus private sibling HOME/config pair. Repeated stable
UID/PID/starttime records exclude strictly older births before environment
access. The current caller is explicitly excluded and audited. Same-tick and
newer live unreadable, malformed or racing entries remain errors. Terminal
groups are excluded only with repeated complete stat/status/task proof of a
single stable Z task; zero/multiple threads or missing metadata are ambiguous.
Directory ownership,
exclusive permissions, direct paths, unique environment ownership keys,
bounded reads, and repeated process/environment identities are checked.
Same-scope read errors fail closed. Missing metadata while the numeric PID
still exists never establishes exit. The scan is limited to 4096 inventory
entries and 8 seconds; reaching either bound records an incomplete census and
fails closed without materializing an unbounded process list.
No name-based process matching, signaling, service launch, or desktop input is
available in this module. Caller tests use fake proc trees and one read-only
identity check of the current test process.

Run static tests from this directory:

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_baseline_utilities test_task_owner_scope -v
```

These checks establish the helper contract only. Independent source/pin review,
a fresh exact-source app build and deployment manifest, and authorized private
native qualification are required before this replacement can be admitted to
the native test route. Historical deployment and qualification files remain
unchanged. The strict Gio parser has its own separate source/tests/manifest.
The recorded cleanup claim covers this fresh task's descendants only. It never
claims all same-user processes were cleaned or retroactively verifies an older
runtime; earlier cleanup-unverified evidence stays unverified.
