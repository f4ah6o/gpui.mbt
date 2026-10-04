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
ALLOWED_SCOPES = ("primitives/", "capability/", "mcp/")


def _validate_scope(scope: str) -> None:
    if scope not in ALLOWED_SCOPES:
        raise ValueError(f"unsupported mutation scope: {scope!r}")


def audit_report(
    report: dict[str, Any],
    revision: str,
    survivor_dir: Path | None = None,
    scope: str = "primitives/",
) -> dict[str, Any]:
    _validate_scope(scope)
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
    if not any(isinstance(path, str) and path.startswith(scope) for path in files):
        raise ValueError(f"report file fingerprints do not include {scope}")
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
        and item["path"].startswith(scope)
        for item in skipped_files
    ):
        raise ValueError(f"turtles skipped a file in the configured {scope} scope")
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
        if not isinstance(path, str) or not path.startswith(scope):
            raise ValueError(f"mutants[{index}] is outside the configured {scope} scope")
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
        "scope": scope,
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


def validate_scope_configuration(
    config_path: Path, report: dict[str, Any], scope: str = "primitives/",
) -> None:
    _validate_scope(scope)
    try:
        config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ValueError(f"cannot read turtles scope configuration: {error}") from error
    if set(config) != {"include", "operators"}:
        raise ValueError("turtles scope config must contain only include and operators")
    if config.get("include") != [scope]:
        raise ValueError(f"turtles.toml include must be exactly {[scope]}")
    if set(config.get("operators", [])) != EXPECTED_OPERATORS:
        raise ValueError("turtles.toml operator groups differ from the audited baseline scope")
    fingerprints = report.get("files")
    if not isinstance(fingerprints, dict):
        raise ValueError("report has no file fingerprints")
    expected = _fnv1a64_hex(config_path.read_bytes())
    if fingerprints.get("turtles.toml") != expected:
        raise ValueError("report turtles.toml fingerprint does not match the checked-in scope")


def _baseline_counts(row: Any, label: str) -> tuple[int, int, int, int]:
    if not isinstance(row, dict):
        raise ValueError(f"{label} must be an object")
    values: dict[str, int] = {}
    for field in ("killed", "survived", "timeout", "viable"):
        value = row.get(field)
        if type(value) is not int or value < 0:
            raise ValueError(f"{label}.{field} must be a non-negative integer")
        values[field] = value
    if values["viable"] <= 0:
        raise ValueError(f"{label}.viable must be positive")
    if values["killed"] + values["survived"] + values["timeout"] != values["viable"]:
        raise ValueError(
            f"{label} must satisfy killed + survived + timeout == viable"
        )
    return (
        values["killed"],
        values["survived"],
        values["timeout"],
        values["viable"],
    )


def _score_percent(killed: int, viable: int) -> float:
    return round(killed * 100.0 / viable, 3)


def _require_no_ratio_regression(
    label: str,
    current_killed: int,
    current_viable: int,
    baseline_killed: int,
    baseline_viable: int,
) -> None:
    if current_viable <= 0:
        raise ValueError(f"{label} has no viable mutants in the current report")
    if current_killed * baseline_viable < baseline_killed * current_viable:
        raise ValueError(
            f"{label} mutation score regressed: "
            f"current {current_killed}/{current_viable} "
            f"({_score_percent(current_killed, current_viable):.3f}%) < "
            f"baseline {baseline_killed}/{baseline_viable} "
            f"({_score_percent(baseline_killed, baseline_viable):.3f}%)"
        )


def _moon_build_identity(value: Any) -> str:
    if not isinstance(value, str):
        raise ValueError("semantic baseline requires a Moon build identity")
    # turtles records `moon version`, which may append an absolute or ~/ installation
    # path. Preserve version, commit and date; reject unfamiliar output formats.
    match = re.fullmatch(
        r"(moon [0-9][0-9A-Za-z.+-]* \([0-9a-f]{7,40} [0-9]{4}-[0-9]{2}-[0-9]{2}\))"
        r"(?: (?:/|~/|[A-Za-z]:[\\/])[^\r\n]+)?", value.strip(),
    )
    if match is None:
        raise ValueError("invalid Moon build identity in semantic baseline or report")
    return match.group(1)


