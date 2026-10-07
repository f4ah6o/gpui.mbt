#!/usr/bin/env python3
"""Run the pinned Mac profile's required local quality stages through actrun."""

import argparse
from contextlib import contextmanager
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
PROFILE_MODULE = HERE / "profile.py"
ACTRUN_LOCK = HERE / "actrun-runner.lock.json"
COMPOSITION_MUTATION = REPO / "infra/linux-desktop/composition-mutation.py"
PACKAGES = "text controls/text_field platform/macos platform/macos_text examples/macos_text_field"


class RunnerError(RuntimeError):
    pass


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_snapshot(repo):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repo, timeout=30)
    names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    inputs = hashlib.sha256()
    for raw in sorted(name for name in names if name):
        path = repo / os.fsdecode(raw)
        inputs.update(raw + b"\0")
        if path.is_symlink():
            inputs.update(b"link\0" + os.fsencode(path.readlink()))
        elif path.is_file():
            inputs.update(b"file\0" + hashlib.sha256(path.read_bytes()).digest())
        else:
            inputs.update(b"missing\0")
    return {"commit": git("rev-parse", "HEAD").decode().strip(),
            "tree": git("rev-parse", "HEAD^{tree}").decode().strip(),
            "tracked_patch_sha256": hashlib.sha256(git("diff", "--binary", "HEAD")).hexdigest(),
            "input_files_sha256": inputs.hexdigest(),
            "status": git("status", "--porcelain", "--untracked-files=all").decode()}


def external_path(value, profile):
    candidate = Path(value).expanduser().absolute()
    if candidate.is_symlink():
        raise RunnerError("run directory must not be a symbolic link")
    path = candidate.resolve()
    if path == Path("/") or path == REPO or REPO in path.parents or path == profile or profile in path.parents:
        raise RunnerError("run directory must be external to both checkout and installed profile")
    return path


def verify_runner(cli, root, node, expected_package_lock_sha):
    lock = json.loads(ACTRUN_LOCK.read_text())
    cli = Path(cli).expanduser().resolve(strict=True)
    package_json = cli.parent.parent / "package.json"
    package_lock = root / "tools/actrun/package-lock.json"
    package = json.loads(package_json.read_text())
    if (package.get("name"), package.get("version")) != (lock["name"], lock["version"]):
        raise RunnerError("installed actrun package name/version differs from lock")
    if digest(cli) != lock["cli_sha256"] or digest(package_lock) != expected_package_lock_sha:
        raise RunnerError("installed actrun CLI or npm package lock differs from pinned bytes")
    version = subprocess.check_output([str(node), "--version"], text=True, timeout=10).strip()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version) or int(version[1:].split(".", 1)[0]) < lock["node_minimum_major"]:
        raise RunnerError("selected Node.js is below the pinned actrun runtime minimum")
    return {"cli": str(cli), "cli_sha256": digest(cli), "node": str(Path(node).resolve(strict=True)),
            "node_sha256": digest(node), "node_version": version,
            "package_lock_sha256": digest(package_lock), "package": lock["name"], "version": lock["version"]}


