#!/usr/bin/env python3
"""Run scoped local Linux acceptance with pinned actrun and an explicit profile."""

import argparse
from contextlib import contextmanager
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]

COMMON_STEPS = [
    ("contracts", "Contract tests and document ledger", "python3 -m unittest discover -s tests -p 'test_*.py' && python3 scripts/check_contracts.py"),
    ("infra", "Linux desktop infrastructure tests", "python3 -m unittest discover -s infra/linux-desktop/tests"),
    ("recipe", "Mozc recipe safety guards", "python3 infra/linux-desktop/mozc-prefix/test_rebuild.py"),
    ("ime-owner-safety", "Read-only GPUI IME harness guards", "python3 infra/linux-desktop/wayland-ime/test_gpui_probe.py"),
    ("format", "MoonBit formatting", "moon fmt --check"),
    ("protocols", "Prepare existing Wayland bindings", "sh scripts/prepare_ubuntu.sh"),
    ("ubuntu-ingress", "Native direct, repeat and experimental IME ingress", "sh scripts/test_ubuntu_ingress.sh"),
    ("linux-text", "Linux text C harnesses and native tests", "sh scripts/test_linux_text.sh"),
]
PACKAGES = "text controls/text_field platform ubuntu examples/linux_text_field"
FAST_STEPS = COMMON_STEPS + [
    ("check-native", "Check affected native packages", 'moon check ' + PACKAGES + ' --target native --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR"'),
    ("test-native", "Test affected native packages", 'env -u DISPLAY -u WAYLAND_DISPLAY moon test ' + PACKAGES + ' --target native --deny-warn --no-parallelize --target-dir "$GPUI_ACTRUN_BUILD_DIR"'),
]
ACCEPTANCE_STEPS = COMMON_STEPS + [
    ("check-all", "Check all Linux-runnable targets", 'moon check --target all --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR"'),
    ("test-all", "Test all Linux-runnable targets headlessly", 'env -u DISPLAY -u WAYLAND_DISPLAY moon test --target all --deny-warn --no-parallelize --target-dir "$GPUI_ACTRUN_BUILD_DIR"'),
    ("native-prerequisites", "Check native input and IPC prerequisites", 'python3 infra/linux-desktop/gpui-desktop.py --root "$GPUI_DESKTOP_ROOT" doctor --build-only --input-e2e --ipc'),
    ("candidate-build", "Build the exact current native candidate", 'python3 infra/linux-desktop/gpui-desktop.py --root "$GPUI_DESKTOP_ROOT" build --repo "$PWD" --output-dir "$GPUI_ACTRUN_BUILD_DIR" --manifest-output "$GPUI_ACTRUN_RUN_DIR/field-build.json"'),
    ("candidate-prepare", "Prepare checked current candidate bytes", 'python3 infra/linux-desktop/candidate_bundle.py prepare --build-manifest "$GPUI_ACTRUN_RUN_DIR/field-build.json" --output "$GPUI_ACTRUN_RUN_DIR/candidate"'),
    ("native-cases", "Replay ready private-display native cases", 'python3 infra/linux-desktop/case_runner.py --candidate "$GPUI_ACTRUN_RUN_DIR/candidate" --all --output "$GPUI_ACTRUN_RUN_DIR/native-cases"'),
]
MUTATION_STEPS = [
    ("composition-model", "Independent composition reference and boundary oracles", 'moon test controls/text_field --target wasm --deny-warn --target-dir "$GPUI_ACTRUN_BUILD_DIR/composition-oracle"'),
    ("composition-mutation", "Fresh targeted composition mutation and reviewed-survivor audit", 'python3 infra/linux-desktop/composition-mutation.py --turtles-bin "$GPUI_TURTLES_BIN" --output "$GPUI_ACTRUN_RUN_DIR/composition-mutation"'),
]
PROOF_STEPS = [
    ("moon-proof", "Bounded Moon proof with source correspondence and negative controls", 'python3 infra/linux-desktop/composition-proof.py --source-root "$PWD" --artifact-dir "$GPUI_ACTRUN_RUN_DIR/moon-proof" --moon-home "$MOON_HOME"'),
]
VERIFICATION_STEPS = [
    ("turtles-verification", "Actual helper mutants with runtime/PBT and source-exact proof", 'python3 infra/linux-desktop/turtles-verification.py --repo "$PWD" --turtles-root "$GPUI_TURTLES_VERIFICATION_ROOT" --turtles-bin "$GPUI_TURTLES_SCHEMA3_BIN" --profile "$GPUI_TURTLES_VERIFICATION_PROFILE" --output "$GPUI_ACTRUN_RUN_DIR/turtles-verification" --moon-home "$MOON_HOME" --why3 "$GPUI_PROOF_WHY3" --solver "$GPUI_PROOF_SOLVER" --ephemeral-workflow "$GPUI_ACTRUN_WORKFLOW"'),
]
PERFORMANCE_STEPS = [
    ("input-hotpath", "Pinned hotpath input timing workload", 'python3 infra/linux-desktop/input-hotpath.py --hotpath-root "$GPUI_HOTPATH_ROOT" --output "$GPUI_ACTRUN_RUN_DIR/input-hotpath"'),
]


