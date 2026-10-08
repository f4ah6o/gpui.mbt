# Virtual HID Kotoeri E2E (opt-in test path)

This path uses the already-installed, enabled Karabiner Virtual HID driver.
It does not install a driver, add launchd jobs, change production behavior, or
replace the standard NSTextView control. The reviewed driver source commit is
`072fa83e824c1b633f508f60cbad87b41aab3047` (package 8.6.0 / protocol 7).

Build helpers without sudo:

```sh
bash infra/macos-desktop/virtual-hid/build.sh DRIVER_CHECKOUT FRESH_EXTERNAL_HELPER_DIRECTORY
```

Build a fresh TextField bundle with the qualified external quality profile,
using `script/build_and_run.sh --demo text-field --test-hooks --build`.
Then run from the user's Terminal:

```sh
sudo /bin/bash infra/macos-desktop/virtual-hid/run-root.sh APP_BUNDLE PROFILE HELPER_BUILD EVIDENCE_PARENT
```

The runner prints a fresh `product.*` directory. Do not type, change input source,
or change focus while it runs. No human transcription of the evidence path is
needed. The fixed sequence is `nihongo`, Space, **one Return**, `n`, Escape.
Root authentication is required by the installed driver daemon. No secret or
password is handled by the collector. The runner starts/stops only its own
transient daemon, retaining an existing daemon and the installed driver.

`GPUI_TEST_HID_SOCKET` and `GPUI_TEST_HID_PRODUCER_PID` select the new producer
only in `GPUI_TESTING` builds. Without these settings the original app-local
CGEvent-backed NSEvent producer is unchanged. The native client verifies a root
socket peer and the exact producer PID; the producer verifies the GUI UID, exact
collector-spawned app PID (0600 PID file), executable, window, source and console
session. A GUI-user probe checks TIS selection before every key pair; root's TIS
selection is not used as evidence.

The producer queues two real scheduler records before acknowledging a request.
`down_posted` / `up_posted` describe that enqueue, **not** OS delivery. It emits
actual HID reports independently of GPUI ACKs, releasing each key after 50ms.
GPView dispatch completion is recorded only after the real received event passes
root report / nonce / timestamp / metadata / characters / owner / session /
phase-order checks and the existing dispatch function returns. Unknown, stale,
wrong-source or out-of-order keys invalidate the run. The machine-qualified
metadata guard expects source PID 0, HID state 1, user data 0, keyboard type 40,
and flags 256, as observed in the passing independent Virtual HID control.
Event timestamps are compared in the awake uptime domain; diagnostic elapsed
time remains CLOCK_MONOTONIC, with both clock values retained.
Other devices/OS configurations need a new independently qualified control.

No event is rewritten or replaced, no callbacks or ACKs are fabricated, no
recursive event pumping is introduced, and the 200-iteration operation limit
and every existing MoonBit / Python acceptance predicate remain intact.
The synchronous IPC wait is bounded to 1 second and acknowledges enqueue before
input is scheduled; it never waits for composition or ACK completion.

`run-user.py` invokes the existing collector and all three screenshot handshakes.
Its standalone summary is insufficient to qualify this producer. `validate.py`
additionally requires exactly 11 authenticated pairs, 22 actual report/receipt
records, source/target probes, producer completion, source restoration and
owned-process cleanup, then runs the existing independent artifact validator.
Only their combined pass may qualify the live E2E; a standard-control pass or
dry-run never qualifies. Package/build/format checks are required separately.

Public event metadata does not expose a unique physical keyboard device ID.
The evidence binds the controlled root producer's reports to received events;
it does not claim physical hardware provenance. Do not mix other input during
this automated run.