COMMON = [
    ("repo-tests", "Repository contract and Python unit tests", 600,
     '"$GPUI_MACOS_PYTHON" -m unittest discover -s tests -p \'test_*.py\' && "$GPUI_MACOS_PYTHON" scripts/check_contracts.py'),
    ("macos-runner-tests", "Mac profile, runner, and evidence collector tests", 300,
     '"$GPUI_MACOS_PYTHON" -m unittest discover -s infra/macos-desktop/tests'),
]
FORMAT = [("format", "MoonBit formatting", 300, '"$MOON_HOME/bin/moon" fmt --check')]
FAST = COMMON + [
    ("check-native", "Type-check affected native MoonBit packages", 900,
     '"$MOON_HOME/bin/moon" check ' + PACKAGES + ' --target native --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/moon-native"'),
    ("check-all-targets", "Type-check all repository targets with warnings denied", 1500,
     '"$MOON_HOME/bin/moon" check --target all --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/moon-all-targets"'),
    ("test-model", "Text-field owner and model tests", 900,
     '"$MOON_HOME/bin/moon" test --package f4ah6o/gpui/examples/macos_text_field --target native --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/model-native"'),
]
NATIVE = FAST + [
    ("native-macos", "Synthetic Mac native E2E, CoreText, and fresh test-hook app build", 1500,
     'bash script/test_macos.sh all --target-dir "$GPUI_ACTRUN_RUN_DIR/checks"'),
    ("ime-acceptance", "Live Kotoeri composition callbacks and owned-window pixel proof", 300,
     '"$GPUI_MACOS_PYTHON" infra/macos-desktop/ime-acceptance.py --repo "$GPUI_ACTRUN_REPO" --profile "$GPUI_MACOS_PROFILE_ROOT" --app "$GPUI_ACTRUN_RUN_DIR/checks/text-field/build/macos/GpuiTextField.app" --output "$GPUI_ACTRUN_RUN_DIR/ime-acceptance"'),
]
PORTABLE = [
    ("portable-composition-mutation-tests", "Portable composition mutation producer regression tests", 240,
     'TMPDIR=/private/tmp "$GPUI_MACOS_PYTHON" -m unittest discover -s infra/linux-desktop/tests -p test_composition_mutation.py'),
    ("portable-composition-proof-tests", "Portable source-exact proof producer regression tests", 240,
     'TMPDIR=/private/tmp "$GPUI_MACOS_PYTHON" -m unittest discover -s infra/linux-desktop/tests -p test_composition_proof.py'),
    ("portable-proof-evidence-tests", "Portable proof evidence validator regression tests", 240,
     'TMPDIR=/private/tmp "$GPUI_MACOS_PYTHON" -m unittest discover -s infra/linux-desktop/tests -p test_proof_evidence.py'),
    ("portable-turtles-verification-tests", "Portable schema-3 mutation evidence regression tests", 240,
     'TMPDIR=/private/tmp "$GPUI_MACOS_PYTHON" -m unittest discover -s infra/linux-desktop/tests -p test_turtles_verification.py'),
    ("composition-oracle-wasm", "TextField composition oracle on wasm", 600,
     '"$MOON_HOME/bin/moon" test controls/text_field --target wasm --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/composition-oracle-wasm"'),
    ("composition-oracle-wasm-gc", "TextField composition oracle on wasm-gc", 600,
     '"$MOON_HOME/bin/moon" test controls/text_field --target wasm-gc --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/composition-oracle-wasm-gc"'),
    ("composition-oracle-js", "TextField composition oracle on js", 600,
     '"$MOON_HOME/bin/moon" test controls/text_field --target js --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/composition-oracle-js"'),
    ("composition-oracle-native", "TextField composition oracle on native", 600,
     '"$MOON_HOME/bin/moon" test controls/text_field --target native --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/composition-oracle-native"'),
    ("composition-mutation", "Fresh pinned Turtles schema-2 mutation and reviewed survivor audit", 1800,
     '"$GPUI_MACOS_PYTHON" infra/linux-desktop/composition-mutation.py --turtles-bin "$GPUI_TURTLES_BIN" --output "$GPUI_ACTRUN_RUN_DIR/composition-mutation"'),
]
PROOF = [
    ("composition-proof", "Five-goal Why3/Z3 proof with two negative controls", 1200,
     '"$GPUI_MACOS_PYTHON" infra/macos-desktop/composition-proof.py --source-root "$GPUI_ACTRUN_REPO" --artifact-dir "$GPUI_ACTRUN_RUN_DIR/moon-proof" --moon-home "$MOON_HOME"'),
]
VERIFICATION = [
    ("turtles-verification", "Actual schema-3 helper mutants with PBT, runtime, and proof evidence", 3900,
     '"$GPUI_MACOS_PYTHON" infra/macos-desktop/turtles-verification.py --repo "$GPUI_ACTRUN_REPO" --turtles-root "$GPUI_TURTLES_VERIFICATION_ROOT" --turtles-bin "$GPUI_TURTLES_SCHEMA3_BIN" --profile "$GPUI_TURTLES_VERIFICATION_PROFILE" --output "$GPUI_ACTRUN_RUN_DIR/turtles-verification" --moon-home "$MOON_HOME" --why3 "$GPUI_PROOF_WHY3" --solver "$GPUI_PROOF_SOLVER" --ephemeral-workflow "$GPUI_ACTRUN_WORKFLOW"'),
]
PERFORMANCE = [
    ("input-hotpath", "Pinned CoreText hotpath workload with resolved font provenance", 900,
     '"$GPUI_MACOS_PYTHON" infra/macos-desktop/input-hotpath.py --hotpath-root "$GPUI_HOTPATH_ROOT" --output "$GPUI_ACTRUN_RUN_DIR/input-hotpath"'),
]


