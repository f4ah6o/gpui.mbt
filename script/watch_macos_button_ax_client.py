#!/usr/bin/env python3
"""Bound the standalone AX client and signal only the PID launched by its harness."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import time
from pathlib import Path


def process_state(pid: int) -> str:
    try:
        result = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)],
            check=False,
            capture_output=True,
            text=True,
            timeout=1.0,
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        return "?"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--done", required=True, type=Path)
    parser.add_argument("--fired", required=True, type=Path)
    args = parser.parse_args()
    if args.pid <= 0 or args.timeout_seconds <= 0:
        parser.error("pid and timeout must be positive")

    deadline = time.monotonic() + args.timeout_seconds
    while time.monotonic() < deadline:
        if args.done.exists():
            return 0
        time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    if args.done.exists():
        return 0

    state = process_state(args.pid)
    if not state or "Z" in state:
        return 0
    try:
        os.kill(args.pid, signal.SIGTERM)
    except ProcessLookupError:
        return 0
    args.fired.touch()
    time.sleep(0.5)
    state = process_state(args.pid)
    if state and "Z" not in state:
        try:
            os.kill(args.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
