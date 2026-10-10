#!/usr/bin/env python3
"""Run a fixed paired Weston comparison without adaptive failure retries.

Each revision is tested six times at both integer scales on the same GitHub
Actions runner. The comparison is evidence collection, not a replacement for
the normal benchmark result or its single failure-only diagnostic.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import platform
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

try:
    from .benchmark_ubuntu import SCENARIO as BENCHMARK_SCENARIO
    from .benchmark_ubuntu import parse_sample_line
except ImportError:  # Direct `python scripts/compare_ubuntu_revisions.py` entry point.
    from benchmark_ubuntu import SCENARIO as BENCHMARK_SCENARIO
    from benchmark_ubuntu import parse_sample_line


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_BASELINE_SHA = "9c70225ddcee70385b64ee24f207ec0755b2b49f"
EXPECTED_BRANCH = "codex/linux-six-pr-integration-20261011"
PAIR_COUNT = 6
SCALES = (1, 2)
COMPARISON_BUDGET_SECONDS = 60 * 60
ATTEMPT_TIMEOUT_SECONDS = 180
KILL_GRACE_SECONDS = 10
MAX_STREAM_LOG_BYTES = 1024 * 1024
MAX_WESTON_LOG_BYTES = 512 * 1024
HEAD_LOG_BYTES = 768 * 1024
TRUNCATION_MARKER = b"\n[comparison log truncated; middle omitted]\n"
TAIL_LOG_BYTES = MAX_STREAM_LOG_BYTES - HEAD_LOG_BYTES - len(TRUNCATION_MARKER)
READ_CHUNK_BYTES = 32 * 1024
EXPECTED_SAMPLES_PER_SCALE = 30
PAIR_COMPLETED_ATTEMPT_STATUSES = frozenset(
    {"passed", "failed", "timed_out", "invalid_measurement"}
)

COMMON_HARNESS_FILES = (
    "scripts/test_ubuntu.sh",
    "scripts/test_ubuntu_ingress.sh",
    "scripts/prepare_ubuntu.sh",
    "scripts/wait_wayland_ready.py",
    "scripts/create_field_fixture_run.sh",
    "scripts/encode_field_fixtures.py",
    "script/linux_text_cc.py",
    "tests/ubuntu/backend_test.c",
    "tests/ubuntu/field_gpu_test.c",
    "tests/ubuntu/direct_text_test.c",
    "tests/ubuntu/key_repeat_test.c",
    "tests/ubuntu/ime_transport_test.c",
)
COMMON_TEST_GLOBS = (
    "ubuntu/*_wbtest.mbt",
    "examples/linux_text_field/*_wbtest.mbt",
    "examples/ubuntu_button/*_wbtest.mbt",
    "examples/ubuntu_button/fixture/*_wbtest.mbt",
)


@dataclass(frozen=True)
class PlannedAttempt:
    ordinal: int
    pair: int
    scale: int
    revision: str


def build_attempt_plan(pair_count: int = PAIR_COUNT) -> list[PlannedAttempt]:
    """Build six complete pairs per scale with alternating revision order."""
    if pair_count <= 0:
        raise ValueError("pair_count must be positive")
    plan: list[PlannedAttempt] = []
    for pair in range(1, pair_count + 1):
        scale_order = SCALES if pair % 2 else tuple(reversed(SCALES))
        for scale in scale_order:
            # Alternate order both across pairs for each scale and between the
            # two scales within a pair to reduce simple time/order confounding.
            baseline_first = (pair + scale) % 2 == 0
            revisions = ("baseline", "candidate") if baseline_first else ("candidate", "baseline")
            for revision in revisions:
                plan.append(PlannedAttempt(len(plan) + 1, pair, scale, revision))
    return plan


def validate_invocation(
    *,
    event_name: str,
    event_action: str,
    ref_name: str,
    github_sha: str,
    candidate_sha: str,
    baseline_sha: str,
    pull_request_head_ref: str = "",
    pull_request_head_repo: str = "",
) -> None:
    """Require an opened integration PR or exact-head manual dispatch."""
    if baseline_sha != EXPECTED_BASELINE_SHA:
        raise ValueError("baseline must be the pinned public #53 head")
    if not re.fullmatch(r"[0-9a-f]{40}", candidate_sha):
        raise ValueError("candidate_sha must be a full lowercase commit SHA")
    if event_name == "pull_request":
        if event_action != "opened":
            raise ValueError("pull_request comparison is allowed only on opened")
        if pull_request_head_ref != EXPECTED_BRANCH:
            raise ValueError("pull_request head branch does not match integration branch")
        if pull_request_head_repo != "gpui-mbt/gpui.mbt":
            raise ValueError("pull_request head must be the repository-owned integration branch")
        if github_sha != candidate_sha:
            raise ValueError("PR candidate SHA does not match the workflow event head")
    elif event_name == "workflow_dispatch":
        if ref_name != EXPECTED_BRANCH:
            raise ValueError("manual comparison must dispatch from the integration branch")
        if github_sha != candidate_sha:
            raise ValueError("manual candidate SHA must equal the selected ref head")
    else:
        raise ValueError("comparison is available only for PR-opened or manual dispatch")


def _git(args: list[str], *, cwd: Path = ROOT) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def _git_is_ancestor(ancestor_sha: str, descendant_sha: str, *, cwd: Path = ROOT) -> bool:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor_sha, descendant_sha],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.returncode == 0


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temp.replace(path)


def _bounded_copy(source: Path, destination: Path, max_bytes: int) -> dict[str, Any]:
    """Copy a file with a source digest while retaining both ends under a cap."""
    size = source.stat().st_size
    digest = hashlib.sha256()
    with source.open("rb") as stream:
        for chunk in iter(lambda: stream.read(64 * 1024), b""):
            digest.update(chunk)
        stream.seek(0)
        if size <= max_bytes:
            data = stream.read(max_bytes + 1)
        else:
            marker = b"\n[Weston log truncated; middle omitted]\n"
            if max_bytes <= len(marker):
                raise ValueError("Weston log retention cap is too small for a truncation marker")
            available = max_bytes - len(marker)
            head_bytes = available // 2
            tail_bytes = available - head_bytes
            head = stream.read(head_bytes)
            stream.seek(size - tail_bytes)
            tail = stream.read(tail_bytes)
            data = head + marker + tail
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return {
        "source_bytes": size,
        "retained_bytes": len(data),
        "truncated": size > len(data),
        "source_sha256": digest.hexdigest(),
    }


def _bounded_readonly(command: list[str], timeout: int = 15) -> str:
    try:
        result = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, check=False, timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unavailable: {error}"
    return result.stdout.strip()[-8192:] or f"exit={result.returncode}"


def collect_environment_metadata() -> dict[str, Any]:
    """Record only allowlisted environment details; read core policy, never change it."""
    native_packages = [
        "build-essential", "pkg-config", "libwayland-dev", "wayland-protocols",
        "libegl1-mesa-dev", "libgles2-mesa-dev", "libxkbcommon-dev",
        "libgl1-mesa-dri", "adwaita-icon-theme", "wayland-utils", "weston",
        "libpango1.0-dev", "libfontconfig1-dev", "fontconfig",
        "fonts-dejavu-core", "fonts-noto-cjk", "fonts-noto-color-emoji",
    ]
    try:
        core_pattern = Path("/proc/sys/kernel/core_pattern").read_text(encoding="utf-8").strip()
    except OSError as error:
        core_pattern = f"unavailable: {error}"
    return {
        "runner": {
            "github_runner_os": os.environ.get("RUNNER_OS", "unknown"),
            "github_runner_arch": os.environ.get("RUNNER_ARCH", "unknown"),
            "job": os.environ.get("GITHUB_JOB", "unknown"),
            "workflow_run_id": os.environ.get("GITHUB_RUN_ID", "unknown"),
            "workflow_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "unknown"),
            "workflow_event": os.environ.get("GITHUB_EVENT_NAME", "unknown"),
            "workflow_event_action": os.environ.get("GITHUB_EVENT_ACTION", "unknown"),
            "workflow_ref": os.environ.get("GITHUB_REF", "unknown"),
            "workflow_event_sha": os.environ.get("GITHUB_SHA", "unknown"),
            "comparison_event_sha": os.environ.get("GPUI_COMPARISON_EVENT_SHA", "unknown"),
            "pull_request_head_ref": os.environ.get("GPUI_PULL_REQUEST_HEAD_REF", "unknown"),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_model": _bounded_readonly(
                ["awk", "-F:", "$1 ~ /model name/ {gsub(/^ +/, \"\", $2); print $2; exit}", "/proc/cpuinfo"]
            ),
        },
        "toolchain": {
            "moon": _bounded_readonly(["moon", "version", "--all"]),
            "weston": _bounded_readonly(["weston", "--version"]),
            "compiler": _bounded_readonly(["cc", "--version"]).splitlines()[0],
            "wayland_protocols": _bounded_readonly(["pkg-config", "--modversion", "wayland-protocols"]),
            "wayland_client": _bounded_readonly(["pkg-config", "--modversion", "wayland-client"]),
            "egl": _bounded_readonly(["pkg-config", "--modversion", "egl"]),
            "native_packages": _bounded_readonly(
                ["dpkg-query", "-W", "-f=${binary:Package}=${Version}\n", *native_packages]
            ),
        },
        "backtrace_feasibility": {
            "core_limit_readonly": _bounded_readonly(["sh", "-c", "ulimit -c"]),
            "core_pattern_readonly": core_pattern,
            "gdb_available": shutil.which("gdb") is not None,
            "backtrace_attempted": False,
            "backtrace_reason": "No core/debugger settings were changed and no replay/attach was performed.",
        },
    }


def _install_common_harness(baseline: Path, candidate: Path) -> dict[str, Any]:
    """Overlay the same baseline test driver on both revisions, plus scale selection."""
    harness_files = list(COMMON_HARNESS_FILES)
    for pattern in COMMON_TEST_GLOBS:
        harness_files.extend(
            path.relative_to(baseline).as_posix()
            for path in sorted(baseline.glob(pattern))
            if path.is_file()
        )
    harness_files = sorted(set(harness_files))
    original_file_hashes: dict[str, str] = {}
    original_file_modes: dict[str, int] = {}
    for relative in harness_files:
        src = baseline / relative
        dst = candidate / relative
        if not src.is_file():
            raise RuntimeError(f"baseline harness file is missing: {relative}")
        original_file_hashes[relative] = hashlib.sha256(src.read_bytes()).hexdigest()
        original_file_modes[relative] = stat.S_IMODE(src.stat().st_mode)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        dst.chmod(original_file_modes[relative])
    for pattern in COMMON_TEST_GLOBS:
        baseline_paths = {
            path.relative_to(baseline).as_posix()
            for path in baseline.glob(pattern)
            if path.is_file()
        }
        for path in candidate.glob(pattern):
            if path.is_file() and path.relative_to(candidate).as_posix() not in baseline_paths:
                path.unlink()

    script = (baseline / "scripts/test_ubuntu.sh").read_text(encoding="utf-8")
    loop = "for scale in 1 2; do"
    if script.count(loop) != 1:
        raise RuntimeError("baseline test driver scale loop was not unique")
    selection = '''case "${GPUI_UBUNTU_ONLY_SCALE:-}" in
  "") ubuntu_scales="1 2" ;;
  1|2) ubuntu_scales="$GPUI_UBUNTU_ONLY_SCALE" ;;
  *) printf 'GPUI_UBUNTU_ONLY_SCALE must be 1 or 2\\n' >&2; exit 2 ;;
esac
comparison_stage() {
  if [ "${GPUI_UBUNTU_RECORD_WESTON_EXIT:-0}" = 1 ]; then
    printf 'GPUI_COMPARISON_STAGE id=%s scale=%s\\n' "$1" "${scale:-0}" >&2
  fi
}
comparison_stage preflight
'''
    script = script.replace("cd \"$(dirname \"$0\")/..\"\n", "cd \"$(dirname \"$0\")/..\"\n" + selection, 1)
    script = script.replace(loop, "for scale in $ubuntu_scales; do", 1)
    old_cleanup = '''cleanup() {
  if [ -n "$compositor_pid" ]; then kill "$compositor_pid" 2>/dev/null || true; wait "$compositor_pid" 2>/dev/null || true; fi
  rm -rf "$runtime"
}
trap cleanup EXIT HUP INT TERM'''
    new_cleanup = '''cleanup() {
  if [ -n "$compositor_pid" ]; then
    cleanup_pid=$compositor_pid
    alive_before_cleanup=false
    if kill -0 "$cleanup_pid" 2>/dev/null; then
      alive_before_cleanup=true
      kill "$cleanup_pid" 2>/dev/null || true
    fi
    set +e
    wait "$cleanup_pid"
    cleanup_status=$?
    set -e
    if [ "${GPUI_UBUNTU_RECORD_WESTON_EXIT:-0}" = 1 ]; then
      printf 'GPUI_WESTON_CLEANUP_STATUS stage=shell_cleanup exit=%s alive_before_cleanup=%s\\n' \\
        "$cleanup_status" "$alive_before_cleanup" >&2
    fi
    compositor_pid=
  fi
  rm -rf "$runtime"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM'''
    if script.count(old_cleanup) != 1:
        raise RuntimeError("baseline Weston cleanup block was not unique")
    script = script.replace(old_cleanup, new_cleanup, 1)
    stage_replacements = (
        ("sh scripts/prepare_ubuntu.sh\n", "comparison_stage prepare_native\nsh scripts/prepare_ubuntu.sh\n"),
        ("_build/ubuntu-e2e/backend-test --clipboard-unit\n", "comparison_stage clipboard_unit\n_build/ubuntu-e2e/backend-test --clipboard-unit\n"),
        ("sh scripts/test_ubuntu_ingress.sh\n", "comparison_stage wayland_ingress_unit\nsh scripts/test_ubuntu_ingress.sh\n"),
        ("  weston --backend=headless-backend.so", "  comparison_stage weston_start\n  weston --backend=headless-backend.so"),
        ("  if ! python3 scripts/wait_wayland_ready.py", "  comparison_stage wayland_ready\n  if ! python3 scripts/wait_wayland_ready.py"),
        ("  set +e\n  GPUI_UBUNTU_E2E=1 timeout 120 moon test ubuntu", "  comparison_stage ubuntu_native_tests\n  set +e\n  GPUI_UBUNTU_E2E=1 timeout 120 moon test ubuntu"),
        ("  GPUI_UBUNTU_SMOKE=1 timeout 30 moon run examples/ubuntu", "  comparison_stage ubuntu_example_smoke\n  GPUI_UBUNTU_SMOKE=1 timeout 30 moon run examples/ubuntu"),
        ("  GPUI_UBUNTU_BUTTON_SMOKE=1 timeout 30 moon run examples/ubuntu_button", "  comparison_stage ubuntu_button_smoke\n  GPUI_UBUNTU_BUTTON_SMOKE=1 timeout 30 moon run examples/ubuntu_button"),
        ("  GPUI_FIELD_E2E=1 timeout 120 moon test examples/linux_text_field", "  comparison_stage text_field_native_tests\n  GPUI_FIELD_E2E=1 timeout 120 moon test examples/linux_text_field"),
        ("  GPUI_FIELD_SMOKE=1 timeout 30 moon run examples/linux_text_field", "  comparison_stage text_field_smoke\n  GPUI_FIELD_SMOKE=1 timeout 30 moon run examples/linux_text_field"),
        ("  GPUI_FIELD_FIXTURES_DIR=", "  comparison_stage field_frame_readback\n  GPUI_FIELD_FIXTURES_DIR="),
        ("  GPUI_UBUNTU_CAPTURE=", "  comparison_stage backend_disconnect\n  GPUI_UBUNTU_CAPTURE="),
    )
    for original, replacement in stage_replacements:
        if script.count(original) != 1:
            raise RuntimeError(f"baseline test driver stage anchor was not unique: {original!r}")
        script = script.replace(original, replacement, 1)
    # GNU timeout normally creates a separate process group for its command.
    # The outer comparison runner terminates each attempt by signaling the
    # driver's process group, so make timeout descendants share that group.
    # A finite kill-after also prevents an inner command from lingering if it
    # ignores the first timeout signal.
    script, timeout_commands_foregrounded = re.subn(
        r"(?<!\S)timeout (?=[0-9])",
        "timeout --foreground --kill-after=5s ",
        script,
    )
    if timeout_commands_foregrounded == 0:
        raise RuntimeError("baseline test driver has no supported GNU timeout invocations")
    final_wait = '  wait "$compositor_pid" || true\n  compositor_pid=\n'
    final_wait_instrumented = '''  set +e
  wait "$compositor_pid"
  weston_status=$?
  set -e
  if [ "${GPUI_UBUNTU_RECORD_WESTON_EXIT:-0}" = 1 ]; then
    printf 'GPUI_WESTON_STATUS stage=backend_disconnect exit=%s\\n' "$weston_status" >&2
  fi
  compositor_pid=
'''
    if script.count(final_wait) != 1:
        raise RuntimeError("baseline final Weston wait was not unique")
    script = script.replace(final_wait, final_wait_instrumented, 1)
    data = script.encode("utf-8")
    for worktree in (baseline, candidate):
        target = worktree / "scripts/test_ubuntu.sh"
        target.write_bytes(data)
        target.chmod(0o755)
    common_file_hashes = {
        relative: hashlib.sha256((baseline / relative).read_bytes()).hexdigest()
        for relative in harness_files
    }
    common_file_modes = {
        relative: stat.S_IMODE((baseline / relative).stat().st_mode)
        for relative in harness_files
    }
    bundle = hashlib.sha256()
    for relative, digest in sorted(common_file_hashes.items()):
        bundle.update(relative.encode("utf-8"))
        bundle.update(b"\0")
        bundle.update(digest.encode("ascii"))
        bundle.update(b"\0")
        bundle.update(oct(common_file_modes[relative]).encode("ascii"))
        bundle.update(b"\0")
    return {
        "files": harness_files,
        "baseline_source_file_sha256": original_file_hashes,
        "baseline_source_file_modes": original_file_modes,
        "common_overlay_file_sha256": common_file_hashes,
        "common_overlay_file_modes": common_file_modes,
        "common_overlay_bundle_sha256": bundle.hexdigest(),
        "comparison_driver_instrumentation_sha256": hashlib.sha256(data).hexdigest(),
        "timeout_commands_foregrounded": timeout_commands_foregrounded,
    }


class _StreamCapture:
    def __init__(self, path: Path):
        self.path = path
        self.head = bytearray()
        self.tail = bytearray()
        self.total = 0
        self.line_buffer = bytearray()
        self.sample_counts: collections.Counter[int] = collections.Counter()
        self.sample_indices: dict[int, set[int]] = {1: set(), 2: set()}
        self.sample_renderers: dict[int, set[str]] = {1: set(), 2: set()}
        self.invalid_sample_record_count = 0
        self.complete_count = 0
        self.valid_complete_count = 0
        self.invalid_complete_count = 0
        self.last_stage: dict[str, Any] | None = None
        self.weston_exit_observations: list[dict[str, Any]] = []
        self.weston_alive_after_failure: list[bool] = []
        self.weston_cleanup_observations: list[dict[str, Any]] = []

    def append(self, chunk: bytes) -> None:
        self.total += len(chunk)
        if len(self.head) < HEAD_LOG_BYTES:
            take = min(HEAD_LOG_BYTES - len(self.head), len(chunk))
            self.head.extend(chunk[:take])
        self.tail.extend(chunk)
        if len(self.tail) > TAIL_LOG_BYTES:
            del self.tail[: len(self.tail) - TAIL_LOG_BYTES]
        self.line_buffer.extend(chunk)
        while b"\n" in self.line_buffer:
            line, _, rest = self.line_buffer.partition(b"\n")
            self.line_buffer[:] = rest
            self._inspect_line(line)
        if len(self.line_buffer) > 64 * 1024:
            self.line_buffer.clear()

    def _inspect_line(self, line: bytes) -> None:
        if line.startswith(b"GPUI_BENCH_SAMPLE "):
            try:
                parsed = parse_sample_line(line.decode("utf-8", errors="strict"))
            except (UnicodeDecodeError, ValueError):
                self.invalid_sample_record_count += 1
                return
            if parsed is None:
                self.invalid_sample_record_count += 1
                return
            scale = parsed["scale"]
            sample = parsed["sample"]
            self.sample_counts[scale] += 1
            if sample < 0 or sample >= EXPECTED_SAMPLES_PER_SCALE:
                self.invalid_sample_record_count += 1
            elif sample in self.sample_indices[scale]:
                self.invalid_sample_record_count += 1
            else:
                self.sample_indices[scale].add(sample)
            if len(self.sample_renderers[scale]) < 4:
                self.sample_renderers[scale].add(parsed["renderer"][:128])
        if line.startswith(b"GPUI_BENCH_COMPLETE "):
            self.complete_count += 1
            try:
                fields: dict[str, str] = {}
                for token in line[len(b"GPUI_BENCH_COMPLETE ") :].decode("ascii").split():
                    if "=" not in token:
                        raise ValueError("malformed completion token")
                    key, value = token.split("=", 1)
                    if not key or key in fields:
                        raise ValueError("duplicate completion field")
                    fields[key] = value
                if (
                    fields.get("scenario") == BENCHMARK_SCENARIO
                    and fields.get("samples_per_scale") == str(EXPECTED_SAMPLES_PER_SCALE)
                ):
                    self.valid_complete_count += 1
                else:
                    self.invalid_complete_count += 1
            except (UnicodeDecodeError, ValueError):
                self.invalid_complete_count += 1
        match = re.fullmatch(
            rb"GPUI_COMPARISON_STAGE id=([a-z0-9_]+) scale=(0|1|2)", line
        )
        if match:
            self.last_stage = {
                "id": match.group(1).decode("ascii"),
                "scale": int(match.group(2)),
            }
        match = re.fullmatch(
            rb"GPUI_WESTON_STATUS(?: stage=([a-z0-9_]+))? exit=(-?\d+)", line
        )
        if match:
            self.weston_exit_observations.append(
                {
                    "stage": match.group(1).decode("ascii") if match.group(1) else "moon_tests_failure",
                    "exit": int(match.group(2)),
                }
            )
        match = re.fullmatch(rb"GPUI_WESTON_STATUS alive_after_moon_failure=(true|false)", line)
        if match:
            self.weston_alive_after_failure.append(match.group(1) == b"true")
        match = re.fullmatch(
            rb"GPUI_WESTON_CLEANUP_STATUS(?: stage=([a-z0-9_]+))? exit=(-?\d+) alive_before_cleanup=(true|false)",
            line,
        )
        if match:
            self.weston_cleanup_observations.append(
                {
                    "stage": match.group(1).decode("ascii") if match.group(1) else "shell_cleanup",
                    "exit": int(match.group(2)),
                    "alive_before_cleanup": match.group(3) == b"true",
                }
            )

    def finish(self) -> dict[str, Any]:
        if self.line_buffer:
            self._inspect_line(bytes(self.line_buffer))
        if self.total <= HEAD_LOG_BYTES:
            data = bytes(self.head)
        else:
            overlap = max(0, len(self.head) + len(self.tail) - self.total)
            data = bytes(self.head) + TRUNCATION_MARKER + bytes(self.tail[overlap:])
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_bytes(data)
        return {
            "bytes_observed": self.total,
            "bytes_retained": len(data),
            "truncated": self.total > len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "sample_counts_by_scale": {str(k): v for k, v in sorted(self.sample_counts.items())},
            "sample_indices_by_scale": {
                str(k): sorted(v) for k, v in sorted(self.sample_indices.items())
            },
            "sample_renderers_by_scale": {
                str(k): sorted(v) for k, v in sorted(self.sample_renderers.items())
            },
            "invalid_sample_record_count": self.invalid_sample_record_count,
            "bench_complete_record_count": self.complete_count,
            "bench_complete_valid_count": self.valid_complete_count,
            "bench_complete_invalid_count": self.invalid_complete_count,
            "last_stage": self.last_stage,
            "weston_exit_observations": self.weston_exit_observations,
            "weston_alive_after_failure": self.weston_alive_after_failure,
            "weston_cleanup_observations": self.weston_cleanup_observations,
        }


def _signal_group(process: subprocess.Popen[bytes], signal_number: int) -> None:
    try:
        os.killpg(process.pid, signal_number)
    except ProcessLookupError:
        pass


def _measurement_is_valid(metadata: dict[str, Any], scale: int) -> bool:
    other_scale = 2 if scale == 1 else 1
    return (
        scale in SCALES
        and metadata["sample_counts_by_scale"].get(str(scale), 0) == EXPECTED_SAMPLES_PER_SCALE
        and metadata["sample_counts_by_scale"].get(str(other_scale), 0) == 0
        and metadata["sample_indices_by_scale"].get(str(scale), [])
        == list(range(EXPECTED_SAMPLES_PER_SCALE))
        and len(metadata["sample_renderers_by_scale"].get(str(scale), [])) == 1
        and metadata["invalid_sample_record_count"] == 0
        and metadata["bench_complete_record_count"] == 1
        and metadata["bench_complete_valid_count"] == 1
        and metadata["bench_complete_invalid_count"] == 0
    )


def _classify_attempt(
    *,
    timed_out: bool,
    spawn_error: str | None,
    returncode: int | None,
    measurement_valid: bool,
    weston_exit_statuses: list[int],
) -> str:
    if timed_out:
        return "timed_out"
    if spawn_error:
        return "could_not_start"
    if returncode != 0:
        return "failed"
    if 139 in weston_exit_statuses:
        return "failed"
    if not measurement_valid:
        return "invalid_measurement"
    return "passed"


def run_attempt(
    attempt: PlannedAttempt,
    worktree: Path,
    attempt_dir: Path,
    *,
    deadline: float,
) -> dict[str, Any]:
    sha = _git(["rev-parse", "HEAD"], cwd=worktree)
    expected_sha_file = attempt_dir / "revision.txt"
    expected_sha_file.parent.mkdir(parents=True, exist_ok=True)
    expected_sha_file.write_text(sha + "\n", encoding="utf-8")
    result: dict[str, Any] = {
        **asdict(attempt),
        "commit_sha": sha,
        "status": "running",
        "started_monotonic_seconds": None,
        "duration_seconds": None,
    }
    if time.monotonic() >= deadline:
        result["status"] = "not_run_budget_exhausted"
        return result

    log_path = worktree / "_build/ubuntu-e2e" / f"weston-scale-{attempt.scale}.log"
    try:
        log_path.unlink(missing_ok=True)
    except OSError as error:
        result.update(status="not_run_log_cleanup_failed", error=str(error))
        return result

    env = os.environ.copy()
    for name in ("GPUI_WAYLAND_TRACE", "GPUI_UBUNTU_E2E_STAGE_TRACE", "WAYLAND_DEBUG"):
        env.pop(name, None)
    env.update(
        GPUI_BENCH_UBUNTU="1",
        GPUI_UBUNTU_ONLY_SCALE=str(attempt.scale),
        GPUI_UBUNTU_RECORD_WESTON_EXIT="1",
        LANG="C.UTF-8",
        LC_ALL="C.UTF-8",
    )
    now = time.monotonic()
    # Reserve one TERM grace window before the overall comparison deadline.
    timeout = min(
        ATTEMPT_TIMEOUT_SECONDS,
        max(0, deadline - now - KILL_GRACE_SECONDS - 1),
    )
    if timeout <= 0:
        result["status"] = "not_run_budget_exhausted"
        return result
    started = time.time()
    result["started_utc_epoch_seconds"] = round(started, 3)
    start_monotonic = time.monotonic()
    result["started_monotonic_seconds"] = round(start_monotonic, 3)
    proc: subprocess.Popen[bytes] | None = None
    stdout = _StreamCapture(attempt_dir / "stdout.log")
    stderr = _StreamCapture(attempt_dir / "stderr.log")
    selector = selectors.DefaultSelector()
    timed_out = False
    terminate_deadline: float | None = None
    kill_close_deadline: float | None = None
    kill_sent = False
    spawn_error: str | None = None
    returncode: int | None = None
    try:
        proc = subprocess.Popen(
            ["sh", "scripts/test_ubuntu.sh"],
            cwd=worktree,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            bufsize=0,
        )
        assert proc.stdout is not None and proc.stderr is not None
        os.set_blocking(proc.stdout.fileno(), False)
        os.set_blocking(proc.stderr.fileno(), False)
        selector.register(proc.stdout, selectors.EVENT_READ, stdout)
        selector.register(proc.stderr, selectors.EVENT_READ, stderr)
        attempt_deadline = start_monotonic + timeout
        while proc.poll() is None or selector.get_map():
            current = time.monotonic()
            if current >= attempt_deadline and terminate_deadline is None:
                timed_out = True
                _signal_group(proc, signal.SIGTERM)
                terminate_deadline = current + KILL_GRACE_SECONDS
            elif terminate_deadline is not None and not kill_sent and current >= terminate_deadline:
                _signal_group(proc, signal.SIGKILL)
                kill_sent = True
                kill_close_deadline = current + 1
            elif kill_sent and kill_close_deadline is not None and current >= kill_close_deadline:
                for key in list(selector.get_map().values()):
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                break
            deadlines = [value for value in (attempt_deadline, terminate_deadline, kill_close_deadline) if value is not None]
            next_deadline = min(deadlines)
            wait_for = min(0.25, max(0.01, next_deadline - time.monotonic()))
            events = selector.select(timeout=wait_for)
            if not selector.get_map() and proc.poll() is None and not events:
                time.sleep(wait_for)
            for key, _ in events:
                stream = key.fileobj
                try:
                    chunk = stream.read(READ_CHUNK_BYTES)
                except BlockingIOError:
                    continue
                if chunk is None:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                else:
                    key.data.append(chunk)
            if proc.poll() is not None and not selector.get_map():
                break
        returncode = proc.wait()
    except OSError as error:
        spawn_error = str(error)
        if proc is not None and proc.poll() is None:
            _signal_group(proc, signal.SIGKILL)
            returncode = proc.wait()
    finally:
        selector.close()
        stdout_meta = stdout.finish()
        stderr_meta = stderr.finish()

    duration = time.monotonic() - start_monotonic
    result.update(
        duration_seconds=round(duration, 3),
        timed_out=timed_out,
        process_returncode=returncode,
        shell_returncode=(returncode if returncode is None or returncode >= 0 else 128 + -returncode),
        spawn_error=spawn_error,
        process_signal=(-returncode if returncode is not None and returncode < 0 else None),
        stdout=stdout_meta,
        stderr=stderr_meta,
    )
    sample_count = stdout_meta["sample_counts_by_scale"].get(str(attempt.scale), 0)
    result["expected_scale_sample_count"] = EXPECTED_SAMPLES_PER_SCALE
    result["observed_scale_sample_count"] = sample_count
    result["measurement_complete_record_count"] = stdout_meta["bench_complete_record_count"]
    result["measurement_valid"] = _measurement_is_valid(stdout_meta, attempt.scale)
    result["last_stage"] = stderr_meta["last_stage"] or stdout_meta["last_stage"]
    result["weston_exit_observations"] = stderr_meta["weston_exit_observations"]
    result["weston_exit_statuses"] = [
        item["exit"] for item in result["weston_exit_observations"]
    ]
    result["weston_alive_after_failure_observations"] = [
        "true" if value else "false" for value in stderr_meta["weston_alive_after_failure"]
    ]
    result["weston_cleanup"] = stderr_meta["weston_cleanup_observations"]
    result["weston_exit_statuses"].extend(
        item["exit"] for item in result["weston_cleanup"]
    )
    result["status"] = _classify_attempt(
        timed_out=timed_out,
        spawn_error=spawn_error,
        returncode=returncode,
        measurement_valid=result["measurement_valid"],
        weston_exit_statuses=result["weston_exit_statuses"],
    )
    if 139 in result["weston_exit_statuses"] and result["status"] == "failed":
        result["status_reason"] = "weston_exit_139_observed"
        if returncode == 0:
            result["status_detail"] = "Weston exited 139 although the test driver returned zero"
    result["weston_log_copied"] = False
    if log_path.is_file():
        destination = attempt_dir / "weston.log"
        weston_log_metadata = _bounded_copy(log_path, destination, MAX_WESTON_LOG_BYTES)
        result["weston_log_copied"] = True
        result["weston_log"] = weston_log_metadata
    return result


def _git_identity(cwd: Path, sha: str) -> dict[str, str]:
    actual = _git(["rev-parse", "--verify", f"{sha}^{{commit}}"], cwd=cwd)
    tree = _git(["rev-parse", f"{actual}^{{tree}}"], cwd=cwd)
    return {"sha": actual, "tree": tree}


def _worktree_add(path: Path, sha: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _git(["worktree", "add", "--detach", str(path), sha])


def _worktree_remove(path: Path) -> None:
    subprocess.run(
        ["git", "worktree", "remove", "--force", str(path)],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )


def summarize_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    by_revision_scale: dict[str, dict[str, Any]] = {}
    for revision in ("baseline", "candidate"):
        for scale in SCALES:
            rows = [
                row for row in results
                if row.get("revision") == revision and row.get("scale") == scale
            ]
            statuses = collections.Counter(str(row.get("status", "unknown")) for row in rows)
            weston_139 = sum(139 in row.get("weston_exit_statuses", []) for row in rows)
            by_revision_scale[f"{revision}-scale-{scale}"] = {
                "planned": PAIR_COUNT,
                "recorded": len(rows),
                "statuses": dict(sorted(statuses.items())),
                "weston_exit_139_observations": weston_139,
                "valid_30_sample_attempts": sum(
                    row.get("measurement_valid") is True for row in rows
                ),
            }
    paired = []
    for pair in range(1, PAIR_COUNT + 1):
        for scale in SCALES:
            side = {
                row.get("revision"): row.get("status")
                for row in results
                if row.get("pair") == pair and row.get("scale") == scale
            }
            if (
                side.get("baseline") not in PAIR_COMPLETED_ATTEMPT_STATUSES
                or side.get("candidate") not in PAIR_COMPLETED_ATTEMPT_STATUSES
            ):
                outcome = "incomplete"
            elif side["baseline"] == "passed" and side["candidate"] == "passed":
                outcome = "both_pass"
            elif side["baseline"] == "passed":
                outcome = "candidate_failed_only"
            elif side["candidate"] == "passed":
                outcome = "baseline_failed_only"
            else:
                outcome = "both_failed"
            paired.append(
                {"pair": pair, "scale": scale, "baseline": side.get("baseline"),
                 "candidate": side.get("candidate"), "outcome": outcome}
            )
    return {"by_revision_and_scale": by_revision_scale, "pairs": paired}


def execute_comparison(
    *,
    baseline_sha: str,
    candidate_sha: str,
    output_dir: Path,
    budget_seconds: int = COMPARISON_BUDGET_SECONDS,
    attempt_runner=run_attempt,
    monotonic=time.monotonic,
) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    plan = build_attempt_plan()
    summary: dict[str, Any] = {
        "schema": "gpui.ubuntu.weston-paired-comparison.v1",
        "status": "setup",
        "baseline_sha": baseline_sha,
        "candidate_sha": candidate_sha,
        "pair_count_per_scale": PAIR_COUNT,
        "scales": list(SCALES),
        "planned_attempts": [asdict(row) for row in plan],
        "attempt_timeout_seconds": ATTEMPT_TIMEOUT_SECONDS,
        "comparison_budget_seconds": budget_seconds,
        "diagnostic_replays": 0,
        "diagnostic_replay_policy": "none; every attempt is predetermined and its original status is retained",
        "environment": collect_environment_metadata(),
        "results": [],
    }
    summary_path = output_dir / "comparison.json"
    _atomic_json(summary_path, summary)
    baseline_path = candidate_path = None
    temp_root: Path | None = None
    exit_code = 1
    start = monotonic()
    deadline = start + budget_seconds
    try:
        baseline_identity = _git_identity(ROOT, baseline_sha)
        candidate_identity = _git_identity(ROOT, candidate_sha)
        if baseline_identity["sha"] == candidate_identity["sha"]:
            raise ValueError("baseline and candidate must be distinct commits")
        if not _git_is_ancestor(baseline_sha, candidate_sha):
            raise ValueError("pinned #53 baseline is not an ancestor of the candidate")
        summary.update(baseline=baseline_identity, candidate=candidate_identity)
        temp_root = Path(tempfile.mkdtemp(prefix="gpui-weston-pairs-"))
        baseline_path = temp_root / "baseline"
        candidate_path = temp_root / "candidate"
        _worktree_add(baseline_path, baseline_sha)
        _worktree_add(candidate_path, candidate_sha)
        if _git(["rev-parse", "HEAD"], cwd=baseline_path) != baseline_sha:
            raise RuntimeError("baseline worktree did not resolve to the requested SHA")
        if _git(["rev-parse", "HEAD"], cwd=candidate_path) != candidate_sha:
            raise RuntimeError("candidate worktree did not resolve to the requested SHA")
        harness = _install_common_harness(baseline_path, candidate_path)
        if harness["common_overlay_file_sha256"] != {
            relative: hashlib.sha256((candidate_path / relative).read_bytes()).hexdigest()
            for relative in harness["files"]
        }:
            raise RuntimeError("baseline and candidate test harness bytes differ after overlay")
        if harness["common_overlay_file_modes"] != {
            relative: stat.S_IMODE((candidate_path / relative).stat().st_mode)
            for relative in harness["files"]
        }:
            raise RuntimeError("baseline and candidate test harness modes differ after overlay")
        summary["harness"] = {
            "source_revision": baseline_sha,
            "files_overlaid_in_candidate": harness["files"],
            **harness,
            "production_code_overlaid": False,
        }
        summary["status"] = "running"
        _atomic_json(summary_path, summary)
        worktrees = {"baseline": baseline_path, "candidate": candidate_path}
        for attempt in plan:
            attempt_dir = output_dir / "attempts" / (
                f"{attempt.ordinal:02d}-pair-{attempt.pair:02d}-scale-{attempt.scale}-"
                f"{attempt.revision}"
            )
            try:
                result = attempt_runner(
                    attempt,
                    worktrees[attempt.revision],
                    attempt_dir,
                    deadline=deadline,
                )
            except Exception as error:
                result = {
                    **asdict(attempt),
                    "status": "runner_error",
                    "error": f"{type(error).__name__}: {error}",
                }
            summary["results"].append(result)
            summary["elapsed_seconds"] = round(monotonic() - start, 3)
            _atomic_json(summary_path, summary)
            print(
                "GPUI_WESTON_PAIR_RESULT "
                + json.dumps(
                    {
                        "ordinal": attempt.ordinal,
                        "pair": attempt.pair,
                        "scale": attempt.scale,
                        "revision": attempt.revision,
                        "status": result["status"],
                        "shell_returncode": result.get("shell_returncode"),
                        "weston_exit_statuses": result.get("weston_exit_statuses", []),
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
        complete = len(summary["results"]) == len(plan) and all(
            item.get("status") in (
                "passed", "failed", "timed_out", "could_not_start",
                "invalid_measurement", "runner_error",
            )
            for item in summary["results"]
        )
        passed = complete and all(item.get("status") == "passed" for item in summary["results"])
        summary["status"] = "complete_pass" if passed else "complete_with_e2e_failures" if complete else "incomplete"
        summary["comparison"] = summarize_results(summary["results"])
        exit_code = 0 if passed else 1
    except Exception as error:  # Persist setup errors and remaining planned attempts.
        summary["setup_error"] = f"{type(error).__name__}: {error}"
        summary["status"] = "setup_failed"
    finally:
        existing = {int(item["ordinal"]) for item in summary["results"]}
        for attempt in plan:
            if attempt.ordinal in existing:
                continue
            summary["results"].append(
                {
                    **asdict(attempt),
                    "status": "not_run_budget_exhausted" if monotonic() >= deadline else "not_run_setup_failed",
                }
            )
        summary["results"].sort(key=lambda item: int(item["ordinal"]))
        summary["elapsed_seconds"] = round(monotonic() - start, 3)
        summary["attempts_completed"] = sum(
            item.get("status") in (
                "passed", "failed", "timed_out", "could_not_start",
                "invalid_measurement", "runner_error",
            )
            for item in summary["results"]
        )
        summary["attempts_incomplete"] = len(plan) - summary["attempts_completed"]
        summary["comparison"] = summarize_results(summary["results"])
        if summary["status"] not in ("complete_pass", "complete_with_e2e_failures"):
            summary["status"] = "setup_failed" if summary.get("setup_error") else "incomplete"
            exit_code = 1
        _atomic_json(summary_path, summary)
        if baseline_path is not None:
            _worktree_remove(baseline_path)
        if candidate_path is not None:
            _worktree_remove(candidate_path)
        if temp_root is not None:
            shutil.rmtree(temp_root, ignore_errors=True)
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-sha", required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "_build/ubuntu-comparison")
    args = parser.parse_args()
    env = os.environ
    try:
        validate_invocation(
            event_name=env.get("GITHUB_EVENT_NAME", ""),
            event_action=env.get("GITHUB_EVENT_ACTION", ""),
            ref_name=env.get("GITHUB_REF_NAME", ""),
            github_sha=env.get("GPUI_COMPARISON_EVENT_SHA", ""),
            candidate_sha=args.candidate_sha,
            baseline_sha=args.baseline_sha,
            pull_request_head_ref=env.get("GPUI_PULL_REQUEST_HEAD_REF", ""),
            pull_request_head_repo=env.get("GPUI_PULL_REQUEST_HEAD_REPO", ""),
        )
    except ValueError as error:
        print(f"comparison ref check failed: {error}", file=sys.stderr)
        return 2
    try:
        actual_head = _git(["rev-parse", "HEAD"])
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 2
    if actual_head != args.candidate_sha:
        print("candidate SHA is not the checked out branch head", file=sys.stderr)
        return 2
    return execute_comparison(
        baseline_sha=args.baseline_sha,
        candidate_sha=args.candidate_sha,
        output_dir=args.output_dir,
    )


if __name__ == "__main__":
    raise SystemExit(main())