def stages_for(mode):
    return {
        "fast": FAST,
        "native": NATIVE,
        "acceptance": NATIVE,
        "mutation": PORTABLE,
        "proof": PROOF,
        "verification": VERIFICATION,
        "performance": PERFORMANCE,
        "quality": FAST + FORMAT + PORTABLE + PROOF + VERIFICATION + PERFORMANCE + NATIVE[len(FAST):],
    }[mode]


def read_json(path):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise RunnerError("duplicate JSON evidence key: " + key)
            value[key] = item
        return value
    def reject(value):
        raise RunnerError("nonfinite JSON evidence value: " + value)
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs, parse_constant=reject)


def mutation_evidence(output, environment):
    directory = output / "composition-mutation"
    summary_path = directory / "summary.json"
    raw_path = directory / "report.json"
    survivor_dir = directory / "turtles/survivors"
    discovery_path = directory / "discovery.log"
    if any(not path.is_file() or path.is_symlink() for path in (summary_path, raw_path, discovery_path)) or \
       not survivor_dir.is_dir() or survivor_dir.is_symlink():
        raise RunnerError("portable mutation stage omitted raw report/discovery/survivor artifacts")
    summary, raw = read_json(summary_path), read_json(raw_path)
    profile = load("macos_mutation_profile", PROFILE_MODULE)
    profile_root = profile.external_path(environment.get("GPUI_MACOS_PROFILE_ROOT", ""))
    profile.doctor(profile_root)
    marker = read_json(profile_root / "installed.json")
    binary = Path(environment.get("GPUI_TURTLES_BIN", "")).resolve(strict=True)
    expected = profile_root / "tools/turtles-schema2/turtles"
    receipt = marker.get("quality_tools", {})
    if binary != expected.resolve(strict=True) or digest(binary) != receipt.get("schema2_binary_sha256") or \
       receipt.get("schema2_lock_sha256") != digest(HERE / "turtles-schema2.lock.json") or \
       subprocess.check_output([str(binary), "--version"], text=True, timeout=10).strip() != "turtles 0.3.0":
        raise RunnerError("schema-2 Turtles binary differs from its exact Mac profile receipt")
    producer = load("macos_mutation_producer", COMPOSITION_MUTATION)
    before = producer.source_state(REPO)
    if summary.get("ok") is not True or summary.get("source_stable") is not True or \
       summary.get("source_before") != before or summary.get("source_after") != before or \
       summary.get("tool_binary_sha256") != digest(binary) or summary.get("turtles_version") != "0.3.0" or \
       summary.get("report_schema") != 2 or summary.get("target") != "wasm" or \
       summary.get("unreviewed_survivors") != 0:
        raise RunnerError("mutation summary is stale or outside the pinned portable scope")
    snapshot = directory / "source"
    if not snapshot.is_dir() or snapshot.is_symlink():
        raise RunnerError("mutated source snapshot is missing")
    discovery = producer.parse_discovery(discovery_path.read_text())
    audited = producer.audit(raw, snapshot, read_json(REPO / "mutation-baselines/composition-reviewed.json"),
                             survivor_dir, discovery)
    fields = ("attempted_candidates", "qualified_viable", "counts", "score_percent", "by_operator",
              "by_source_file", "reviewed_survivors", "unreviewed_survivors")
    if any(summary.get(key) != audited.get(key) for key in fields):
        raise RunnerError("independent mutation report audit differs from producer summary fields")
    return {key: summary[key] for key in ("scope", "target", "selection", "source_files", "turtles_version",
            "report_schema", "attempted_candidates", "qualified_viable", "counts", "score_percent",
            "reviewed_survivors", "mutation_seconds", "total_seconds", "tool_binary_sha256")}


def workflow_text(mode):
    stages = stages_for(mode)
    lines = ["name: Local Mac " + mode + " quality", "on:", "  push:", "jobs:",
             "  macos-local:", "    runs-on: macos-latest", "    timeout-minutes: 300", "    steps:"]
    for identity, title, timeout, command in stages:
        wrapped = ('"$GPUI_MACOS_PYTHON" infra/macos-desktop/stage.py --run-dir '
                   '"$GPUI_ACTRUN_RUN_DIR" --id ' + identity + ' --timeout ' + str(timeout) + ' -- /bin/bash -c ' +
                   shlex.quote(command))
        lines += ["      - id: " + identity, "        name: " + title, "        run: |", "          " + wrapped]
    return "\n".join(lines) + "\n"