def _enforce_survivor_review(
    summary: dict[str, Any], baseline: dict[str, Any], scope: str,
) -> dict[str, Any]:
    """Critical semantic scopes cannot trade an unexplained survivor for kills."""
    if _moon_build_identity(baseline.get("moon_version")) != _moon_build_identity(summary.get("moon_version")):
        raise ValueError("semantic baseline Moon build identity does not match the report")
    reviews = baseline.get("survivor_reviews")
    if not isinstance(reviews, list):
        raise ValueError("semantic baseline must contain survivor_reviews")
    if baseline["overall"]["timeout"] != 0:
        raise ValueError("semantic baseline must have zero timeouts")
    if len(reviews) != baseline["overall"]["survived"]:
        raise ValueError("survivor review count does not match baseline survivors")
    reviewed: dict[str, dict[str, Any]] = {}
    for review in reviews:
        if not isinstance(review, dict):
            raise ValueError("survivor review must be an object")
        identity = review.get("id")
        if not isinstance(identity, str) or not identity or identity in reviewed:
            raise ValueError("survivor review has missing or duplicate id")
        if review.get("classification") not in ("equivalent", "redundant"):
            raise ValueError("survivor review must explain equivalence or redundancy")
        reason = review.get("rationale")
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError("survivor review requires a nonempty rationale")
        if not isinstance(review.get("path"), str) or not review["path"].startswith(scope):
            raise ValueError("survivor review is outside the selected scope")
        if review.get("operator") not in EXPECTED_OPERATORS:
            raise ValueError("survivor review has an unexpected operator")
        for field in ("original", "replacement"):
            if not isinstance(review.get(field), str):
                raise ValueError(f"survivor review must record {field}")
        reviewed[identity] = review
    unresolved = summary.get("unresolved")
    if not isinstance(unresolved, list):
        raise ValueError("audited semantic summary must list unresolved mutants")
    if len(unresolved) != summary["mutation_counts"]["survived"] + summary["mutation_counts"]["timeout"]:
        raise ValueError("audited semantic unresolved count differs from survivor counts")
    seen: set[str] = set()
    for mutant in unresolved:
        identity = mutant.get("id")
        if identity in seen:
            raise ValueError("audited semantic summary repeats a survivor id")
        seen.add(identity)
        if mutant.get("outcome") != "SURVIVED":
            raise ValueError("semantic mutation gate permits no unresolved timeouts")
        review = reviewed.get(identity)
        if review is None:
            raise ValueError(f"unreviewed semantic survivor: {identity}")
        for field in ("path", "operator", "original", "replacement"):
            if mutant.get(field) != review[field]:
                raise ValueError(f"survivor review identity mismatch for {identity}: {field}")
    return {"status": "pass", "surviving_reviewed": len(unresolved), "reviewed_baseline_count": len(reviews)}


