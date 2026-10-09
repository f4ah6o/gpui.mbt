#!/usr/bin/env python3
"""Run one owned Wayland test client and retain a bounded lifecycle-only trace.

The caller must opt in with GPUI_WAYLAND_TRACE=1. Only requests/events from a
small presentation-lifecycle interface allowlist are retained, and all protocol
arguments are stripped before writing the trace. stdout is inherited unchanged.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import BinaryIO, Iterator


DEFAULT_MAX_BYTES = 256 * 1024
READ_CHUNK_BYTES = 4096
MAX_PROTOCOL_LINE_BYTES = 64 * 1024
TRACE_INTERFACES = frozenset(
    {
        "wl_display",
        "wl_registry",
        "wl_output",
        "wl_compositor",
        "wl_surface",
        "wl_callback",
        "wl_region",
        "wl_buffer",
        "wl_shm",
        "xdg_wm_base",
        "xdg_surface",
        "xdg_toplevel",
    }
)
WAYLAND_HEADER = re.compile(
    rb"^\s*(\[\s*[0-9]+(?:\.[0-9]+)?\s*\])\s+(->\s+)?"
    rb"([a-z][a-z0-9_]*)@([0-9]+)\.([a-z][a-z0-9_]*)\("
)


def sanitize_protocol_line(line: bytes) -> bytes | None:
    """Return a payload-free lifecycle record; discard input and other APIs."""
    match = WAYLAND_HEADER.match(line)
    if match is None or match.group(3).decode("ascii") not in TRACE_INTERFACES:
        return None
    timestamp, direction, interface, object_id, method = match.groups()
    arrow = direction.strip() if direction is not None else b"<-"
    return b" ".join((timestamp, arrow)) + b" " + interface + b"@" + object_id + b"." + method + b"\n"


def _append_bounded(tail: bytearray, data: bytes, max_bytes: int) -> None:
    if len(data) >= max_bytes:
        tail[:] = data[-max_bytes:]
        return
    tail.extend(data)
    if len(tail) > max_bytes:
        del tail[: len(tail) - max_bytes]


def _status_code(returncode: int) -> int:
    return returncode if returncode >= 0 else 128 + -returncode


def _bounded_lines(stream: BinaryIO) -> Iterator[bytes]:
    """Yield protocol lines without retaining an unbounded raw stderr line."""
    pending = bytearray()
    discarding = False
    while True:
        # read1 returns currently available pipe data instead of waiting to fill
        # the full chunk, so a quiet client cannot stall while emitting a trace.
        read_chunk = getattr(stream, "read1", None)
        if read_chunk is None:
            read_chunk = stream.read
        chunk = read_chunk(READ_CHUNK_BYTES)
        if not chunk:
            break
        start = 0
        while start < len(chunk):
            newline = chunk.find(b"\n", start)
            if newline < 0:
                segment = chunk[start:]
                if not discarding:
                    if len(pending) + len(segment) <= MAX_PROTOCOL_LINE_BYTES:
                        pending.extend(segment)
                    else:
                        pending.clear()
                        discarding = True
                break

            segment = chunk[start : newline + 1]
            if not discarding:
                if len(pending) + len(segment) <= MAX_PROTOCOL_LINE_BYTES:
                    pending.extend(segment)
                    yield bytes(pending)
            pending.clear()
            discarding = False
            start = newline + 1

    if pending and not discarding:
        yield bytes(pending)


def run_with_trace(
    command: list[str],
    output: Path,
    *,
    max_bytes: int = DEFAULT_MAX_BYTES,
    env: dict[str, str] | None = None,
) -> int:
    """Run a command, saving only sanitized stderr when explicitly enabled."""
    if max_bytes <= 0:
        raise ValueError("max_bytes must be positive")
    child_env = dict(os.environ if env is None else env)
    enabled = child_env.get("GPUI_WAYLAND_TRACE") == "1"
    if enabled:
        child_env["WAYLAND_DEBUG"] = "client"
    else:
        child_env.pop("WAYLAND_DEBUG", None)

    if not enabled:
        try:
            return _status_code(subprocess.run(command, env=child_env, check=False).returncode)
        except OSError as error:
            print(f"Wayland diagnostic command could not start: {error}", file=sys.stderr)
            return 127

    tail = bytearray()
    try:
        process = subprocess.Popen(
            command,
            env=child_env,
            stdout=None,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        print(f"Wayland diagnostic command could not start: {error}", file=sys.stderr)
        return 127

    assert process.stderr is not None
    with process.stderr:
        for line in _bounded_lines(process.stderr):
            sanitized = sanitize_protocol_line(line)
            if sanitized is not None:
                _append_bounded(tail, sanitized, max_bytes)
    status = _status_code(process.wait())

    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(tail)
        print(f"GPUI_WAYLAND_TRACE_FILE={output} bytes={len(tail)}", file=sys.stderr)
    except OSError as error:
        # This is an auxiliary diagnostic. Never replace the test's exit code.
        print(f"Wayland diagnostic trace could not be saved: {error}", file=sys.stderr)
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("a command is required after --")
    return run_with_trace(command, args.output, max_bytes=args.max_bytes)


if __name__ == "__main__":
    raise SystemExit(main())
