#!/usr/bin/env python3
"""Run the Ubuntu Wayland E2E workload and report real present-to-frame samples.

The C E2E emits one GPUI_BENCH_SAMPLE key/value record per measured frame.
This wrapper owns environment capture, percentile calculation, report retention,
and conservative baseline comparison. A successful measurement is diagnostic
evidence; it is not itself a production performance-gate pass.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
SCENARIO = "ubuntu.wayland.recovered_present_to_frame.v1"
EXPECTED_SCALES = (1, 2)
MIN_SAMPLES = 30
SAMPLE_PREFIX = "GPUI_BENCH_SAMPLE "


def parse_sample_line(line: str) -> dict[str, Any] | None:
    """Parse a measurement record, ignoring all ordinary test output."""
    if not line.startswith(SAMPLE_PREFIX):
        return None
    fields: dict[str, str] = {}
    for token in line[len(SAMPLE_PREFIX) :].strip().split():
        if "=" not in token:
            raise ValueError(f"malformed benchmark token: {token!r}")
        key, value = token.split("=", 1)
        if not key or key in fields:
            raise ValueError(f"empty or duplicate benchmark field: {key!r}")
        fields[key] = value
    required = {"scenario", "platform", "scale", "sample", "duration_ns", "renderer"}
    missing = sorted(required - fields.keys())
    if missing:
        raise ValueError(f"benchmark sample is missing fields: {', '.join(missing)}")
    if fields["scenario"] != SCENARIO:
        raise ValueError(f"unsupported benchmark scenario: {fields['scenario']}")
    if fields["platform"] != "ubuntu-wayland":
        raise ValueError(f"unexpected benchmark platform: {fields['platform']}")
    try:
        scale = int(fields["scale"])
        sample = int(fields["sample"])
        duration_ns = int(fields["duration_ns"])
    except ValueError as error:
        raise ValueError("scale, sample, and duration_ns must be integers") from error
    if scale not in EXPECTED_SCALES:
        raise ValueError(f"unexpected scale factor: {scale}")
    if sample < 0 or duration_ns <= 0:
        raise ValueError("sample index must be non-negative and duration must be positive")
    return {
        "scenario": fields["scenario"],
        "platform": fields["platform"],
        "scale": scale,
        "sample": sample,
        "duration_ns": duration_ns,
        "renderer": fields.get("renderer", "unknown"),
    }


def _percentile_nearest_rank(values: list[int], percentile: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile * len(ordered)) - 1)]


def summarize_samples(samples: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[int, list[dict[str, Any]]] = {scale: [] for scale in EXPECTED_SCALES}
    seen: set[tuple[int, int]] = set()
    samples = list(samples)
    for sample in samples:
        scale = sample["scale"]
        index = sample["sample"]
        key = (scale, index)
        if key in seen:
            raise ValueError(f"duplicate sample index {index} at scale {scale}")
        seen.add(key)
        grouped[scale].append(sample)

    renderers = {str(sample["renderer"]) for sample in samples}
    if len(renderers) > 1:
        raise ValueError(f"renderer changed within one benchmark run: {sorted(renderers)}")

    summaries = []
    for scale in EXPECTED_SCALES:
        rows = sorted(grouped[scale], key=lambda item: item["sample"])
        durations = [int(row["duration_ns"]) for row in rows]
        if len(durations) < MIN_SAMPLES:
            raise ValueError(
                f"scale {scale} has {len(durations)} samples; at least {MIN_SAMPLES} are required"
            )
        if [row["sample"] for row in rows] != list(range(len(rows))):
            raise ValueError(f"sample indices for scale {scale} must be contiguous from zero")
        summaries.append(
            {
                "scenario": SCENARIO,
                "platform": "ubuntu-wayland",
                "scale": scale,
                "unit": "ns",
                "sample_count": len(durations),
                "p50": int(round(__import__("statistics").median(durations))),
                "p95": _percentile_nearest_rank(durations, 0.95),
                "min": min(durations),
                "max": max(durations),
                "raw_samples": durations,
            }
        )
    return summaries


def _cpu_model() -> str:
    cpu = platform.processor().strip()
    if cpu:
        return cpu
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.lower().startswith(("model name", "hardware")):
                return line.split(":", 1)[-1].strip()
    except OSError:
        pass
    return "unknown"


def _command_output(command: list[str], cwd: Path) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unavailable: {error}"
    return result.stdout.strip() or f"exit={result.returncode}"


def _git_state() -> dict[str, Any]:
    revision = _command_output(["git", "rev-parse", "HEAD"], ROOT)
    try:
        status = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
        diff = subprocess.run(
            ["git", "diff", "--binary", "HEAD"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
        untracked = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        return {"revision": revision, "dirty": None, "tree_sha256": f"unavailable: {error}"}
    tree = hashlib.sha256()
    tree.update(revision.encode("utf-8"))
    tree.update(b"\0")
    tree.update(status)
    tree.update(b"\0")
    tree.update(diff)
    tree.update(b"\0")
    for raw_path in untracked.split(b"\0"):
        if not raw_path:
            continue
        rel = Path(os.fsdecode(raw_path))
        path = ROOT / rel
        tree.update(raw_path)
        tree.update(b"\0")
        try:
            tree.update(path.read_bytes())
        except OSError as error:
            tree.update(f"unreadable:{error}".encode("utf-8"))
        tree.update(b"\0")
    return {
        "revision": revision,
        "dirty": bool(status.strip()),
        "tree_sha256": tree.hexdigest(),
    }


def _sha256_files(paths: list[Path], base: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(base).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def environment_report(runner_class: str, renderer: str) -> dict[str, Any]:
    return {
        "runner_class": runner_class,
        "os": platform.platform(),
        "machine": platform.machine(),
        "cpu_model": _cpu_model(),
        "renderer": renderer,
        "compiler": _command_output(["cc", "--version"], ROOT).splitlines()[0],
        "moon": _command_output(["moon", "version", "--all"], ROOT),
    }


def _compatibility_keys(report: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    workload = report.get("workload", {})
    environment = report.get("environment", {})
    return (
        {
            key: environment.get(key)
            for key in (
                "runner_class",
                "os",
                "machine",
                "cpu_model",
                "renderer",
                "compiler",
                "moon",
            )
        },
        {
            key: workload.get(key)
            for key in ("scenario", "timer", "scale_factors", "samples_per_scale", "fixture_sha256")
        },
    )


def _assert_comparable(current: dict[str, Any], baseline: dict[str, Any]) -> None:
    for label, report in (("current", current), ("baseline", baseline)):
        _validate_report(report, label)
    for label, left, right in zip(
        ("runner", "workload"), _compatibility_keys(current), _compatibility_keys(baseline)
    ):
        if left != right:
            changed = [key for key in left if left.get(key) != right.get(key)]
            raise ValueError(f"incomparable {label}; changed fields: {', '.join(changed)}")
    if current["run_id"] == baseline["run_id"]:
        raise ValueError("current and baseline must be independent runs")


def compare_reports(
    current: dict[str, Any],
    baseline: dict[str, Any],
    confirmation: dict[str, Any] | None = None,
    threshold_percent: float = 10.0,
) -> dict[str, Any]:
    """Compare only reports from the same runner and exact benchmark workload.

    A regression is release-blocking only when the same p50 or p95 threshold is
    exceeded in two independent current runs, as required by docs/performance.md.
    """
    _assert_comparable(current, baseline)
    if confirmation is not None:
        _assert_comparable(confirmation, baseline)
        if len({current["run_id"], baseline["run_id"], confirmation["run_id"]}) != 3:
            raise ValueError("baseline, current, and confirmation need distinct run IDs")
        if (current["revision"], current["worktree_sha256"]) != (
            confirmation["revision"],
            confirmation["worktree_sha256"],
        ):
            raise ValueError("independent current runs must measure the same revision and worktree")

    baseline_by_scale = {int(item["scale"]): item for item in baseline["measurements"]}

    def deltas(candidate: dict[str, Any]) -> list[dict[str, Any]]:
        candidate_by_scale = {int(item["scale"]): item for item in candidate["measurements"]}
        result = []
        for scale in EXPECTED_SCALES:
            before = baseline_by_scale[scale]
            after = candidate_by_scale[scale]
            if before["sample_count"] < MIN_SAMPLES or after["sample_count"] < MIN_SAMPLES:
                raise ValueError("baseline comparison requires at least 30 samples per scale")
            metrics = {}
            for field in ("p50", "p95"):
                old = int(before[field])
                new = int(after[field])
                metrics[field] = {
                    "baseline_ns": old,
                    "current_ns": new,
                    "change_percent": round((new - old) * 100.0 / old, 3) if old else None,
                }
            result.append({"scale": scale, "metrics": metrics})
        return result

    first = deltas(current)
    if confirmation is None:
        return {
            "state": "requires_independent_confirmation",
            "threshold_percent": threshold_percent,
            "runs": [first],
        }
    second = deltas(confirmation)

    def exceeds(run: list[dict[str, Any]]) -> set[tuple[int, str]]:
        return {
            (row["scale"], field)
            for row in run
            for field, metric in row["metrics"].items()
            if metric["change_percent"] is not None
            and metric["change_percent"] > threshold_percent
        }

    first_regressions = exceeds(first)
    second_regressions = exceeds(second)
    confirmed = sorted(first_regressions & second_regressions)
    if confirmed:
        state = "regression_confirmed"
    elif first_regressions or second_regressions:
        state = "inconclusive"
    else:
        state = "within_threshold"
    return {
        "state": state,
        "threshold_percent": threshold_percent,
        "confirmed_metrics": [
            {"scale": scale, "metric": metric} for scale, metric in confirmed
        ],
        "runs": [first, second],
    }


def _validate_report(report: dict[str, Any], label: str) -> None:
    if report.get("schema_version") != 1 or report.get("kind") != "gpui-native-performance-report":
        raise ValueError(f"{label} report has an unsupported schema")
    if report.get("measurement_status") != "complete":
        raise ValueError(f"{label} report must contain complete measurements")
    if report.get("measurement_provenance") != "captured_live":
        raise ValueError(f"{label} report is not a live measurement; replayed logs cannot be baselines")
    if not report.get("run_id"):
        raise ValueError(f"{label} report is missing a unique run ID")
    revision = report.get("revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
        raise ValueError(f"{label} report has invalid or unavailable source revision provenance")
    tree_hash = report.get("worktree_sha256")
    if not isinstance(tree_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", tree_hash):
        raise ValueError(f"{label} report has invalid or unavailable worktree provenance")
    if type(report.get("worktree_dirty")) is not bool:
        raise ValueError(f"{label} report is missing the worktree dirty flag")
    if report.get("target") != "native":
        raise ValueError(f"{label} report target must be native")
    measurements = report.get("measurements")
    if not isinstance(measurements, list) or len(measurements) != len(EXPECTED_SCALES):
        raise ValueError(f"{label} report must include exactly two scale measurements")
    environment = report.get("environment", {})
    required_environment = (
        "runner_class",
        "os",
        "machine",
        "cpu_model",
        "renderer",
        "compiler",
        "moon",
    )
    for key in required_environment:
        value = environment.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"{label} report has an incomplete runner field: {key}")
        if value.lower().startswith(("unknown", "unavailable", "inconsistent:")):
            raise ValueError(f"{label} report has an unusable runner field: {key}={value}")
        if key == "runner_class" and value == "local-unpinned":
            raise ValueError(f"{label} report does not identify a comparable runner class")
    workload = report.get("workload", {})
    if workload.get("scenario") != SCENARIO or workload.get("scale_factors") != list(EXPECTED_SCALES):
        raise ValueError(f"{label} report has an unsupported workload")
    if not isinstance(workload.get("timer"), str) or not workload["timer"].strip():
        raise ValueError(f"{label} report has no timer methodology")
    if not isinstance(workload.get("samples_per_scale"), int) or workload["samples_per_scale"] < MIN_SAMPLES:
        raise ValueError(f"{label} report workload requires at least 30 samples per scale")
    fixture_hash = workload.get("fixture_sha256")
    if not isinstance(fixture_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", fixture_hash):
        raise ValueError(f"{label} report has an invalid workload fixture checksum")
    if not isinstance(workload.get("samples_per_scale"), int) or workload["samples_per_scale"] < MIN_SAMPLES:
        raise ValueError(f"{label} report workload requires at least 30 samples per scale")
    if any(not isinstance(item, dict) or type(item.get("scale")) is not int for item in measurements):
        raise ValueError(f"{label} report contains malformed scale measurement rows")
    measurements_by_scale = {item["scale"]: item for item in measurements}
    if set(measurements_by_scale) != set(EXPECTED_SCALES):
        raise ValueError(f"{label} report has missing or unexpected scale factors")
    for scale, item in measurements_by_scale.items():
        raw = item.get("raw_samples")
        if not isinstance(raw, list) or len(raw) != item.get("sample_count"):
            raise ValueError(f"{label} report scale {scale} raw samples do not match sample_count")
        if len(raw) != workload["samples_per_scale"] or len(raw) < MIN_SAMPLES:
            raise ValueError(f"{label} report scale {scale} does not match the declared sample count")
        if any(type(value) is not int or value <= 0 for value in raw):
            raise ValueError(f"{label} report scale {scale} needs 30 positive raw samples")
        if item.get("unit") != "ns":
            raise ValueError(f"{label} report scale {scale} has an unsupported time unit")
        expected = {
            "p50": int(round(__import__("statistics").median(raw))),
            "p95": _percentile_nearest_rank(raw, 0.95),
            "min": min(raw),
            "max": max(raw),
        }
        for field, value in expected.items():
            if type(item.get(field)) is not int or item[field] != value:
                raise ValueError(f"{label} report scale {scale} has inconsistent {field}")


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read report {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"report {path} must contain a JSON object")
    return value


def _collect_measurements(
    input_log: Path | None,
    samples_per_scale: int,
) -> tuple[list[dict[str, Any]], int, str, str | None]:
    samples: list[dict[str, Any]] = []
    if input_log is not None:
        lines = input_log.read_text(encoding="utf-8").splitlines()
        process_exit = 0
        command_text = f"replay:{input_log}"
    else:
        env = os.environ.copy()
        env["GPUI_BENCH_UBUNTU"] = "1"
        process = subprocess.Popen(
            ["sh", "scripts/test_ubuntu.sh"],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        assert process.stdout is not None
        lines = []
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            lines.append(line.rstrip("\n"))
        process_exit = process.wait()
        command_text = "sh scripts/test_ubuntu.sh (benchmark env enabled)"

    parse_error = None
    for line_number, line in enumerate(lines, start=1):
        try:
            parsed = parse_sample_line(line)
            if parsed is not None:
                samples.append(parsed)
        except ValueError as error:
            parse_error = f"line {line_number}: {error}"
            break
    if parse_error:
        return samples, process_exit, command_text, parse_error
    for scale in EXPECTED_SCALES:
        count = sum(1 for sample in samples if sample["scale"] == scale)
        if count != samples_per_scale:
            return (
                samples,
                process_exit,
                command_text,
                f"scale {scale} emitted {count} samples; expected exactly {samples_per_scale}",
            )
    return samples, process_exit, command_text, None


def build_report(
    samples: list[dict[str, Any]],
    process_exit: int,
    command_text: str,
    runner_class: str,
    samples_per_scale: int,
    error: str | None,
) -> dict[str, Any]:
    fixture = ROOT / "tests/ubuntu/backend_test.c"
    workload = {
        "scenario": SCENARIO,
        "timer": "CLOCK_MONOTONIC; renderer recovery through the next Wayland frame callback",
        "scale_factors": list(EXPECTED_SCALES),
        "samples_per_scale": samples_per_scale,
        "fixture_sha256": _sha256_files([fixture], ROOT),
    }
    measurements: list[dict[str, Any]] = []
    if error is None:
        try:
            measurements = summarize_samples(samples)
        except ValueError as caught:
            error = str(caught)
    complete = error is None and process_exit == 0 and len(measurements) == len(EXPECTED_SCALES)
    renderers = sorted({str(sample.get("renderer", "unknown")) for sample in samples})
    renderer = renderers[0] if len(renderers) == 1 else "inconsistent:" + ",".join(renderers)
    git = _git_state()
    return {
        "schema_version": 1,
        "kind": "gpui-native-performance-report",
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "measurement_status": "complete" if complete and not renderer.startswith("inconsistent:") else "failed",
        "measurement_provenance": "replayed_log_unverified" if command_text.startswith("replay:") else "captured_live",
        "measurement_error": error,
        "process_exit_code": process_exit,
        "command": command_text,
        "run_id": str(uuid.uuid4()),
        "revision": git["revision"],
        "worktree_dirty": git["dirty"],
        "worktree_sha256": git["tree_sha256"],
        "target": "native",
        "environment": environment_report(runner_class, renderer),
        "workload": workload,
        "measurements": measurements,
        "release_gate_effect": "diagnostic_only; tier1 baseline and independent confirmation are required",
        "comparison": {"state": "no_baseline"},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("_build/ubuntu-bench/report.json"))
    parser.add_argument(
        "--runner-class",
        default=os.environ.get("GPUI_BENCH_RUNNER_CLASS", "local-unpinned"),
    )
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--input-log", type=Path, help="parse an existing log instead of rerunning E2E")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--confirmation", type=Path)
    parser.add_argument("--threshold-percent", type=float, default=10.0)
    args = parser.parse_args()
    if args.samples != MIN_SAMPLES:
        parser.error(f"this workload currently emits exactly {MIN_SAMPLES} samples per scale")
    if args.threshold_percent < 0:
        parser.error("--threshold-percent must be non-negative")
    if args.confirmation and not args.baseline:
        parser.error("--confirmation requires --baseline")

    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    input_log = args.input_log
    if input_log is not None and not input_log.is_absolute():
        input_log = ROOT / input_log

    samples, process_exit, command_text, error = _collect_measurements(input_log, args.samples)
    report = build_report(samples, process_exit, command_text, args.runner_class, args.samples, error)
    if args.baseline:
        try:
            baseline = _read_json(args.baseline)
            confirmation = _read_json(args.confirmation) if args.confirmation else None
            report["comparison"] = compare_reports(
                report, baseline, confirmation, threshold_percent=args.threshold_percent
            )
        except (OSError, ValueError, KeyError, TypeError) as caught:
            report["comparison"] = {"state": "incomparable", "error": str(caught)}

    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Benchmark report: {output}")
    print(f"Measurement status: {report['measurement_status']}")
    print(f"Comparison status: {report['comparison']['state']}")
    if report["measurement_error"]:
        print(f"Measurement error: {report['measurement_error']}", file=sys.stderr)
    if process_exit != 0 or report["measurement_status"] != "complete":
        return 1
    if report["comparison"]["state"] == "regression_confirmed":
        return 1
    if report["comparison"]["state"] in ("incomparable", "inconclusive"):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
