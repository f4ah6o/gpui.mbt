#!/usr/bin/env python3
"""Observe fresh real mutations in the bounded command-palette state slice.

Survivors are test-gap evidence, not a score gate. UNVIABLE candidates are
reported separately from test kills, including warning-rejected candidates.
"""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import tomllib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SCOPE = "mutation-scopes/command-palette.toml"
SOURCES = ("controls/command_palette/picker.mbt", "controls/command_palette/palette.mbt")
OPERATORS = {"comparison", "boolean", "arithmetic", "literal", "condition"}
OUTCOMES = {"KILLED", "SURVIVED", "TIMEOUT", "UNVIABLE"}
IGNORED = {".git", "_build", ".mooncakes", ".moon", ".turtles", "node_modules", "__pycache__"}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fnv(content):
    value = 0xCBF29CE484222325
    for byte in content:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def source_state(repo):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repo)
    names = sorted(git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0"))
    manifest = {}
    for name in names:
        if name:
            path = repo / name.decode()
            if path.is_symlink():
                target = path.resolve()
                if not target.is_file() or repo not in target.parents:
                    raise RuntimeError("source symlinks must resolve to regular files inside the checkout")
                manifest[name.decode()] = {"link": str(path.readlink()), "target_sha256": sha256(target)}
            else:
                manifest[name.decode()] = sha256(path) if path.is_file() else "missing"
    return {"commit": git("rev-parse", "HEAD").decode().strip(),
            "tree": git("rev-parse", "HEAD^{tree}").decode().strip(),
            "files_sha256": manifest}


def parse_discovery(text):
    header = re.search(r"^Found (\d+) mutation\(s\)\.$", text, re.MULTILINE)
    locations = list(re.finditer(r"^([^\n]+\.mbt):(\d+):(\d+): ", text, re.MULTILINE))
    candidates = []
    for index, location in enumerate(locations):
        end = locations[index + 1].start() if index + 1 < len(locations) else len(text)
        description = text[location.end():end].strip()
        detail = re.fullmatch(r"(.*) -> (.*) \[(public|private|test)\]", description, re.DOTALL)
        if detail is None:
            raise ValueError("cannot parse pinned turtles discovery entry")
        candidates.append((location[1], int(location[2]), int(location[3]), detail[1], detail[2], detail[3]))
    if not header or int(header[1]) != len(candidates) or not candidates or len(set(candidates)) != len(candidates):
        raise ValueError("empty, incomplete, duplicate or skipped pinned-tool discovery")
    return candidates


def candidate_tuple(row):
    return tuple(row.get(key) for key in ("path", "line", "column", "original", "replacement", "visibility"))


def audit(report, snapshot, survivor_dir=None, discovery=None):
    if report.get("schema") != 2 or report.get("turtles_version") != "0.3.0":
        raise ValueError("requires turtles 0.3.0 / report schema 2")
    if report.get("module") != str(snapshot) or report.get("test_scope") != "module":
        raise ValueError("requires the exact snapshot and full portable module test scope")
    if not report.get("moon_version") or not all(str(report.get(key, "")).isdigit() for key in
            ("baseline_duration_ms", "baseline_check_ms", "baseline_test_ms")):
        raise ValueError("missing toolchain or baseline timing")
    if report.get("skipped_files") != []:
        raise ValueError("parse skips are not classified palette mutations")
    for relative in (*SOURCES, "turtles.toml"):
        if report.get("files", {}).get(relative) != fnv((snapshot / relative).read_bytes()):
            raise ValueError("source/configuration fingerprint mismatch: " + relative)
    for relative, expected in report.get("files", {}).items():
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or not (snapshot / path).is_file() or \
           fnv((snapshot / path).read_bytes()) != expected:
            raise ValueError("retained module/test input fingerprint mismatch: " + relative)
    mutants = report.get("mutants")
    if not isinstance(mutants, list) or not mutants:
        raise ValueError("empty mutation discovery is not an observation")
    if discovery is not None and (len(mutants) != len(discovery) or
            set(candidate_tuple(row) for row in mutants) != set(discovery)):
        raise ValueError("report does not classify the complete discovered candidate set")
    counts, seen, survivors, unviable, groups = Counter(), set(), [], [], {}
    for row in mutants:
        identity, outcome, path = row.get("id"), row.get("outcome"), row.get("path")
        if not identity or identity in seen or path not in SOURCES or outcome not in OUTCOMES or row.get("group") not in OPERATORS:
            raise ValueError("duplicate, invalid or out-of-scope candidate")
        seen.add(identity)
        if row.get("reused") is not False:
            raise ValueError("fresh classifications required")
        content = (snapshot / path).read_bytes()
        offset, end = row.get("offset"), row.get("end")
        if type(offset) is not int or type(end) is not int or not 0 <= offset < end <= len(content) or \
           content[offset:end].decode() != row.get("original") or not isinstance(row.get("replacement"), str):
            raise ValueError("candidate diff does not match snapshot bytes")
        if row.get("line") != content[:offset].count(b"\n") + 1:
            raise ValueError("candidate line does not match snapshot")
        counts[outcome.lower()] += 1
        groups.setdefault(row["group"], Counter())[outcome.lower()] += 1
        if outcome == "KILLED":
            kills = row.get("killed_by")
            if not isinstance(kills, list) or not kills or any(not isinstance(kill, dict) or
                    not kill.get("package") or not kill.get("filename") or type(kill.get("index")) is not int or
                    kill.get("kind") not in {"Assertion", "Property", "Snapshot", "DocTest"} for kill in kills):
                raise ValueError("unattributed test failure cannot count as a kill")
        if outcome in {"SURVIVED", "TIMEOUT"}:
            if survivor_dir is not None and not (survivor_dir / (identity + ".diff")).is_file():
                raise ValueError("missing retained unresolved diff: " + identity)
            survivors.append({key: row[key] for key in
                              ("id", "path", "line", "group", "original", "replacement", "outcome")})
        if outcome == "UNVIABLE":
            unviable.append(row)
    if survivor_dir is not None:
        expected = {row["id"] + ".diff" for row in mutants if row["outcome"] in {"SURVIVED", "TIMEOUT"}}
        actual = {path.name for path in survivor_dir.glob("*.diff")} if survivor_dir.is_dir() else set()
        if actual != expected:
            raise ValueError("retained unresolved diffs do not match report")
    summary = report.get("summary", {})
    for key in ("killed", "survived", "timeout", "unviable"):
        if type(summary.get(key)) is not int or summary[key] != counts[key]:
            raise ValueError("summary count mismatch: " + key)
    viable = counts["killed"] + counts["survived"] + counts["timeout"]
    if not viable or summary.get("reused") != 0:
        raise ValueError("observation needs viable fresh mutants")
    score = summary.get("score")
    if not isinstance(score, (int, float)) or not math.isclose(score, counts["killed"] * 100 / viable):
        raise ValueError("incorrect mutation score")
    return {"attempted_candidates": len(mutants), "qualified_viable": viable,
            "counts": {key: counts[key] for key in ("killed", "survived", "timeout", "unviable")},
            "score_percent": score, "by_operator": groups, "unresolved": survivors,
            "unviable_candidates": unviable,
            "mutation_policy": "observe-only: investigate survivors; no score threshold"}


def replay_unviable(report, snapshot, output):
    """Retain the actual default-target compiler reason, separate from kills.

    Mirrors official turtles 0.3.0's `moon check` command. A warning alongside
    an unbound-name/type error is a compiler-error rejection, not warning-only.
    """
    rows = [row for row in report["mutants"] if row["outcome"] == "UNVIABLE"]
    counts = {"warning_only": 0, "compiler_error": 0, "other_check_failure": 0}
    if not rows:
        return {"counts": counts, "candidates": []}
    root = output / "unviable-replay-source"
    shutil.copytree(snapshot, root, ignore=lambda _, names: [name for name in names if name in IGNORED])
    logs = output / "unviable-check-logs"
    logs.mkdir()
    def check(name):
        result = subprocess.run(["moon", "check"], cwd=root, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=60)
        (logs / name).write_text(result.stdout)
        return result
    baseline = check("baseline.log")
    if baseline.returncode:
        raise ValueError("unviable replay baseline check failed; refusing diagnostic classification")
    observations = []
    for row in rows:
        source = root / row["path"]
        original = source.read_bytes()
        source.write_bytes(original[:row["offset"]] + row["replacement"].encode() + original[row["end"]:])
        try:
            name = row["id"] + ".log"
            result = check(name)
        finally:
            source.write_bytes(original)
        if result.returncode == 0:
            raise ValueError("UNVIABLE replay unexpectedly compiled: " + row["id"])
        errors = re.findall(r"(?m)^Error: \[([0-9]+)\]", result.stdout)
        warnings = re.findall(r"(?m)^Warning: \[([0-9]+)\]", result.stdout)
        kind = "compiler_error" if errors else "warning_only" if warnings else "other_check_failure"
        counts[kind] += 1
        observations.append({"id": row["id"], "check_exit_code": result.returncode,
                             "diagnostic_kind": kind, "error_codes": errors, "warning_codes": warnings,
                             "log_file": "unviable-check-logs/" + name,
                             "log_sha256": sha256(logs / name)})
    return {"counts": counts, "candidates": observations}


def execute(repo, binary, output, jobs=2):
    repo, binary, output = repo.resolve(), binary.resolve(), output.resolve()
    if output == repo or repo in output.parents:
        raise ValueError("output must be a new external directory")
    output.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    record = {"schema_version": 1, "scope": "portable command-palette state mutation",
              "target": "wasm", "target_selection": "Moon default, verified dry-run",
              "selection": "complete explicit source files; no changed-line filtering",
              "source_files": list(SOURCES), "turtles_version": "0.3.0", "report_schema": 2,
              "cache_policy": "fresh outcomes; warm build cache only inside this invocation",
              "ok": False}
    before = source_state(repo)
    record["source_before"] = before
    try:
        version = subprocess.check_output([str(binary), "--version"], text=True).strip()
        if version != "turtles 0.3.0":
            raise RuntimeError("requires the official pinned turtles 0.3.0 installation")
        record["tool_binary_sha256"] = sha256(binary)
        record["moon_version"] = subprocess.check_output(["moon", "version", "--all"], text=True).strip()
        config = tomllib.loads((repo / SCOPE).read_text())
        if set(config) != {"include", "operators"} or config["include"] != list(SOURCES) or \
           set(config["operators"]) != OPERATORS:
            raise RuntimeError("palette scope must retain both complete files and all five operator groups")
        if any(re.search(r"#turtles\.skip|turtles:\s*skip", (repo / path).read_text()) for path in SOURCES):
            raise RuntimeError("palette scope cannot gain mutation skip markers")
        snapshot = output / "source"
        shutil.copytree(repo, snapshot, ignore=lambda _, names: [name for name in names if name in IGNORED])
        shutil.copy2(repo / SCOPE, snapshot / "turtles.toml")
        dry = subprocess.check_output(["moon", "test", "--dry-run"], cwd=snapshot, text=True)
        (output / "target-plan.log").write_text(dry)
        targets = set(re.findall(r"-target ([\w-]+)", dry))
        if targets != {"wasm"}:
            raise RuntimeError("default target changed; deliberately qualify the new target first")
        discovery_command = [str(binary), "--dir", str(snapshot), "--list"]
        discovery_text = subprocess.check_output(discovery_command, text=True, stderr=subprocess.STDOUT)
        (output / "discovery.log").write_text(discovery_text)
        discovery = parse_discovery(discovery_text)
        record["discovery_command"] = discovery_command
        record["discovered_candidates"] = len(discovery)
        command = [str(binary), "--dir", str(snapshot), "--jobs", str(jobs), "--timeout", "60",
                   "--timeout-multiplier", "3", "--fail-under", "0", "--emit-regressions",
                   "--json", str(output / "report.json"), "--output-dir", str(output / "turtles")]
        record["command"] = command
        timer = time.perf_counter()
        with (output / "console.log").open("w") as stream:
            result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
        record["mutation_seconds"] = time.perf_counter() - timer
        record["turtles_exit_code"] = result.returncode
        if result.returncode:
            raise RuntimeError("turtles setup/execution failed; raw logs retained")
        report = json.loads((output / "report.json").read_text())
        record["attempted_candidates"] = len(report.get("mutants", []))
        record["observed_counts"] = report.get("summary")
        record.update(audit(report, snapshot, output / "turtles/survivors", discovery))
        record["unviable_diagnostics"] = replay_unviable(report, snapshot, output)
        record["ok"] = True
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        record["error"] = str(error)
    finally:
        record["source_after"] = source_state(repo)
        record["source_stable"] = before == record["source_after"]
        if not record["source_stable"]:
            record["ok"] = False
            record["error"] = "source changed during mutation observation"
        record["total_seconds"] = time.perf_counter() - started
        (output / "summary.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({key: record.get(key) for key in ("ok", "counts", "qualified_viable", "error", "total_seconds")}))
    return 0 if record["ok"] else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=REPO)
    parser.add_argument("--turtles-bin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args(argv)
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    return execute(args.repo, args.turtles_bin, args.output, args.jobs)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print("palette-mutation: " + str(error), file=sys.stderr)
        sys.exit(1)