def steps_for(mode):
    if mode == "headless":
        return [("step_1", "Linux text headless only", "sh scripts/test_linux_text.sh")]
    if mode == "fast":
        return FAST_STEPS
    if mode == "acceptance":
        return ACCEPTANCE_STEPS
    if mode == "mutation":
        return MUTATION_STEPS
    if mode == "proof":
        return PROOF_STEPS
    if mode == "verification":
        return VERIFICATION_STEPS
    if mode == "performance":
        return PERFORMANCE_STEPS
    if mode == "quality":
        return FAST_STEPS + MUTATION_STEPS + PROOF_STEPS + VERIFICATION_STEPS + PERFORMANCE_STEPS
    raise ValueError("unknown local gate mode")


def workflow_text(mode):
    if mode == "headless":
        return (HERE / "actrun-feedback.yml").read_text()
    title = "wider acceptance" if mode == "acceptance" else mode + " acceptance"
    lines = ["name: Local Linux " + title, "on:", "  push:", "jobs:",
             "  linux-local:", "    runs-on: ubuntu-24.04", "    timeout-minutes: 15", "    steps:"]
    for identity, title, command in steps_for(mode):
        lines += ["      - id: " + identity, "        name: " + title, "        run: |",
                  "          " + command]
    return "\n".join(lines) + "\n"


def coverage_for(mode, tasks):
    job = "linux-text-headless" if mode == "headless" else "linux-local"
    by_id = {row["id"]: row for row in tasks}
    coverage = []
    for identity, title, _ in steps_for(mode):
        row = by_id.get(job + "/" + identity)
        if row is None or row.get("status") in {"skipped", "blocked", "cancelled", "pending"}:
            status = "not-run"
        else:
            status = "passed" if row.get("status") == "success" and row.get("code") == 0 else "failed"
        coverage.append({"id": identity, "scope": title, "status": status})
    for identity, reason in [
        ("macos-native", "requires macOS; outside this Linux gate"),
        ("windows-native", "requires Windows; outside this Linux gate"),
        ("browser-proof", "real-browser proof is a separate acceptance scope"),
        ("mutation", "select --mode mutation or quality for the explicit portable composition mutation scope"),
        ("mcp-stdio", "stdio interoperability is a separate acceptance scope"),
        ("ubuntu-gpu-suite", "the separate scale/readback/lifecycle suite is not this private keyboard catalog"),
        ("moon-proof", "select --mode proof or quality for the separately qualified bounded proof"),
        ("turtles-verification", "select --mode verification or quality for actual bounded helper mutants with runtime/PBT and proof"),
        ("input-hotpath", "select --mode performance or quality for the pinned hotpath input workload"),
    ]:
        active = (identity == "mutation" and mode in {"mutation", "quality"}) or \
                 (identity == "moon-proof" and mode in {"proof", "quality"}) or \
                 (identity == "turtles-verification" and mode in {"verification", "quality"}) or \
                 (identity == "input-hotpath" and mode in {"performance", "quality"})
        if not active:
            coverage.append({"id": identity, "status": "skipped", "reason": reason})
    if mode in {"mutation", "quality"}:
        coverage.append({"id": "full-mutation", "status": "skipped", "reason": "only both declared composition source files are mutated; native owner/transport and other packages are outside this denominator"})
    if mode != "acceptance":
        coverage += [{"id": "all-target-headless", "status": "skipped", "reason": "select --mode acceptance for the wider target suite"},
                     {"id": "native-input", "status": "skipped", "reason": "select --mode acceptance for a fresh private-display candidate replay"}]
    return coverage