def enforce_ratchet(
    summary: dict[str, Any],
    baseline: dict[str, Any],
    scope: str = "primitives/",
) -> dict[str, Any]:
    _validate_scope(scope)
    if summary.get("scope") != scope:
        raise ValueError("audited summary scope does not match selected mutation scope")
    if baseline.get("schema_version") != 1:
        raise ValueError("mutation ratchet baseline must use schema_version 1")
    if baseline.get("kind") != "turtles-mutation-ratchet":
        raise ValueError("mutation ratchet baseline has the wrong kind")
    if baseline.get("scope") != scope:
        raise ValueError(
            f"mutation ratchet baseline scope must be {scope!r}"
        )
    for field in ("turtles_version", "target", "test_scope"):
        if baseline.get(field) != summary.get(field):
            raise ValueError(
                f"mutation ratchet baseline {field} does not match the current report"
            )

    source = baseline.get("source")
    if not isinstance(source, dict):
        raise ValueError("mutation ratchet baseline must record source provenance")
    if not isinstance(source.get("head_sha"), str) or not source["head_sha"]:
        raise ValueError("mutation ratchet baseline source.head_sha is required")
    if type(source.get("workflow_run_id")) is not int or source["workflow_run_id"] <= 0:
        raise ValueError("mutation ratchet baseline source.workflow_run_id is required")
    manifest = source.get("source_manifest_sha256")
    if not isinstance(manifest, str) or re.fullmatch(r"[0-9a-f]{64}", manifest) is None:
        raise ValueError(
            "mutation ratchet baseline source.source_manifest_sha256 must be sha256"
        )

    baseline_overall = _baseline_counts(baseline.get("overall"), "baseline.overall")
    baseline_by_operator = baseline.get("by_operator")
    if not isinstance(baseline_by_operator, dict):
        raise ValueError("mutation ratchet baseline must contain by_operator")
    if set(baseline_by_operator) != EXPECTED_OPERATORS:
        raise ValueError(
            "mutation ratchet baseline operator groups differ from the configured scope"
        )

    baseline_rows: dict[str, tuple[int, int, int, int]] = {}
    for operator in sorted(EXPECTED_OPERATORS):
        baseline_rows[operator] = _baseline_counts(
            baseline_by_operator[operator],
            f"baseline.by_operator.{operator}",
        )
    if (
        sum(row[0] for row in baseline_rows.values()) != baseline_overall[0]
        or sum(row[1] for row in baseline_rows.values()) != baseline_overall[1]
        or sum(row[2] for row in baseline_rows.values()) != baseline_overall[2]
        or sum(row[3] for row in baseline_rows.values()) != baseline_overall[3]
    ):
        raise ValueError(
            "mutation ratchet baseline overall counts do not equal by_operator totals"
        )

    current_counts = summary.get("mutation_counts")
    if not isinstance(current_counts, dict):
        raise ValueError("audited summary is missing mutation_counts")
    current_killed = current_counts.get("killed")
    current_survived = current_counts.get("survived")
    current_timeout = current_counts.get("timeout")
    if any(type(value) is not int or value < 0 for value in (
        current_killed,
        current_survived,
        current_timeout,
    )):
        raise ValueError("audited summary has invalid mutation counts")
    current_viable = current_killed + current_survived + current_timeout
    _require_no_ratio_regression(
        "overall",
        current_killed,
        current_viable,
        baseline_overall[0],
        baseline_overall[3],
    )
    if current_timeout > baseline_overall[2]:
        raise ValueError(
            "overall timeout count regressed: "
            f"current {current_timeout} > baseline {baseline_overall[2]}"
        )

    current_by_operator = summary.get("by_operator")
    if not isinstance(current_by_operator, dict):
        raise ValueError("audited summary is missing by_operator")
    operator_results: dict[str, dict[str, Any]] = {}
    for operator in sorted(EXPECTED_OPERATORS):
        current = current_by_operator.get(operator)
        if not isinstance(current, dict):
            raise ValueError(f"audited summary is missing operator {operator}")
        values = [current.get(name) for name in ("killed", "survived", "timeout")]
        if any(type(value) is not int or value < 0 for value in values):
            raise ValueError(f"audited summary has invalid counts for {operator}")
        op_killed, op_survived, op_timeout = values
        op_viable = op_killed + op_survived + op_timeout
        base_killed, _, base_timeout, base_viable = baseline_rows[operator]
        _require_no_ratio_regression(
            f"operator {operator}",
            op_killed,
            op_viable,
            base_killed,
            base_viable,
        )
        if op_timeout > base_timeout:
            raise ValueError(
                f"operator {operator} timeout count regressed: "
                f"current {op_timeout} > baseline {base_timeout}"
            )
        operator_results[operator] = {
            "current": {
                "killed": op_killed,
                "viable": op_viable,
                "score_percent": _score_percent(op_killed, op_viable),
                "timeout": op_timeout,
            },
            "baseline": {
                "killed": base_killed,
                "viable": base_viable,
                "score_percent": _score_percent(base_killed, base_viable),
                "timeout": base_timeout,
            },
        }

    survivor_review = None
    if scope in ("capability/", "mcp/"):
        survivor_review = _enforce_survivor_review(summary, baseline, scope)
    return {
        "status": "pass",
        "survivor_review": survivor_review,
        "baseline_source": source,
        "overall": {
            "current": {
                "killed": current_killed,
                "viable": current_viable,
                "score_percent": _score_percent(current_killed, current_viable),
                "timeout": current_timeout,
            },
            "baseline": {
                "killed": baseline_overall[0],
                "viable": baseline_overall[3],
                "score_percent": _score_percent(
                    baseline_overall[0], baseline_overall[3]
                ),
                "timeout": baseline_overall[2],
            },
        },
        "by_operator": operator_results,
    }


def _read_baseline(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read mutation ratchet baseline {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("mutation ratchet baseline must be a JSON object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--survivor-dir", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--scope", choices=ALLOWED_SCOPES, default="primitives/")
    parser.add_argument("--config", type=Path, default=Path("turtles.toml"))
    args = parser.parse_args()
    report_path = args.report.resolve()
    repo_root = Path(__file__).resolve().parents[1]
    output = args.output if args.output.is_absolute() else repo_root / args.output
    try:
        survivor_dir = args.survivor_dir
        if not survivor_dir.is_absolute():
            survivor_dir = repo_root / survivor_dir
        report = _read_report(report_path)
        validate_scope_configuration(repo_root / args.config, report, args.scope)
        summary = audit_report(report, _revision(repo_root), survivor_dir, args.scope)
        if args.baseline is not None:
            baseline_path = args.baseline
            if not baseline_path.is_absolute():
                baseline_path = repo_root / baseline_path
            summary["ratchet"] = enforce_ratchet(
                summary,
                _read_baseline(baseline_path),
                args.scope,
            )
            summary["baseline_state"] = "ratchet_enforced"
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"turtles report audit failed: {error}", file=sys.stderr)
        return 2
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if "ratchet" in summary:
        current = summary["ratchet"]["overall"]["current"]
        baseline = summary["ratchet"]["overall"]["baseline"]
        print(
            "turtles mutation ratchet passed: "
            f"{current['score_percent']:.3f}% >= {baseline['score_percent']:.3f}% "
            "overall; every operator floor and timeout ceiling held"
        )
    else:
        print(
            "turtles baseline observed: "
            f"{summary['score_percent']:.3f}% ({summary['mutation_counts']}); "
            "release mutation gate remains pending"
        )
    print(f"audited summary: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