@contextmanager
def temporary_workflow(repo):
    directory = repo / ".github/workflows"
    if not directory.is_dir() or directory.resolve() != directory:
        raise RunnerError("local actrun expects this checkout's .github/workflows directory")
    path = directory / ("_local-actrun-feedback-" + uuid.uuid4().hex + ".yml")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            yield path, stream
    finally:
        path.unlink(missing_ok=True)


def stage_status(output, stages):
    run_path = output / "runs"
    candidates = list(run_path.glob("run-*/run.json"))
    if len(candidates) != 1:
        raise RunnerError("actrun did not leave exactly one inspectable run.json")
    run = json.loads(candidates[0].read_text())
    tasks = {row.get("id", ""): row for row in run.get("tasks", [])}
    task_rows = []
    coverage = []
    for identity, title, timeout, _ in stages:
        row = tasks.get("macos-local/" + identity)
        passed = row is not None and row.get("status") == "success" and row.get("code") == 0
        task_rows.append({key: row.get(key) for key in ("id", "status", "code", "duration_ms")} if row else
                         {"id": "macos-local/" + identity, "status": "missing", "code": None})
        coverage.append({"id": identity, "scope": title, "status": "passed" if passed else "failed",
                         "timeout_seconds": timeout})
    expected_ids = {"macos-local/" + row[0] for row in stages}
    finish_id = "macos-local/__finish"
    extras = set(tasks) - expected_ids
    if extras not in (set(), {finish_id}):
        raise RunnerError("actrun task inventory contains an unreviewed stage")
    steps = {row.get("id", ""): row for row in run.get("steps", [])}
    if set(steps) != expected_ids | {finish_id} or steps[finish_id].get("status") not in {"success", "blocked"}:
        raise RunnerError("actrun step inventory omits a required stage or final barrier")
    if run.get("ok") is True and (finish_id not in tasks or tasks[finish_id].get("status") != "success" or
                                  tasks[finish_id].get("code") != 0 or steps[finish_id].get("status") != "success"):
        raise RunnerError("actrun completed successfully without its successful final barrier")
    return run, task_rows, coverage