def native_coverage(output):
    # Require the current catalog's complete ready-case set; skips stay explicit.
    spec = importlib.util.spec_from_file_location("gate_cases", HERE / "input_cases.py")
    cases = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cases)
    catalog = cases.catalog(cases.CASES)
    path = output / "native-cases/summary.json"
    summary = json.loads(path.read_text()) if path.is_file() else None
    results = {row["case_id"]: row for row in summary["results"]} if summary else {}
    if summary and (len(results) != len(summary["results"]) or set(results) != {case["id"] for case in catalog}):
        raise RuntimeError("native replay did not report the exact current catalog")
    ready = [case for case in catalog if cases.runnable(case)]
    if not ready or (summary and summary.get("executed") != len(ready)):
        raise RuntimeError("native replay did not execute every ready case")
    coverage = []
    for case in catalog:
        row = results.get(case["id"])
        if cases.runnable(case):
            status = "not-run" if row is None else ("passed" if row.get("status") == "passed" else "failed")
            coverage.append({"id": case["id"], "status": status})
        else:
            if row and row.get("status") != "skipped-" + case["disposition"]:
                raise RuntimeError("native pending/unsupported case was mislabeled: " + case["id"])
            coverage.append({"id": case["id"], "status": "skipped", "reason": case["reason"]})
    return coverage


def mutation_evidence(output):
    path = output / "composition-mutation/summary.json"
    if not path.is_file():
        raise RuntimeError("composition mutation produced no audited summary")
    report = json.loads(path.read_text())
    if report.get("ok") is not True or report.get("source_stable") is not True or \
       report.get("turtles_version") != "0.3.0" or report.get("report_schema") != 2 or \
       report.get("target") != "wasm" or report.get("unreviewed_survivors") != 0 or \
       type(report.get("qualified_viable")) is not int or report["qualified_viable"] <= 0:
        raise RuntimeError("composition mutation did not pass its declared fresh audited scope")
    return {key: report[key] for key in ("scope", "target", "selection", "source_files", "turtles_version",
            "report_schema", "attempted_candidates", "qualified_viable", "counts", "score_percent",
            "reviewed_survivors", "mutation_seconds", "total_seconds")}


def load_quality_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def proof_evidence(output, environment=None):
    proof = load_quality_module("gate_proof_evidence", "proof-evidence.py")
    return proof.validate(output / "moon-proof", REPO, environment if environment is not None else dict(os.environ),
                          source_snapshot(REPO))


def verification_evidence(output, environment, expected_workflow):
    verification = load_quality_module("gate_turtles_verification", "turtles-verification.py")
    audited = verification.validate(output / "turtles-verification", REPO, environment,
                                    expected_workflow=expected_workflow)
    if type(audited) is not dict or audited.get("kind") != "bounded-real-mutant-helper-verification":
        raise RuntimeError("verification collector did not return the declared audited scope")
    return audited


def hotpath_evidence(output, environment=None):
    directory = output / "input-hotpath"
    path = directory / "summary.json"
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("hotpath workload produced no regular measured summary")
    report = json.loads(path.read_text())
    if not isinstance(report, dict) or type(report.get("schema_version")) is not int or report["schema_version"] != 2 or \
       type(report.get("repeats")) is not int or report["repeats"] != 7 or \
       report.get("performance_policy") != "observe-only: no universal timing gate":
        raise RuntimeError("hotpath current gate requires fresh schema2, seven pairs and observe-only policy")
    workload = load_quality_module("gate_hotpath", "input-hotpath.py")
    report = workload.validate_evidence(report, directory)
    current = source_snapshot(REPO)
    if report["source_before"] != current or report["source_after"] != current:
        raise RuntimeError("hotpath evidence is stale for the current candidate source")
    if environment is not None:
        # The producer's retained baseline reader deliberately allows historical
        # environments. A current acceptance must match the actual stage tools.
        report_environment = report["environment"]
        profile, marker = workload.verify_profile(environment.get("GPUI_DESKTOP_ROOT"))
        if report_environment.get("installed_profile_sha256") != marker or \
           report_environment.get("profile_lock_sha256") != digest(HERE / "profile.lock.json") or \
           report_environment.get("native_build") != workload.native_build_identity(environment):
            raise RuntimeError("hotpath current native tool/profile environment differs from the report")
        if report_environment.get("tools", {}).get("moon") != workload.tool_identity([str(profile / "moon/bin/moon")], environment, "version") or \
           report_environment.get("tools", {}).get("moonc") != workload.tool_identity([str(profile / "moon/bin/moonc")], environment, "-v") or \
           report_environment.get("tools", {}).get("moonrun") != {"sha256": digest(profile / "moon/bin/moonrun")} or \
           report_environment.get("core_module_sha256") != digest(profile / "moon/lib/core/moon.mod"):
            raise RuntimeError("hotpath current compiler/runtime identity differs from the report")
        current_fontconfig = digest(environment["FONTCONFIG_FILE"]) if environment.get("FONTCONFIG_FILE") else None
        if report_environment.get("fontconfig_sha256") != current_fontconfig or \
           report_environment.get("tools", {}).get("default_cc") != workload.tool_identity(workload.environment_words(environment, "CC", "cc"), environment) or \
           report_environment.get("tools", {}).get("fc_match") != workload.tool_identity(["fc-match"], environment):
            raise RuntimeError("hotpath current font configuration/default compiler differs from the report")
        fonts = {}
        for family in ("sans", "Noto Sans CJK JP"):
            selected = subprocess.check_output(["fc-match", "-f", "%{file}", family], text=True,
                                               env=environment, timeout=10).strip()
            if not selected or not Path(selected).is_file():
                raise RuntimeError("hotpath current font fixture cannot be resolved")
            fonts[family] = digest(selected)
        if report_environment.get("fonts") != fonts:
            raise RuntimeError("hotpath current resolved font bytes differ from the report")
    return {key: report[key] for key in ("scope", "excluded", "hotpath_runtime", "binary_sha256",
            "workload_sha256", "behavior_equal", "statistics", "performance_policy")}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def external_path(path, repo):
    path = Path(path).expanduser().resolve()
    if path == Path("/") or path == Path.home() or path == repo or repo in path.parents:
        raise RuntimeError("keep the profile and results outside the source checkout and HOME")
    return path


