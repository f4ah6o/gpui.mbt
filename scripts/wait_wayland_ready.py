#!/usr/bin/env python3
"""Bounded protocol readiness for the test-owned Weston compositor.

Socket creation alone is not readiness. This helper requires a successful
wayland-info roundtrip while the child remains live, within a monotonic budget.
It does not create sockets, start a compositor, or run any rendering tests.
"""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from collections.abc import Callable


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def socket_is_ready(path: Path) -> bool:
    return path.is_socket()


def protocol_roundtrip(timeout_seconds: float) -> bool:
    try:
        result = subprocess.run(
            ["wayland-info"], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=timeout_seconds, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def wait_for_ready(
    pid: int, socket_path: Path, timeout_seconds: float = 30.0, *,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    is_alive: Callable[[int], bool] = process_alive,
    socket_ready: Callable[[Path], bool] = socket_is_ready,
    roundtrip: Callable[[float], bool] = protocol_roundtrip,
    diagnostic: Callable[[str], None] | None = None,
) -> bool:
    if pid <= 0 or not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("positive PID and finite positive timeout required")
    def fail(reason: str) -> bool:
        if diagnostic is not None:
            diagnostic(reason)
        return False

    start = clock()
    if not math.isfinite(start):
        return fail("Wayland readiness clock is invalid")
    previous = start
    probe_attempted = False
    while True:
        now = clock()
        if not math.isfinite(now) or now < previous:
            return fail("Wayland readiness clock is invalid or reversed")
        if now - start >= timeout_seconds:
            detail = "protocol roundtrip failed" if probe_attempted else "socket unavailable"
            return fail(f"Wayland readiness timeout: {detail}")
        previous = now
        if not is_alive(pid):
            return fail("Wayland readiness failed: compositor exited")
        if socket_ready(socket_path):
            # A probe may consume its whole timeout. Recheck both time and child
            # liveness before admitting tests, even when the probe exits zero.
            probe_attempted = True
            remaining = timeout_seconds - (now - start)
            ready = roundtrip(min(1.0, remaining))
            now = clock()
            if not is_alive(pid):
                return fail("Wayland readiness failed: compositor exited during protocol probe")
            if not math.isfinite(now) or now < previous:
                return fail("Wayland readiness clock is invalid or reversed")
            if now - start >= timeout_seconds:
                return fail("Wayland readiness timeout: protocol roundtrip exceeded deadline")
            previous = now
            if ready:
                return True
        remaining = timeout_seconds - (now - start)
        sleep(min(0.05, remaining))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    args = parser.parse_args()
    if not shutil.which("wayland-info"):
        print("Wayland readiness requires wayland-info protocol probe", file=sys.stderr)
        return 1
    try:
        ready = wait_for_ready(
            args.pid, args.socket, args.timeout_seconds,
            diagnostic=lambda message: print(message, file=sys.stderr),
        )
    except (ValueError, OSError) as error:
        print(f"Wayland readiness failed: {error}", file=sys.stderr)
        return 1
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
