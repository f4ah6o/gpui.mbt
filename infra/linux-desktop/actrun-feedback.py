#!/usr/bin/env python3
"""Run the bounded Linux text workload with pinned actrun and an explicit profile."""

import argparse
from contextlib import contextmanager
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


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
def temporary_workflow(repo):
    # Published 0.32.0 infers the workspace correctly only from this directory.
    # Keep the template out of hosted workflows; remove only our newly-created file.
    directory = repo / ".github/workflows"
    if not directory.is_dir() or directory.resolve() != directory:
        raise RuntimeError("the checkout must have its own .github/workflows directory")
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", prefix="_local-actrun-feedback-",
                                         suffix=".yml", dir=directory, delete=False) as stream:
            name = Path(stream.name)
            stream.write((HERE / "actrun-feedback.yml").read_text())
        yield name
    finally:
        if name is not None:
            name.unlink(missing_ok=True)


def profile_environment(root):
    spec = importlib.util.spec_from_file_location("feedback_desktop", HERE / "gpui-desktop.py")
    desktop = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(desktop)
    return desktop.native_environment(root)


def execute(root, cli, output):
    started = time.perf_counter()
    output.mkdir(parents=True, exist_ok=False)
    before = source_snapshot(REPO)
    report = {"schema_version": 1, "scope": "Linux text headless workload only",
              "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
              "source_before": before, "profile_lock_sha256": digest(HERE / "profile.lock.json"),
              "runner_cli_sha256": digest(cli), "entrypoint_sha256": digest(HERE / "actrun-feedback.py"),
              "template_sha256": digest(HERE / "actrun-feedback.yml"), "ok": False}
    try:
        doctor_start = time.perf_counter()
        doctor_command = [sys.executable, str(HERE / "gpui-desktop.py"), "--root", str(root),
                          "doctor", "--build-only"]
        with (output / "doctor.log").open("w") as stream:
            doctor = subprocess.run(doctor_command, stdout=stream, stderr=subprocess.STDOUT)
        report["doctor_seconds"] = time.perf_counter() - doctor_start
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
        with temporary_workflow(REPO) as workflow:
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
            if result.returncode or run.get("ok") is not True or run.get("state") != "completed":
                raise RuntimeError("Linux headless workload failed; full task logs are retained")
            if Path(run["workspace_root"]).resolve() != REPO:
                raise RuntimeError("actrun workspace does not match the candidate checkout")
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
        report["total_seconds"] = time.perf_counter() - started
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print("summary=" + str(output / "summary.json"))
    return 0 if report["ok"] else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="already-bootstrapped exact desktop profile")
    parser.add_argument("--actrun-cli", help="pinned npm package's dist/actrun.js")
    parser.add_argument("--run-dir", help="new external directory for this run's logs and timing")
    args = parser.parse_args(argv)
    root = external_path(args.root, REPO)
    cli, _ = verify_runner(args.actrun_cli or root / "tools/actrun/node_modules/@mizchi/actrun/dist/actrun.js")
    output = external_path(args.run_dir or root / "results/actrun-feedback" / uuid.uuid4().hex, REPO)
    return execute(root, cli, output)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("actrun-feedback: " + str(error), file=sys.stderr)
        sys.exit(1)
