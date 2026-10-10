#!/usr/bin/env python3
"""Run the Ubuntu benchmark, then exactly one bounded diagnostic on failure.

The benchmark result remains authoritative. The diagnostic replays the lifecycle
E2E at both configured integer scales and cannot change the benchmark status.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Callable


ROOT = Path(__file__).resolve().parents[1]
RunProcess = Callable[..., subprocess.CompletedProcess[bytes]]
BENCHMARK_TIMEOUT_SECONDS = 480
DIAGNOSTIC_TIMEOUT_SECONDS = 480
TIMEOUT_KILL_GRACE = "10s"


def _shell_status(returncode: int) -> int:
    return returncode if returncode >= 0 else 128 + -returncode


def _bounded_command(command: list[str], timeout_seconds: int) -> list[str]:
    """Bound a command and its child process group with GNU coreutils timeout."""
    return [
        "timeout",
        "--kill-after=" + TIMEOUT_KILL_GRACE,
        f"{timeout_seconds}s",
        *command,
    ]


def run_benchmark_with_failure_trace(
    benchmark_command: list[str],
    trace_command: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    run_process: RunProcess = subprocess.run,
) -> int:
    """Return the benchmark status; exactly one failure-only trace cannot mask it."""
    base_env = dict(os.environ if env is None else env)
    base_env.pop("GPUI_WAYLAND_TRACE", None)
    base_env.pop("GPUI_UBUNTU_E2E_STAGE_TRACE", None)
    base_env.pop("WAYLAND_DEBUG", None)
    try:
        benchmark = run_process(benchmark_command, cwd=cwd, env=base_env, check=False)
    except OSError as error:
        print(f"Ubuntu benchmark could not start: {error}", file=sys.stderr)
        return 127

    benchmark_status = _shell_status(benchmark.returncode)
    if benchmark_status == 0:
        return 0

    trace_env = base_env.copy()
    trace_env["GPUI_WAYLAND_TRACE"] = "1"
    trace_env["GPUI_UBUNTU_E2E_STAGE_TRACE"] = "1"
    try:
        trace = run_process(trace_command, cwd=cwd, env=trace_env, check=False)
        print(
            f"GPUI_UBUNTU_DIAGNOSTIC_STATUS={trace.returncode}; "
            f"preserving benchmark exit={benchmark_status}",
            file=sys.stderr,
        )
    except OSError as error:
        print(
            f"GPUI_UBUNTU_DIAGNOSTIC_START_FAILED={error}; "
            f"preserving benchmark exit={benchmark_status}",
            file=sys.stderr,
        )
    return benchmark_status


def main() -> int:
    benchmark = _bounded_command(
        [
            sys.executable,
            str(ROOT / "scripts/benchmark_ubuntu.py"),
            "--output",
            str(ROOT / "_build/ubuntu-bench/report.json"),
        ],
        BENCHMARK_TIMEOUT_SECONDS,
    )
    diagnostic = _bounded_command(
        ["sh", str(ROOT / "scripts/capture_ubuntu_wayland_trace.sh")],
        DIAGNOSTIC_TIMEOUT_SECONDS,
    )
    return run_benchmark_with_failure_trace(benchmark, diagnostic, cwd=ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
