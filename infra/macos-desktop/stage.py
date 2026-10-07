#!/usr/bin/env python3
"""Run one bounded, separately logged local Mac quality stage."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

TERM_GRACE_SECONDS = 18


def terminate(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        # The native IME collector uses SIGTERM to restore the selected
        # NSTextInputContext source before it exits. Leave enough bounded time
        # for its 8-second app acknowledgement and 5-second exit wait.
        proc.wait(timeout=TERM_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.timeout < 1 or not args.id.replace("-", "").isalnum():
        parser.error("provide a stage id, positive timeout and command after --")
    root = args.run_dir.resolve(strict=True)
    logs = root / "stages"
    logs.mkdir(exist_ok=True)
    log_path, result_path = logs / (args.id + ".log"), logs / (args.id + ".json")
    if log_path.exists() or result_path.exists():
        raise SystemExit("refusing to reuse an existing stage artifact: " + args.id)
    started = time.monotonic()
    started_at = dt.datetime.now(dt.timezone.utc).isoformat()
    with log_path.open("xb") as stream:
        stream.write(("COMMAND " + json.dumps(command) + "\n").encode())
        stream.flush()
        proc = subprocess.Popen(command, cwd=os.environ.get("GPUI_ACTRUN_REPO"),
                                stdout=stream, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            code = proc.wait(timeout=args.timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            terminate(proc)
            code, timed_out = proc.returncode, True
        except BaseException:
            terminate(proc)
            raise
    result = {"schema_version": 1, "id": args.id, "command": command,
              "started_at": started_at, "duration_seconds": round(time.monotonic() - started, 6),
              "timeout_seconds": args.timeout, "timed_out": timed_out,
              "exit_code": code, "status": "timed-out" if timed_out else "passed" if code == 0 else "failed",
              "log": str(log_path.relative_to(root))}
    result_path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in ("id", "status", "exit_code", "duration_seconds", "log")}))
    return 0 if code == 0 and not timed_out else code or 124


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("macos-stage: " + str(error), file=sys.stderr)
        sys.exit(1)
