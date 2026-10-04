#!/usr/bin/env python3
"""Audit the structure and counts of a turtles schema-2 baseline report.

This validates that an observation is complete and internally consistent. It
does not approve its survivors or turn a baseline observation into a release
mutation pass.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import tomllib
from collections import defaultdict
from pathlib import Path
from typing import Any


EXPECTED_TURTLES_VERSION = "0.3.0"
EXPECTED_OUTCOMES = {"KILLED", "SURVIVED", "TIMEOUT", "UNVIABLE"}
EXPECTED_COUNTERS = ("killed", "survived", "timeout", "unviable")
EXPECTED_OPERATORS = {"comparison", "boolean", "arithmetic", "literal", "condition"}
EXPECTED_INCLUDE = ["primitives/"]


def audit_report(
    report: dict[str, Any],
    revision: str,
    survivor_dir: Path | None = None,
) -> dict[str, Any]:
    if report.get("schema") != 2:
        raise ValueError("expected turtles JSON schema 2")
    if report.get("turtles_version") != EXPECTED_TURTLES_VERSION:
        raise ValueError(f"expected turtles {EXPECTED_TURTLES_VERSION}")
    if not isinstance(report.get("module"), str) or not report["module"].strip():
        raise ValueError("report must identify the tested MoonBit module")
    if not isinstance(report.get("moon_version"), str) or not report["moon_version"].strip():
        raise ValueError("report must identify the MoonBit toolchain")
    if report.get("test_scope") != "module":
        raise ValueError("the baseline requires turtles' full module test scope")
    for timing in ("baseline_duration_ms", "baseline_check_ms", "baseline_test_ms"):
        value = report.get(timing)
        if not isinstance(value, (str, int)) or not str(value).isdigit():
            raise ValueError(f"report.{timing} must be a non-negative duration")
    files = report.get("files")
    if not isinstance(files, dict) or "turtles.toml" not in files:
        raise ValueError("report must fingerprint source/configuration files, including turtles.toml")
    if not any(isinstance(path, str) and path.startswith("primitives/") for path in files):
        raise ValueError("report file fingerprints do not include primitives/")
    if any(
        not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{16}", digest)
        for digest in files.values()
    ):
        raise ValueError("report contains an invalid turtles source fingerprint")
    skipped_files = report.get("skipped_files")
    if not isinstance(skipped_files, list):
        raise ValueError("report must contain the skipped_files array")
    if any(
        isinstance(item, dict)
        and isinstance(item.get("path"), str)
        and item["path"].startswith("primitives/")
        for item in skipped_files
    ):
        raise ValueError("turtles skipped a file in the configured primitives scope")
    mutants = report.get("mutants")
    if not isinstance(mutants, list) or not mutants:
        raise ValueError("report must contain a non-empty mutants array")
    summary = report.get("summary")
    if not isinstance(summary, dict):
        raise ValueError("report must contain a summary object")
    for counter in EXPECTED_COUNTERS:
        if type(summary.get(counter)) is not int or summary[counter] < 0:
            raise ValueError(f"summary.{counter} must be a non-negative integer")

    counts = {counter: 0 for counter in EXPECTED_COUNTERS}
    by_operator: dict[str, dict[str, int]] = defaultdict(
        lambda: {counter: 0 for counter in EXPECTED_COUNTERS}
    )
    unresolved: list[dict[str, Any]] = []
    mutant_ids: set[str] = set()
    for index, mutant in enumerate(mutants):
        if not isinstance(mutant, dict):
            raise ValueError(f"mutants[{index}] must be an object")
        outcome = mutant.get("outcome")
        if outcome not in EXPECTED_OUTCOMES:
            raise ValueError(f"mutants[{index}] has unknown outcome {outcome!r}")
        counter = outcome.lower()
        counts[counter] += 1
        path = mutant.get("path")
        if not isinstance(path, str) or not path.startswith("primitives/"):
            raise ValueError(f"mutants[{index}] is outside the configured primitives scope")
        operator = mutant.get("group")
        if operator not in EXPECTED_OPERATORS:
            raise ValueError(f"mutants[{index}] has an unexpected mutation operator {operator!r}")
        mutant_id = mutant.get("id")
        if not isinstance(mutant_id, str) or not mutant_id or mutant_id in mutant_ids:
            raise ValueError(f"mutants[{index}] has a missing or duplicate id")
        mutant_ids.add(mutant_id)
        if type(mutant.get("line")) is not int or mutant["line"] < 1:
            raise ValueError(f"mutants[{index}] has an invalid source line")
        if not isinstance(mutant.get("original"), str) or not isinstance(mutant.get("replacement"), str):
            raise ValueError(f"mutants[{index}] is missing its mutation diff")
        by_operator[operator][counter] += 1
        if outcome in ("SURVIVED", "TIMEOUT"):
            unresolved.append(
                {
                    "id": mutant.get("id"),
                    "path": path,
                    "line": mutant.get("line"),
                    "operator": operator,
                    "outcome": outcome,
                    "original": mutant.get("original"),
                    "replacement": mutant.get("replacement"),
                }
            )

    if counts != {counter: summary[counter] for counter in EXPECTED_COUNTERS}:
        raise ValueError("summary counters do not equal outcomes in mutants[]")
    if set(by_operator) != EXPECTED_OPERATORS:
        missing = sorted(EXPECTED_OPERATORS - set(by_operator))
        raise ValueError(f"report does not cover every configured operator group: {', '.join(missing)}")
    viable = counts["killed"] + counts["survived"] + counts["timeout"]
    if viable == 0:
        raise ValueError("report contains no viable mutants; an empty or all-unviable run is not a baseline")
    expected_score = counts["killed"] * 100.0 / viable
    score = summary.get("score")
    if not isinstance(score, (int, float)) or not math.isclose(
        float(score), expected_score, rel_tol=0.0, abs_tol=0.01
    ):
        raise ValueError("summary.score does not match killed / viable mutants")
    if report.get("test_scope") != "module":
        raise ValueError("pinned turtles 0.3.0 baseline must use Moon's complete module test scope")

    source_manifest = hashlib.sha256()
    for path, fingerprint in sorted(files.items()):
        source_manifest.update(path.encode("utf-8"))
        source_manifest.update(b"\0")
        source_manifest.update(fingerprint.encode("ascii"))
        source_manifest.update(b"\0")

    if survivor_dir is not None:
        expected_diffs = {f"{mutant['id']}.diff" for mutant in unresolved}
        actual_diffs = {
            path.name
            for path in survivor_dir.glob("*.diff")
            if path.is_file()
        } if survivor_dir.is_dir() else set()
        if actual_diffs != expected_diffs:
            missing_diffs = sorted(expected_diffs - actual_diffs)
            extra_diffs = sorted(actual_diffs - expected_diffs)
            raise ValueError(
                "survivor/timeout diffs do not match the report; "
                f"missing={missing_diffs}, extra={extra_diffs}"
            )
        for diff_name in expected_diffs:
            if (survivor_dir / diff_name).stat().st_size == 0:
                raise ValueError(f"survivor/timeout diff is empty: {diff_name}")

    return {
        "schema_version": 1,
        "kind": "turtles-baseline-observation",
        "baseline_state": "observed_pending_review",
        "release_mutation_gate": "pending",
        "turtles_version": report["turtles_version"],
        "target": "moon-default",
        "test_scope": report.get("test_scope", "module"),
        "revision": revision,
        "source_manifest_sha256": source_manifest.hexdigest(),
        "module": report.get("module"),
        "moon_version": report["moon_version"],
        "mutation_counts": counts,
        "viable": viable,
        "score_percent": round(expected_score, 3),
        "by_operator": dict(sorted(by_operator.items())),
        "unresolved": unresolved,
        "unresolved_diff_files": sorted(f"{mutant['id']}.diff" for mutant in unresolved),
        "mutant_count": len(mutants),
        "summary_matches": True,
    }


def _read_report(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read turtles report {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("turtles report must be a JSON object")
    return value


def _revision(repo_root: Path) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else "unavailable"


def _fnv1a64_hex(content: bytes) -> str:
    value = 0xCBF29CE484222325
    for byte in content:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def validate_scope_configuration(config_path: Path, report: dict[str, Any]) -> None:
    try:
        config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ValueError(f"cannot read turtles scope configuration: {error}") from error
    if config.get("include") != EXPECTED_INCLUDE:
        raise ValueError(f"turtles.toml include must be exactly {EXPECTED_INCLUDE}")
    if set(config.get("operators", [])) != EXPECTED_OPERATORS:
        raise ValueError("turtles.toml operator groups differ from the audited baseline scope")
    fingerprints = report.get("files")
    if not isinstance(fingerprints, dict):
        raise ValueError("report has no file fingerprints")
    expected = _fnv1a64_hex(config_path.read_bytes())
    if fingerprints.get("turtles.toml") != expected:
        raise ValueError("report turtles.toml fingerprint does not match the checked-in scope")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--survivor-dir", type=Path, required=True)
    args = parser.parse_args()
    report_path = args.report.resolve()
    repo_root = Path(__file__).resolve().parents[1]
    output = args.output if args.output.is_absolute() else repo_root / args.output
    try:
        survivor_dir = args.survivor_dir
        if not survivor_dir.is_absolute():
            survivor_dir = repo_root / survivor_dir
        report = _read_report(report_path)
        validate_scope_configuration(repo_root / "turtles.toml", report)
        summary = audit_report(report, _revision(repo_root), survivor_dir)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"turtles report audit failed: {error}", file=sys.stderr)
        return 2
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "turtles baseline observed: "
        f"{summary['score_percent']:.3f}% ({summary['mutation_counts']}); "
        "release mutation gate remains pending"
    )
    print(f"audited summary: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