def verify_runner(cli):
    lock = json.loads((HERE / "actrun-runner.lock.json").read_text())
    cli = Path(cli).expanduser().resolve()
    package = json.loads((cli.parent.parent / "package.json").read_text())
    if (package.get("name"), package.get("version")) != (lock["name"], lock["version"]):
        raise RuntimeError("actrun package name/version does not match the runner lock")
    if digest(cli) != lock["cli_sha256"]:
        raise RuntimeError("actrun CLI SHA-256 does not match the runner lock")
    return cli, lock


def source_snapshot(repo):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repo)
    inputs = hashlib.sha256()
    for name in sorted(git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")):
        if not name:
            continue
        path = repo / name.decode()
        inputs.update(name + b"\0")
        if path.is_symlink():
            inputs.update(b"link\0" + str(path.readlink()).encode())
        elif path.is_file():
            inputs.update(b"file\0" + hashlib.sha256(path.read_bytes()).digest())
        else:
            inputs.update(b"missing\0")
    return {
        "commit": git("rev-parse", "HEAD").decode().strip(),
        "tree": git("rev-parse", "HEAD^{tree}").decode().strip(),
        "tracked_patch_sha256": hashlib.sha256(git("diff", "--binary", "HEAD")).hexdigest(),
        "input_files_sha256": inputs.hexdigest(),
        "status": git("status", "--porcelain", "--untracked-files=all").decode(),
    }


@contextmanager
def temporary_workflow(repo, mode="headless"):
    # Published 0.32.0 infers the workspace correctly only from this directory.
    # Keep the template out of hosted workflows; remove only our newly-created file.
    directory = repo / ".github/workflows"
    if not directory.is_dir() or directory.resolve() != directory:
        raise RuntimeError("the checkout must have its own .github/workflows directory")
    name = None
    try:
        candidate = directory / ("_local-actrun-feedback-" + uuid.uuid4().hex + ".yml")
        descriptor = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        name = candidate
        with os.fdopen(descriptor, "w") as stream:
            stream.write(workflow_text(mode))
        yield name
    finally:
        if name is not None:
            name.unlink(missing_ok=True)


def profile_environment(root):
    spec = importlib.util.spec_from_file_location("feedback_desktop", HERE / "gpui-desktop.py")
    desktop = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(desktop)
    return desktop.native_environment(root)


def execute(root, cli, output, mode="fast", turtles=None, hotpath=None, solver=None, why3=None,
            verification_root=None, schema3=None, verification_profile=None):
    started = time.perf_counter()
    output.mkdir(parents=True, exist_ok=False)
    before = source_snapshot(REPO)
    template = workflow_text(mode)
    report = {"schema_version": 2, "mode": mode, "scope": "local Linux " + mode,
              "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
              "source_before": before, "profile_lock_sha256": digest(HERE / "profile.lock.json"),
              "runner_cli_sha256": digest(cli), "entrypoint_sha256": digest(HERE / "actrun-feedback.py"),
              "template_sha256": hashlib.sha256(template.encode()).hexdigest(),
              "coverage": coverage_for(mode, []), "doctor_status": "not-run",
              "ok": False, "green_scope": None}
    try:
        if mode == "acceptance":
            report["native_cases"] = native_coverage(output)
        doctor_start = time.perf_counter()
        doctor_command = [sys.executable, str(HERE / "gpui-desktop.py"), "--root", str(root),
                          "doctor", "--build-only"]
        with (output / "doctor.log").open("w") as stream:
            doctor = subprocess.run(doctor_command, stdout=stream, stderr=subprocess.STDOUT)
        report["doctor_seconds"] = time.perf_counter() - doctor_start
        report["doctor_status"] = "passed" if doctor.returncode == 0 else "failed"
        if doctor.returncode:
            raise RuntimeError("explicit profile doctor failed; see doctor.log")
        env = profile_environment(root)
        node = shutil.which("node", path=env["PATH"])
        if not node:
            raise RuntimeError("Node.js is required; no software is installed automatically")
        version = subprocess.check_output([node, "--version"], text=True).strip()
        major = int(version.removeprefix("v").split(".")[0])
        minimum = json.loads((HERE / "actrun-runner.lock.json").read_text())["node_minimum_major"]
        if major < minimum:
            raise RuntimeError("Node.js version is below the pinned runner minimum")
        report["node_version"] = version
        env["GPUI_LINUX_TEXT_BUILD_DIR"] = str(root / "feedback-build" /
                                                hashlib.sha256(str(REPO).encode()).hexdigest()[:16])
        env["GPUI_ACTRUN_BUILD_DIR"] = env["GPUI_LINUX_TEXT_BUILD_DIR"]
        env["GPUI_ACTRUN_RUN_DIR"] = str(output)
        if mode in {"mutation", "quality"}:
            binary = Path(turtles) if turtles else root / "tools/turtles/turtles"
            env["GPUI_TURTLES_BIN"] = str(binary.expanduser().resolve())
        if mode in {"performance", "quality"}:
            checkout = Path(hotpath) if hotpath else root / "tools/hotpath"
            env["GPUI_HOTPATH_ROOT"] = str(checkout.expanduser().resolve())
        if solver:
            env["GPUI_PROOF_SOLVER"] = str(Path(solver).expanduser().resolve())
        if why3:
            env["GPUI_PROOF_WHY3"] = str(Path(why3).expanduser().resolve())
        if mode in {"verification", "quality"}:
            for name, value in (("GPUI_TURTLES_VERIFICATION_ROOT", verification_root),
                                ("GPUI_TURTLES_SCHEMA3_BIN", schema3),
                                ("GPUI_TURTLES_VERIFICATION_PROFILE", verification_profile)):
                if value:
                    env[name] = str(Path(value).expanduser().resolve())
            for name in ("GPUI_TURTLES_VERIFICATION_ROOT", "GPUI_TURTLES_SCHEMA3_BIN",
                         "GPUI_TURTLES_VERIFICATION_PROFILE", "GPUI_PROOF_WHY3", "GPUI_PROOF_SOLVER"):
                if not env.get(name):
                    raise RuntimeError("verification requires explicit pinned input: " + name)
        env["XDG_CACHE_HOME"] = str(Path(env["GPUI_ACTRUN_BUILD_DIR"]) / "xdg-cache")
        with temporary_workflow(REPO, mode) as workflow:
            env["GPUI_ACTRUN_WORKFLOW"] = str(workflow)
            expected_workflow = {"path": workflow.relative_to(REPO).as_posix(),
                                 "sha256": digest(workflow), "mode": workflow.stat().st_mode & 0o777}
            report["generated_workflow"] = expected_workflow
            (output / "workflow.yml").write_text(template)
            command = [node, str(cli), "workflow", "run", str(workflow), "--workspace-mode", "local",
                       "--run-root", str(output / "runs"), "--artifact-root", str(output / "artifacts"),
                       "--cache-root", str(root / "feedback-cache"), "--no-nix"]
            timer = time.perf_counter()
            result = subprocess.run(command, cwd=REPO, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            report["actrun_seconds"] = time.perf_counter() - timer
            (output / "actrun.log").write_text(result.stdout)
            print(result.stdout, end="")
            match = re.search(r"^run_id=(run-\d+)$", result.stdout, re.MULTILINE)
            if not match:
                raise RuntimeError("actrun did not identify a recorded run; see actrun.log")
            run = json.loads((output / "runs" / match[1] / "run.json").read_text())
            report["run_id"] = match[1]
            report["tasks"] = [{key: row.get(key) for key in
                                ("id", "status", "code", "duration_ms")}
                               for row in run["tasks"]]
            report["coverage"] = coverage_for(mode, report["tasks"])
            if mode == "acceptance":
                report["native_cases"] = native_coverage(output)
            if result.returncode or run.get("ok") is not True or run.get("state") != "completed":
                raise RuntimeError("local Linux required workload failed; full task logs are retained")
            if Path(run["workspace_root"]).resolve() != REPO:
                raise RuntimeError("actrun workspace does not match the candidate checkout")
            if any(row["status"] != "passed" for row in report["coverage"] if "scope" in row):
                raise RuntimeError("a required local step failed or was not run")
            if mode == "acceptance":
                if any(row["status"] not in {"passed", "skipped"} for row in report["native_cases"]):
                    raise RuntimeError("a required native case failed or was not run")
            if mode in {"mutation", "quality"}:
                report["mutation_evidence"] = mutation_evidence(output)
            if mode in {"proof", "quality"}:
                report["proof_evidence"] = proof_evidence(output, env)
            if mode in {"verification", "quality"}:
                report["verification_evidence"] = verification_evidence(output, env, expected_workflow)
            if mode in {"performance", "quality"}:
                report["hotpath_evidence"] = hotpath_evidence(output, env)
        report["ok"] = True
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print("actrun-feedback: " + str(error), file=sys.stderr)
    finally:
        report["source_after"] = source_snapshot(REPO)
        report["source_stable"] = report["source_after"] == before
        if not report["source_stable"]:
            report["ok"] = False
            report["error"] = "source changed during validation; run again on the frozen candidate"
        report["green_scope"] = "local Linux " + mode if report["ok"] else None
        report["total_seconds"] = time.perf_counter() - started
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print("summary=" + str(output / "summary.json"))
        print(("GREEN" if report["ok"] else "FAIL") + " scope=local-linux-" + mode)
        for row in report["coverage"] + report.get("native_cases", []):
            print(row["status"] + ": " + row["id"] + ("; " + row["reason"] if "reason" in row else ""))
    return 0 if report["ok"] else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="already-bootstrapped exact desktop profile")
    parser.add_argument("--actrun-cli", help="pinned npm package's dist/actrun.js")
    parser.add_argument("--run-dir", help="new external directory for this run's logs and timing")
    parser.add_argument("--mode", choices=("fast", "headless", "acceptance", "mutation", "proof", "verification", "performance", "quality"), default="fast",
                        help="fast Linux gate (default), text subset, native acceptance, mutation, proof, real-mutant verification, performance, or combined quality")
    parser.add_argument("--turtles-bin", help="already-installed official turtles 0.3.0 executable for mutation/quality")
    parser.add_argument("--hotpath-root", help="explicit pinned hotpath source checkout for performance/quality")
    parser.add_argument("--proof-solver", help="explicit qualified proof solver executable")
    parser.add_argument("--proof-why3", help="qualified official socket-free Why3 export executable")
    parser.add_argument("--turtles-verification-root", help="explicit pinned turtles source checkout for verification/quality")
    parser.add_argument("--turtles-schema3-bin", help="separate reviewed schema-3 turtles executable for verification/quality")
    parser.add_argument("--turtles-verification-profile", help="explicit pinned bounded-helper profile JSON for verification/quality")
    args = parser.parse_args(argv)
    root = external_path(args.root, REPO)
    cli, _ = verify_runner(args.actrun_cli or root / "tools/actrun/node_modules/@mizchi/actrun/dist/actrun.js")
    output = external_path(args.run_dir or root / "results/actrun-feedback" / uuid.uuid4().hex, REPO)
    if args.turtles_bin or args.hotpath_root or args.proof_solver or args.proof_why3 or \
       args.turtles_verification_root or args.turtles_schema3_bin or args.turtles_verification_profile:
        return execute(root, cli, output, args.mode, args.turtles_bin, args.hotpath_root, args.proof_solver, args.proof_why3,
                       verification_root=args.turtles_verification_root, schema3=args.turtles_schema3_bin,
                       verification_profile=args.turtles_verification_profile)
    return execute(root, cli, output, args.mode)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("actrun-feedback: " + str(error), file=sys.stderr)
        sys.exit(1)