@contextmanager
def canonical_source_environment(environment, workflow, output, repo=REPO, expected_snapshot=None):
    """Verify the repo's existing ignore rule keeps the current local workflow ephemeral."""
    repo = Path(repo).resolve(strict=True)
    selected = Path(workflow)
    if selected.is_symlink() or not selected.is_file():
        raise RunnerError("generated local workflow is not a regular file")
    relative = selected.resolve(strict=True).relative_to(repo).as_posix()
    if not re.fullmatch(r"\.github/workflows/_local-actrun-feedback-[0-9a-f]{32}\.yml", relative):
        raise RunnerError("source inventory exclusion is not the current exact generated workflow")
    ignored = subprocess.run(["git", "check-ignore", "-v", "--no-index", "--", relative], cwd=repo,
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    if ignored.returncode != 0:
        raise RunnerError("repository ignore rules do not exclude the generated local workflow")
    line = ignored.stdout.strip()
    fields = line.split(":", 2)
    if len(fields) != 3 or Path(fields[0]).name != ".gitignore" or \
       fields[2].split("\t", 1)[0] != ".github/workflows/_local-actrun-feedback-*.yml":
        raise RunnerError("generated local workflow is excluded by an unreviewed/global Git ignore rule")
    identity = {"path": relative, "sha256": digest(selected), "mode": selected.stat().st_mode & 0o777,
                "ignore_source": ".gitignore", "ignore_pattern": fields[2].split("\t", 1)[0],
                "source_snapshot_sha256": hashlib.sha256(
                    json.dumps(source_snapshot(repo), sort_keys=True, separators=(",", ":")).encode()
                ).hexdigest()}
    if expected_snapshot is not None and source_snapshot(repo) != expected_snapshot:
        raise RunnerError("generated workflow changed the canonical source snapshot before actrun stages")
    yield identity


def evidence(output, mode, environment, workflow_identity):
    result = {}
    if mode in {"mutation", "quality"}:
        result["mutation"] = mutation_evidence(output, environment)
    if mode in {"proof", "quality"}:
        module = load("macos_gate_proof_evidence", HERE / "proof-evidence.py")
        result["proof"] = module.validate(output / "moon-proof", REPO, environment, source_snapshot(REPO))
    if mode in {"verification", "quality"}:
        module = load("macos_gate_turtles_verification", HERE / "turtles-verification.py")
        report = module.validate(output / "turtles-verification", REPO, environment,
                                 expected_workflow=workflow_identity)
        if type(report) is not dict or report.get("kind") != "bounded-real-mutant-helper-verification":
            raise RunnerError("schema-3 validator did not return its audited helper scope")
        result["verification"] = report
    if mode in {"performance", "quality"}:
        module = load("macos_gate_hotpath", HERE / "input-hotpath.py")
        summary = output / "input-hotpath/summary.json"
        if not summary.is_file() or summary.is_symlink():
            raise RunnerError("Mac CoreText hotpath stage did not emit summary.json")
        report = json.loads(summary.read_text())
        report = module.validate_evidence(report, summary.parent)
        current = source_snapshot(REPO)
        if report.get("source_before") != current or report.get("source_after") != current:
            raise RunnerError("hotpath report is stale for the current checkout/source snapshot")
        result["performance"] = {key: report.get(key) for key in ("scope", "excluded", "hotpath_runtime",
                                      "binary_sha256", "workload_sha256", "behavior_equal", "statistics",
                                      "performance_policy", "environment")}
    if mode in {"native", "acceptance", "quality"}:
        ime = load("macos_gate_ime", HERE / "ime-acceptance.py")
        summary = output / "ime-acceptance/summary.json"
        if not summary.is_file() or summary.is_symlink():
            raise RunnerError("actual IME acceptance did not emit its strict summary")
        report = load("macos_gate_ime", HERE / "ime-acceptance.py").validate_summary(
            summary, REPO, source_snapshot(REPO))
        if report.get("ok") is not True or report.get("status") != "passed" or report.get("source_stable") is not True:
            raise RunnerError("actual IME/pixel acceptance report is not a current pass")
        result["native_ime"] = {"summary_sha256": digest(summary), "input_source": report.get("input_source"),
                                "commit_callbacks": report.get("final_acceptance", {}).get("commit_callbacks"),
                                "pixel_differences": report.get("pixel_differences"),
                                "screenshots": report.get("screenshots")}
    return result


def execute(root, output, mode="fast", actrun_cli=None):
    started = time.perf_counter()
    profile = load("gpui_macos_quality_profile", PROFILE_MODULE)
    root = profile.external_path(root)
    output = external_path(output, root)
    if output.exists():
        raise RunnerError("run directory must be new; evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=False)
    before = source_snapshot(REPO)
    report = {"schema_version": 1, "mode": mode, "scope": "local macOS " + mode,
              "started_at": dt.datetime.now(dt.timezone.utc).isoformat(), "source_before": before,
              "ok": False, "status": "running", "green_scope": None, "coverage": [], "tasks": []}
    try:
        doctor_log = output / "doctor.log"
        result = subprocess.run([sys.executable, str(PROFILE_MODULE), "--root", str(root), "doctor"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        doctor_log.write_text(result.stdout)
        report["doctor_status"] = "passed" if result.returncode == 0 else "failed"
        if result.returncode:
            raise RunnerError("Mac profile doctor failed; see doctor.log")
        environment = profile.profile_environment(root)
        node = shutil.which("node", path=environment.get("PATH"))
        if not node:
            raise RunnerError("Node.js >=18 is required for actrun; no packages are installed automatically")
        cli = Path(actrun_cli or root / "tools/actrun/node_modules/@mizchi/actrun/dist/actrun.js")
        tool = verify_runner(cli, root, node, profile.lock()["actrun"]["package_lock_sha256"])
        report["runtime"] = {**tool, "python": str(Path(sys.executable).resolve()),
                              "python_sha256": digest(sys.executable), "python_version": sys.version,
                              "profile_root": str(root), "profile_lock_sha256": digest(HERE / "profile.lock.json"),
                              "installed_marker_sha256": digest(root / "installed.json"),
                              "host_identity": profile.host_identity()}
        environment.update({"GPUI_MACOS_PYTHON": str(Path(sys.executable).resolve()),
                           "GPUI_ACTRUN_REPO": str(REPO), "GPUI_ACTRUN_RUN_DIR": str(output),
                           "GPUI_ACTRUN_BUILD_DIR": str(output / "build"),
                           "XDG_CACHE_HOME": str(output / "build/xdg-cache")})
        Path(environment["GPUI_ACTRUN_BUILD_DIR"]).mkdir(parents=True)
        template = workflow_text(mode)
        report["runner_cli_sha256"] = tool["cli_sha256"]
        report["entrypoint_sha256"] = digest(HERE / "actrun-feedback.py")
        report["stage_runner_sha256"] = digest(HERE / "stage.py")
        report["workflow_template_sha256"] = hashlib.sha256(template.encode()).hexdigest()
        report["required_stage_ids"] = [row[0] for row in stages_for(mode)]
        with temporary_workflow(REPO) as (workflow, stream):
            stream.write(template)
            stream.flush()
            os.fsync(stream.fileno())
            workflow_identity = {"path": workflow.relative_to(REPO).as_posix(),
                                 "sha256": digest(workflow), "mode": workflow.stat().st_mode & 0o777}
            report["generated_local_workflow"] = workflow_identity
            (output / "workflow.yml").write_text(template)
            environment["GPUI_ACTRUN_WORKFLOW"] = str(workflow)
            command = [node, str(cli), "workflow", "run", str(workflow), "--workspace-mode", "local",
                       "--run-root", str(output / "runs"), "--artifact-root", str(output / "artifacts"),
                       "--cache-root", str(root / "feedback-cache"), "--no-nix"]
            with canonical_source_environment(environment, workflow, output, expected_snapshot=before) as exclusion:
                report["source_exclusion"] = exclusion
                result = subprocess.run(command, cwd=REPO, env=environment, text=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=18000)
                (output / "actrun.log").write_text(result.stdout)
                print(result.stdout, end="")
                report["actrun_command"] = command
                report["actrun_exit_code"] = result.returncode
                match = re.search(r"^run_id=(run-[A-Za-z0-9_-]+)$", result.stdout, re.MULTILINE)
                if not match:
                    raise RunnerError("actrun did not publish a run_id; see actrun.log")
                run, tasks, coverage = stage_status(output, stages_for(mode))
                report["actrun_run_id"] = match[1]
                report["actrun_state"] = run.get("state")
                report["actrun_ok"] = run.get("ok")
                report["tasks"], report["coverage"] = tasks, coverage
                if result.returncode or run.get("ok") is not True or run.get("state") != "completed":
                    raise RunnerError("actrun did not complete every task successfully")
                if any(row["status"] != "passed" for row in coverage):
                    raise RunnerError("a required stage is missing, skipped, or failed")
                report["evidence"] = evidence(output, mode, environment, workflow_identity)
        report["ok"] = True
        report["status"] = "passed"
    except (RunnerError, OSError, ValueError, KeyError, TypeError,
            subprocess.SubprocessError, json.JSONDecodeError) as error:
        report["error"] = str(error)
        report["status"] = "failed"
        print("macos-actrun: " + str(error), file=sys.stderr)
    finally:
        try:
            after = source_snapshot(REPO)
            report["source_after"] = after
            report["source_stable"] = before == after
            if before != after:
                report["ok"] = False
                report["status"] = "failed"
                report["error"] = "source changed during quality run; evidence is not a frozen-candidate pass"
        except (OSError, subprocess.SubprocessError) as error:
            report["source_stable"] = False
            report["error"] = "could not capture final source identity: " + str(error)
            report["status"] = "failed"
        report["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        report["duration_seconds"] = round(time.perf_counter() - started, 3)
        report["ok"] = report.get("ok") is True and report.get("source_stable") is True
        report["green_scope"] = "local macOS " + mode if report["ok"] else None
        if not report.get("coverage"):
            report["coverage"] = [{"id": row[0], "scope": row[1], "status": "not-run"}
                                  for row in stages_for(mode)]
        (output / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print("summary=" + str(output / "summary.json"))
        print(("GREEN" if report["ok"] else "FAIL") + " scope=local-macos-" + mode)
    return 0 if report.get("ok") else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="qualified private Mac quality profile")
    parser.add_argument("--run-dir", required=True, help="new external evidence directory")
    parser.add_argument("--mode", choices=("fast", "native", "acceptance", "mutation", "proof",
                      "verification", "performance", "quality"), default="fast")
    parser.add_argument("--actrun-cli", help="use only a CLI whose package and SHA match the lock")
    args = parser.parse_args(argv)
    try:
        return execute(args.root, args.run_dir, args.mode, args.actrun_cli)
    except (RunnerError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("macos-actrun: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
