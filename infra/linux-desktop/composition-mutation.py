#!/usr/bin/env python3
"""Run and audit the explicit portable composition-file mutation acceptance."""

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
SCOPE = "mutation-scopes/composition.toml"
REVIEW = "mutation-baselines/composition-reviewed.json"
SOURCES = ("controls/text_field/composition.mbt", "text/composition.mbt")
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


def audit(report, snapshot, review, survivor_dir=None, discovery=None):
    if report.get("schema") != 2 or report.get("turtles_version") != "0.3.0":
        raise ValueError("requires turtles 0.3.0 / report schema 2")
    if report.get("module") != str(snapshot) or report.get("test_scope") != "module":
        raise ValueError("requires the exact snapshot and full portable module test scope")
    if not report.get("moon_version") or not all(str(report.get(key, "")).isdigit() for key in
            ("baseline_duration_ms", "baseline_check_ms", "baseline_test_ms")):
        raise ValueError("missing toolchain or baseline timing")
    if report.get("skipped_files") != []:
        raise ValueError("parse skips cannot pass composition acceptance")
    fingerprints = report.get("files", {})
    for relative in (*SOURCES, "turtles.toml"):
        if fingerprints.get(relative) != fnv((snapshot / relative).read_bytes()):
            raise ValueError("source/configuration fingerprint mismatch: " + relative)
    if review.get("schema_version") != 1 or review.get("kind") != "composition-survivor-review" or \
       review.get("turtles_version") != "0.3.0" or review.get("report_schema") != 2:
        raise ValueError("invalid survivor review identity")
    approved = {}
    for row in review.get("survivors", []):
        if row.get("id") in approved or not row.get("rationale") or not row.get("classification"):
            raise ValueError("duplicate or unexplained survivor review")
        approved[row["id"]] = row
    mutants = report.get("mutants")
    if not isinstance(mutants, list) or not mutants:
        raise ValueError("empty mutation discovery is not acceptance")
    if discovery is not None and (len(mutants) != len(discovery) or
            set(candidate_tuple(row) for row in mutants) != set(discovery)):
        raise ValueError("report does not classify the complete fresh discovered candidate set")
    counts, groups, paths, seen, classified = Counter(), {}, {}, set(), []
    for row in mutants:
        identity, outcome, path = row.get("id"), row.get("outcome"), row.get("path")
        if not identity or identity in seen or path not in SOURCES or outcome not in OUTCOMES or row.get("group") not in OPERATORS:
            raise ValueError("duplicate, invalid or out-of-scope candidate")
        seen.add(identity)
        if row.get("reused") is not False:
            raise ValueError("acceptance requires fresh classifications, not cached outcomes")
        content = (snapshot / path).read_bytes()
        offset, end = row.get("offset"), row.get("end")
        if type(offset) is not int or type(end) is not int or not 0 <= offset < end <= len(content) or \
           content[offset:end].decode() != row.get("original") or not isinstance(row.get("replacement"), str):
            raise ValueError("candidate diff does not match snapshot bytes")
        if row.get("line") != content[:offset].count(b"\n") + 1:
            raise ValueError("candidate line does not match snapshot")
        counts[outcome.lower()] += 1
        groups.setdefault(row["group"], Counter())[outcome.lower()] += 1
        paths.setdefault(path, Counter())[outcome.lower()] += 1
        if outcome == "KILLED":
            kills = row.get("killed_by")
            if not isinstance(kills, list) or not kills or any(not isinstance(kill, dict) or
                    not kill.get("package") or not kill.get("filename") or type(kill.get("index")) is not int or
                    kill.get("kind") not in {"Assertion", "Property", "Snapshot", "DocTest"} for kill in kills):
                raise ValueError("unattributed test failure is not a qualified composition kill")
        if outcome == "SURVIVED":
            if survivor_dir is not None and not (survivor_dir / (identity + ".diff")).is_file():
                raise ValueError("missing raw survivor diff: " + identity)
            allowed = approved.get(identity)
            if not allowed or any(allowed.get(key) != row.get(key) for key in
                    ("id", "path", "offset", "end", "original", "replacement", "group")) or \
               allowed.get("source_sha256") != hashlib.sha256(content).hexdigest():
                raise ValueError("unreviewed or stale survivor: " + identity)
            for dependency, expected in allowed.get("rationale_dependencies_sha256", {}).items():
                if dependency.startswith("/") or ".." in Path(dependency).parts or \
                   not (snapshot / dependency).is_file() or sha256(snapshot / dependency) != expected:
                    raise ValueError("stale survivor rationale dependency: " + dependency)
            if survivor_dir is not None and sha256(survivor_dir / (identity + ".diff")) != allowed.get("diff_sha256"):
                raise ValueError("raw survivor diff differs from reviewed hunk: " + identity)
            classified.append({"id": identity, "classification": allowed["classification"],
                               "rationale": allowed["rationale"]})
    if survivor_dir is not None:
        expected_diffs = {row["id"] + ".diff" for row in mutants if row["outcome"] == "SURVIVED"}
        actual_diffs = {path.name for path in survivor_dir.iterdir()} if survivor_dir.is_dir() else set()
        if actual_diffs != expected_diffs:
            raise ValueError("raw survivor diff set is not exactly the current survivor set")
    summary = report.get("summary", {})
    for key in ("killed", "survived", "timeout", "unviable"):
        if type(summary.get(key)) is not int or summary[key] != counts[key]:
            raise ValueError("summary count mismatch: " + key)
    viable = counts["killed"] + counts["survived"] + counts["timeout"]
    if not viable or counts["timeout"] or counts["unviable"] or summary.get("reused") != 0:
        raise ValueError("no viable evidence, timeout, unqualified check failure, or cached evidence")
    score = summary.get("score")
    if not isinstance(score, (int, float)) or not math.isclose(score, counts["killed"] * 100 / viable):
        raise ValueError("incorrect mutation score")
    return {"attempted_candidates": len(mutants), "qualified_viable": viable,
            "counts": {key: counts[key] for key in ("killed", "survived", "timeout", "unviable")},
            "score_percent": score, "by_operator": groups, "by_source_file": paths,
            "reviewed_survivors": classified, "unreviewed_survivors": 0}


def execute(repo, binary, output, jobs=2):
    repo, binary, output = repo.resolve(), binary.resolve(), output.resolve()
    if output == repo or repo in output.parents:
        raise ValueError("output must be a new external directory")
    output.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    record = {"schema_version": 1, "scope": "portable composition-file mutation",
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
            raise RuntimeError("composition scope must retain both complete files and all five operator groups")
        if any(re.search(r"#turtles\.skip|turtles:\s*skip", (repo / path).read_text()) for path in SOURCES):
            raise RuntimeError("composition scope cannot gain mutation skip markers")
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
        record.update(audit(report, snapshot, json.loads((repo / REVIEW).read_text()),
                            output / "turtles/survivors", discovery))
        record["ok"] = True
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        record["error"] = str(error)
    finally:
        record["source_after"] = source_state(repo)
        record["source_stable"] = before == record["source_after"]
        if not record["source_stable"]:
            record["ok"] = False
            record["error"] = "source changed during mutation acceptance"
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
        print("composition-mutation: " + str(error), file=sys.stderr)
        sys.exit(1)
